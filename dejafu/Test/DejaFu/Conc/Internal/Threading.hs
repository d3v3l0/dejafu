{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Test.DejaFu.Conc.Internal.Threading
-- Copyright   : (c) 2016--2018 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : ExistentialQuantification, FlexibleContexts, RankNTypes
--
-- Operations and types for threads. This module is NOT considered to
-- form part of the public interface of this library.
module Test.DejaFu.Conc.Internal.Threading where

import           Control.Exception                (Exception, MaskingState(..),
                                                   SomeException, fromException)
import           Control.Monad                    (forever)
import qualified Control.Monad.Conc.Class         as C
import           Data.List                        (intersect)
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict                  as M
import           Data.Maybe                       (isJust)
import           GHC.Stack                        (HasCallStack)

import           Test.DejaFu.Conc.Internal.Common
import           Test.DejaFu.Internal
import           Test.DejaFu.Types

--------------------------------------------------------------------------------
-- * Threads

-- | Threads are stored in a map index by 'ThreadId'.
type Threads n = Map ThreadId (Thread n)

-- | All the state of a thread.
data Thread n = Thread
  { _continuation :: Action n
  -- ^ The next action to execute.
  , _blocking     :: Maybe BlockedOn
  -- ^ The state of any blocks.
  , _handlers     :: [Handler n]
  -- ^ Stack of exception handlers
  , _masking      :: MaskingState
  -- ^ The exception masking state.
  , _bound        :: Maybe (BoundThread n)
  -- ^ State for the associated bound thread, if it exists.
  }

-- | The state of a bound thread.
data BoundThread n = BoundThread
  { _runboundIO :: C.MVar n (n (Action n))
  -- ^ Run an @IO@ action in the bound thread by writing to this.
  , _getboundIO :: C.MVar n (Action n)
  -- ^ Get the result of the above by reading from this.
  , _boundTId   :: C.ThreadId n
  -- ^ Thread ID
  }

-- | Construct a thread with just one action
mkthread :: Action n -> Thread n
mkthread c = Thread c Nothing [] Unmasked Nothing

--------------------------------------------------------------------------------
-- * Blocking

-- | A @BlockedOn@ is used to determine what sort of variable a thread
-- is blocked on.
data BlockedOn = OnMVarFull MVarId | OnMVarEmpty MVarId | OnTVar [TVarId] | OnMask ThreadId deriving Eq

-- | Determine if a thread is blocked in a certain way.
(~=) :: Thread n -> BlockedOn -> Bool
thread ~= theblock = case (_blocking thread, theblock) of
  (Just (OnMVarFull  _), OnMVarFull  _) -> True
  (Just (OnMVarEmpty _), OnMVarEmpty _) -> True
  (Just (OnTVar      _), OnTVar      _) -> True
  (Just (OnMask      _), OnMask      _) -> True
  _ -> False

--------------------------------------------------------------------------------
-- * Exceptions

-- | An exception handler.
data Handler n = forall e. Exception e => Handler (e -> MaskingState -> Action n)

-- | Propagate an exception upwards, finding the closest handler
-- which can deal with it.
propagate :: HasCallStack => SomeException -> ThreadId -> Threads n -> Maybe (Threads n)
propagate e tid threads = raise <$> propagate' handlers where
  handlers = _handlers (elookup tid threads)

  raise (act, hs) = except act hs tid threads

  propagate' [] = Nothing
  propagate' (Handler h:hs) = maybe (propagate' hs) (\act -> Just (act, hs)) $ h <$> fromException e

-- | Check if a thread can be interrupted by an exception.
interruptible :: Thread n -> Bool
interruptible thread =
  _masking thread == Unmasked ||
  (_masking thread == MaskedInterruptible && isJust (_blocking thread))

-- | Register a new exception handler.
catching :: (Exception e, HasCallStack) => (e -> Action n) -> ThreadId -> Threads n -> Threads n
catching h = eadjust $ \thread ->
  let ms0 = _masking thread
      h'  = Handler $ \e ms -> (if ms /= ms0 then AResetMask False False ms0 else id) (h e)
  in thread { _handlers = h' : _handlers thread }

-- | Remove the most recent exception handler.
uncatching :: HasCallStack => ThreadId -> Threads n -> Threads n
uncatching = eadjust $ \thread ->
  thread { _handlers = etail (_handlers thread) }

-- | Raise an exception in a thread.
except :: HasCallStack => (MaskingState -> Action n) -> [Handler n] -> ThreadId -> Threads n -> Threads n
except actf hs = eadjust $ \thread -> thread
  { _continuation = actf (_masking thread)
  , _handlers = hs
  , _blocking = Nothing
  }

-- | Set the masking state of a thread.
mask :: HasCallStack => MaskingState -> ThreadId -> Threads n -> Threads n
mask ms = eadjust $ \thread -> thread { _masking = ms }

--------------------------------------------------------------------------------
-- * Manipulating threads

-- | Replace the @Action@ of a thread.
goto :: HasCallStack => Action n -> ThreadId -> Threads n -> Threads n
goto a = eadjust $ \thread -> thread { _continuation = a }

-- | Start a thread with the given ID, inheriting the masking state
-- from the parent thread. This ID must not already be in use!
launch :: HasCallStack => ThreadId -> ThreadId -> ((forall b. ModelConc n b -> ModelConc n b) -> Action n) -> Threads n -> Threads n
launch parent tid a threads = launch' ms tid a threads where
  ms = _masking (elookup parent threads)

-- | Start a thread with the given ID and masking state. This must not already be in use!
launch' :: HasCallStack => MaskingState -> ThreadId -> ((forall b. ModelConc n b -> ModelConc n b) -> Action n) -> Threads n -> Threads n
launch' ms tid a = einsert tid thread where
  thread = Thread (a umask) Nothing [] ms Nothing

  umask mb = resetMask True Unmasked >> mb >>= \b -> resetMask False ms >> pure b
  resetMask typ m = ModelConc $ \k -> AResetMask typ True m $ k ()

-- | Block a thread.
block :: HasCallStack => BlockedOn -> ThreadId -> Threads n -> Threads n
block blockedOn = eadjust $ \thread -> thread { _blocking = Just blockedOn }

-- | Unblock all threads waiting on the appropriate block. For 'TVar'
-- blocks, this will wake all threads waiting on at least one of the
-- given 'TVar's.
wake :: BlockedOn -> Threads n -> (Threads n, [ThreadId])
wake blockedOn threads = (unblock <$> threads, M.keys $ M.filter isBlocked threads) where
  unblock thread
    | isBlocked thread = thread { _blocking = Nothing }
    | otherwise = thread

  isBlocked thread = case (_blocking thread, blockedOn) of
    (Just (OnTVar tvids), OnTVar blockedOn') -> tvids `intersect` blockedOn' /= []
    (theblock, _) -> theblock == Just blockedOn

-------------------------------------------------------------------------------
-- ** Bound threads

-- | Turn a thread into a bound thread.
makeBound :: (C.MonadConc n, HasCallStack) => ThreadId -> Threads n -> n (Threads n)
makeBound tid threads = do
    runboundIO <- C.newEmptyMVar
    getboundIO <- C.newEmptyMVar
    btid <- C.forkOSN ("bound worker for '" ++ show tid ++ "'") (go runboundIO getboundIO)
    let bt = BoundThread runboundIO getboundIO btid
    pure (eadjust (\t -> t { _bound = Just bt }) tid threads)
  where
    go runboundIO getboundIO = forever $ do
      na <- C.takeMVar runboundIO
      C.putMVar getboundIO =<< na

-- | Kill a thread and remove it from the thread map.
--
-- If the thread is bound, the worker thread is cleaned up.
kill :: (C.MonadConc n, HasCallStack) => ThreadId -> Threads n -> n (Threads n)
kill tid threads = do
  let thread = elookup tid threads
  maybe (pure ()) (C.killThread . _boundTId) (_bound thread)
  pure (M.delete tid threads)

-- | Run an action.
--
-- If the thread is bound, the action is run in the worker thread.
runLiftedAct :: C.MonadConc n => ThreadId -> Threads n -> n (Action n) -> n (Action n)
runLiftedAct tid threads ma = case _bound =<< M.lookup tid threads of
  Just bt -> do
    C.putMVar (_runboundIO bt) ma
    C.takeMVar (_getboundIO bt)
  Nothing -> ma
