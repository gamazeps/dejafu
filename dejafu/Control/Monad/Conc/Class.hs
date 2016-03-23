{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE TypeFamilies     #-}

-- | This module captures in a typeclass the interface of concurrency
-- monads.
module Control.Monad.Conc.Class
  ( MonadConc(..)

  -- * Threads
  , spawn
  , forkFinally
  , killThread

  -- ** Named Threads
  , forkN
  , forkOnN
  , lineNum

  -- ** Bound Threads

  -- | @MonadConc@ does not support bound threads, if you need that
  -- sort of thing you will have to use regular @IO@.

  , rtsSupportsBoundThreads
  , isCurrentThreadBound

  -- * Exceptions
  , throw
  , catch
  , mask
  , uninterruptibleMask

  -- * Mutable State
  , newMVar
  , newMVarN
  , cas

  -- * Utilities for instance writers
  , makeTransConc
  , liftedF
  , liftedFork
  ) where

-- for the class and utilities
import Control.Exception (Exception, AsyncException(ThreadKilled), SomeException)
import Control.Monad.Catch (MonadCatch, MonadThrow, MonadMask)
import qualified Control.Monad.Catch as Ca
import Control.Monad.STM.Class (MonadSTM, TVar)
import Control.Monad.Trans.Control (MonadTransControl, StT, liftWith)
import Data.Typeable (Typeable)
import Language.Haskell.TH (Q, DecsQ, Exp, Loc(..), Info(VarI), Name, Type(..), reify, location, varE)

-- for the 'IO' instance
import qualified Control.Concurrent as IO
import qualified Control.Monad.STM as IO
import qualified Data.Atomics as IO
import qualified Data.IORef as IO

-- for the transformer instances
import Control.Monad.Trans (lift)
import Control.Monad.Reader (ReaderT)
import qualified Control.Monad.RWS.Lazy as RL
import qualified Control.Monad.RWS.Strict as RS
import qualified Control.Monad.State.Lazy as SL
import qualified Control.Monad.State.Strict as SS
import qualified Control.Monad.Writer.Lazy as WL
import qualified Control.Monad.Writer.Strict as WS

{-# ANN module ("HLint: ignore Use const" :: String) #-}

-- | @MonadConc@ is an abstraction over GHC's typical concurrency
-- abstraction. It captures the interface of concurrency monads in
-- terms of how they can operate on shared state and in the presence
-- of exceptions.
--
-- Every @MonadConc@ has an associated 'MonadSTM', transactions of
-- which can be run atomically.
class ( Applicative m, Monad m
      , MonadCatch m, MonadThrow m, MonadMask m
      , MonadSTM (STM m)
      , Eq (ThreadId m), Show (ThreadId m)) => MonadConc m  where

  {-# MINIMAL
        (forkWithUnmask | forkWithUnmaskN)
      , (forkOnWithUnmask | forkOnWithUnmaskN)
      , getNumCapabilities
      , setNumCapabilities
      , myThreadId
      , yield
      , (newEmptyMVar | newEmptyMVarN)
      , putMVar
      , tryPutMVar
      , readMVar
      , takeMVar
      , tryTakeMVar
      , (newCRef | newCRefN)
      , modifyCRef
      , writeCRef
      , readForCAS
      , peekTicket
      , casCRef
      , modifyCRefCAS
      , atomically
      , throwTo
    #-}

  -- | The associated 'MonadSTM' for this class.
  type STM m :: * -> *

  -- | The mutable reference type, like 'MVar's. This may contain one
  -- value at a time, attempting to read or take from an \"empty\"
  -- @MVar@ will block until it is full, and attempting to put to a
  -- \"full\" @MVar@ will block until it is empty.
  type MVar m :: * -> *

  -- | The mutable non-blocking reference type. These may suffer from
  -- relaxed memory effects if functions outside the set @newCRef@,
  -- @readCRef@, @modifyCRef@, and @atomicWriteCRef@ are used.
  type CRef m :: * -> *

  -- | When performing compare-and-swap operations on @CRef@s, a
  -- @Ticket@ is a proof that a thread observed a specific previous
  -- value.
  type Ticket m :: * -> *

  -- | An abstract handle to a thread.
  type ThreadId m :: *

  -- | Fork a computation to happen concurrently. Communication may
  -- happen over @MVar@s.
  --
  -- > fork ma = forkWithUnmask (\_ -> ma)
  fork :: m () -> m (ThreadId m)
  fork ma = forkWithUnmask (\_ -> ma)

  -- | Like 'fork', but the child thread is passed a function that can
  -- be used to unmask asynchronous exceptions. This function should
  -- not be used within a 'mask' or 'uninterruptibleMask'.
  --
  -- > forkWithUnmask = forkWithUnmaskN ""
  forkWithUnmask :: ((forall a. m a -> m a) -> m ()) -> m (ThreadId m)
  forkWithUnmask = forkWithUnmaskN ""

  -- | Like 'forkWithUnmask', but the thread is given a name which may
  -- be used to present more useful debugging information.
  --
  -- If an empty name is given, the @ThreadId@ is used. If names
  -- conflict, successive threads with the same name are given a
  -- numeric suffix, counting up from 1.
  --
  -- > forkWithUnmaskN _ = forkWithUnmask
  forkWithUnmaskN :: String -> ((forall a. m a -> m a) -> m ()) -> m (ThreadId m)
  forkWithUnmaskN _ = forkWithUnmask

  -- | Fork a computation to happen on a specific processor. The
  -- specified int is the /capability number/, typically capabilities
  -- correspond to physical processors or cores but this is
  -- implementation dependent. The int is interpreted modulo to the
  -- total number of capabilities as returned by 'getNumCapabilities'.
  --
  -- > forkOn c ma = forkOnWithUnmask c (\_ -> ma)
  forkOn :: Int -> m () -> m (ThreadId m)
  forkOn c ma = forkOnWithUnmask c (\_ -> ma)

  -- | Like 'forkWithUnmask', but the child thread is pinned to the
  -- given CPU, as with 'forkOn'.
  --
  -- > forkOnWithUnmask = forkOnWithUnmaskN ""
  forkOnWithUnmask :: Int -> ((forall a. m a -> m a) -> m ()) -> m (ThreadId m)
  forkOnWithUnmask = forkOnWithUnmaskN ""

  -- | Like 'forkWithUnmaskN', but the child thread is pinned to the
  -- given CPU, as with 'forkOn'.
  --
  -- > forkOnWithUnmaskN _ = forkOnWithUnmask
  forkOnWithUnmaskN :: String -> Int -> ((forall a. m a -> m a) -> m ()) -> m (ThreadId m)
  forkOnWithUnmaskN _ = forkOnWithUnmask

  -- | Get the number of Haskell threads that can run simultaneously.
  getNumCapabilities :: m Int

  -- | Set the number of Haskell threads that can run simultaneously.
  setNumCapabilities :: Int -> m ()

  -- | Get the @ThreadId@ of the current thread.
  myThreadId :: m (ThreadId m)

  -- | Allows a context-switch to any other currently runnable thread
  -- (if any).
  yield :: m ()

  -- | Yields the current thread, and optionally suspends the current
  -- thread for a given number of microseconds.
  --
  -- If suspended, there is no guarantee that the thread will be
  -- rescheduled promptly when the delay has expired, but the thread
  -- will never continue to run earlier than specified.
  --
  -- > threadDelay _ = yield
  threadDelay :: Int -> m ()
  threadDelay _ = yield

  -- | Create a new empty @MVar@.
  --
  -- > newEmptyMVar = newEmptyMVarN ""
  newEmptyMVar :: m (MVar m a)
  newEmptyMVar = newEmptyMVarN ""

  -- | Create a new empty @MVar@, but it is given a name which may be
  -- used to present more useful debugging information.
  --
  -- If an empty name is given, a counter starting from 0 is used. If
  -- names conflict, successive @MVar@s with the same name are given a
  -- numeric suffix, counting up from 1.
  --
  -- > newEmptyMVarN _ = newEmptyMVar
  newEmptyMVarN :: String -> m (MVar m a)
  newEmptyMVarN _ = newEmptyMVar

  -- | Put a value into a @MVar@. If there is already a value there,
  -- this will block until that value has been taken, at which point
  -- the value will be stored.
  putMVar :: MVar m a -> a -> m ()

  -- | Attempt to put a value in a @MVar@ non-blockingly, returning
  -- 'True' (and filling the @MVar@) if there was nothing there,
  -- otherwise returning 'False'.
  tryPutMVar :: MVar m a -> a -> m Bool

  -- | Block until a value is present in the @MVar@, and then return
  -- it. As with 'readMVar', this does not \"remove\" the value,
  -- multiple reads are possible.
  readMVar :: MVar m a -> m a

  -- | Take a value from a @MVar@. This \"empties\" the @MVar@,
  -- allowing a new value to be put in. This will block if there is no
  -- value in the @MVar@ already, until one has been put.
  takeMVar :: MVar m a -> m a

  -- | Attempt to take a value from a @MVar@ non-blockingly, returning
  -- a 'Just' (and emptying the @MVar@) if there was something there,
  -- otherwise returning 'Nothing'.
  tryTakeMVar :: MVar m a -> m (Maybe a)

  -- | Create a new reference.
  --
  -- > newCRef = newCRefN ""
  newCRef :: a -> m (CRef m a)
  newCRef = newCRefN ""

  -- | Create a new reference, but it is given a name which may be
  -- used to present more useful debugging information.
  --
  -- If an empty name is given, a counter starting from 0 is used. If
  -- names conflict, successive @CRef@s with the same name are given a
  -- numeric suffix, counting up from 1.
  --
  -- > newCRefN _ = newCRef
  newCRefN :: String -> a -> m (CRef m a)
  newCRefN _ = newCRef

  -- | Read the current value stored in a reference.
  --
  -- > readCRef cref = readForCAS cref >>= peekTicket
  readCRef :: CRef m a -> m a
  readCRef cref = readForCAS cref >>= peekTicket

  -- | Atomically modify the value stored in a reference. This imposes
  -- a full memory barrier.
  modifyCRef :: CRef m a -> (a -> (a, b)) -> m b

  -- | Write a new value into an @CRef@, without imposing a memory
  -- barrier. This means that relaxed memory effects can be observed.
  writeCRef :: CRef m a -> a -> m ()

  -- | Replace the value stored in a reference, with the
  -- barrier-to-reordering property that 'modifyCRef' has.
  --
  -- > atomicWriteCRef r a = modifyCRef r $ const (a, ())
  atomicWriteCRef :: CRef m a -> a -> m ()
  atomicWriteCRef r a = modifyCRef r $ const (a, ())

  -- | Read the current value stored in a reference, returning a
  -- @Ticket@, for use in future compare-and-swap operations.
  readForCAS :: CRef m a -> m (Ticket m a)

  -- | Extract the actual Haskell value from a @Ticket@.
  --
  -- This shouldn't need to do any monadic computation, the @m@
  -- appears in the result type because of the need for injectivity in
  -- the @Ticket@ type family, which can't be expressed currently.
  peekTicket :: Ticket m a -> m a

  -- | Perform a machine-level compare-and-swap (CAS) operation on a
  -- @CRef@. Returns an indication of success and a @Ticket@ for the
  -- most current value in the @CRef@.
  --
  -- This is strict in the \"new\" value argument.
  casCRef :: CRef m a -> Ticket m a -> a -> m (Bool, Ticket m a)

  -- | A replacement for 'modifyCRef' using a compare-and-swap.
  --
  -- This is strict in the \"new\" value argument.
  modifyCRefCAS :: CRef m a -> (a -> (a, b)) -> m b

  -- | A variant of 'modifyCRefCAS' which doesn't return a result.
  --
  -- > modifyCRefCAS_ cref f = modifyCRefCAS cref (\a -> (f a, ()))
  modifyCRefCAS_ :: CRef m a -> (a -> a) -> m ()
  modifyCRefCAS_ cref f = modifyCRefCAS cref (\a -> (f a, ()))

  -- | Perform an STM transaction atomically.
  atomically :: STM m a -> m a

  -- | Throw an exception to the target thread. This blocks until the
  -- exception is delivered, and it is just as if the target thread
  -- had raised it with 'throw'. This can interrupt a blocked action.
  throwTo :: Exception e => ThreadId m -> e -> m ()

  -- | Does nothing.
  --
  -- This function is purely for testing purposes, and indicates that
  -- the thread has a reference to the provided @MVar@ or @TVar@. This
  -- function may be called multiple times, to add new knowledge to
  -- the system. It does not need to be called when @MVar@s or @TVar@s
  -- are created, these get recorded automatically.
  --
  -- Gathering this information allows detection of cases where the
  -- main thread is blocked on a variable no runnable thread has a
  -- reference to, which is a deadlock situation.
  --
  -- > _concKnowsAbout _ = pure ()
  _concKnowsAbout :: Either (MVar m a) (TVar (STM m) a) -> m ()
  _concKnowsAbout _ = pure ()

  -- | Does nothing.
  --
  -- The counterpart to '_concKnowsAbout'. Indicates that the
  -- referenced variable will never be touched again by the current
  -- thread.
  --
  -- Note that inappropriate use of @_concForgets@ can result in false
  -- positives! Be very sure that the current thread will /never/
  -- refer to the variable again, for instance when leaving its scope.
  --
  -- > _concForgets _ = pure ()
  _concForgets :: Either (MVar m a) (TVar (STM m) a) -> m ()
  _concForgets _ = pure ()

  -- | Does nothing.
  --
  -- Indicates to the test runner that all variables which have been
  -- passed in to this thread have been recorded by calls to
  -- '_concKnowsAbout'. If every thread has called '_concAllKnown',
  -- then detection of nonglobal deadlock is turned on.
  --
  -- If a thread receives references to @MVar@s or @TVar@s in the
  -- future (for instance, if one was sent over a channel), then
  -- '_concKnowsAbout' should be called immediately, otherwise there
  -- is a risk of identifying false positives.
  --
  -- > _concAllKnown = pure ()
  _concAllKnown :: m ()
  _concAllKnown = pure ()

  -- | Does nothing.
  --
  -- During testing, records a message which shows up in the trace.
  --
  -- > _concMessage _ = pure ()
  _concMessage :: Typeable a => a -> m ()
  _concMessage _ = pure ()

-------------------------------------------------------------------------------
-- Utilities

-- | Get the current line number as a String. Useful for automatically
-- naming threads, @MVar@s, and @CRef@s.
--
-- Example usage:
--
-- > forkN $lineNum ...
--
-- Unfortunately this can't be packaged up into a
-- @forkL@/@forkOnL@/etc set of functions, because this imposes a
-- 'Lift' constraint on the monad, which 'IO' does not have.
lineNum :: Q Exp
lineNum = do
  line <- show . fst . loc_start <$> location
  [| line |]

-- Threads

-- | Create a concurrent computation for the provided action, and
-- return a @MVar@ which can be used to query the result.
spawn :: MonadConc m => m a -> m (MVar m a)
spawn ma = do
  cvar <- newEmptyMVar
  _ <- fork $ _concKnowsAbout (Left cvar) >> ma >>= putMVar cvar
  pure cvar

-- | Fork a thread and call the supplied function when the thread is
-- about to terminate, with an exception or a returned value. The
-- function is called with asynchronous exceptions masked.
--
-- This function is useful for informing the parent when a child
-- terminates, for example.
forkFinally :: MonadConc m => m a -> (Either SomeException a -> m ()) -> m (ThreadId m)
forkFinally action and_then =
  mask $ \restore ->
    fork $ Ca.try (restore action) >>= and_then

-- | Raise the 'ThreadKilled' exception in the target thread. Note
-- that if the thread is prepared to catch this exception, it won't
-- actually kill it.
killThread :: MonadConc m => ThreadId m -> m ()
killThread tid = throwTo tid ThreadKilled

-- | Like 'fork', but the thread is given a name which may be used to
-- present more useful debugging information.
--
-- If no name is given, the @ThreadId@ is used. If names conflict,
-- successive threads with the same name are given a numeric suffix,
-- counting up from 1.
forkN :: MonadConc m => String -> m () -> m (ThreadId m)
forkN name ma = forkWithUnmaskN name (\_ -> ma)

-- | Like 'forkOn', but the thread is given a name which may be used
-- to present more useful debugging information.
--
-- If no name is given, the @ThreadId@ is used. If names conflict,
-- successive threads with the same name are given a numeric suffix,
-- counting up from 1.
forkOnN :: MonadConc m => String -> Int -> m () -> m (ThreadId m)
forkOnN name i ma = forkOnWithUnmaskN name i (\_ -> ma)

-- Bound Threads

-- | Provided for compatibility, always returns 'False'.
rtsSupportsBoundThreads :: Bool
rtsSupportsBoundThreads = False

-- | Provided for compatibility, always returns 'False'.
isCurrentThreadBound :: MonadConc m => m Bool
isCurrentThreadBound = pure False

-- Exceptions

-- | Throw an exception. This will \"bubble up\" looking for an
-- exception handler capable of dealing with it and, if one is not
-- found, the thread is killed.
throw :: (MonadConc m, Exception e) => e -> m a
throw = Ca.throwM

-- | Catch an exception. This is only required to be able to catch
-- exceptions raised by 'throw', unlike the more general
-- Control.Exception.catch function. If you need to be able to catch
-- /all/ errors, you will have to use 'IO'.
catch :: (MonadConc m, Exception e) => m a -> (e -> m a) -> m a
catch = Ca.catch

-- | Executes a computation with asynchronous exceptions
-- /masked/. That is, any thread which attempts to raise an exception
-- in the current thread with 'throwTo' will be blocked until
-- asynchronous exceptions are unmasked again.
--
-- The argument passed to mask is a function that takes as its
-- argument another function, which can be used to restore the
-- prevailing masking state within the context of the masked
-- computation. This function should not be used within an
-- 'uninterruptibleMask'.
mask :: MonadConc m => ((forall a. m a -> m a) -> m b) -> m b
mask = Ca.mask

-- | Like 'mask', but the masked computation is not
-- interruptible. THIS SHOULD BE USED WITH GREAT CARE, because if a
-- thread executing in 'uninterruptibleMask' blocks for any reason,
-- then the thread (and possibly the program, if this is the main
-- thread) will be unresponsive and unkillable. This function should
-- only be necessary if you need to mask exceptions around an
-- interruptible operation, and you can guarantee that the
-- interruptible operation will only block for a short period of
-- time. The supplied unmasking function should not be used within a
-- 'mask'.
uninterruptibleMask :: MonadConc m => ((forall a. m a -> m a) -> m b) -> m b
uninterruptibleMask = Ca.uninterruptibleMask

-- Mutable Variables

-- | Create a new @MVar@ containing a value.
newMVar :: MonadConc m => a -> m (MVar m a)
newMVar a = do
  cvar <- newEmptyMVar
  putMVar cvar a
  pure cvar

-- | Create a new @MVar@ containing a value, but it is given a name
-- which may be used to present more useful debugging information.
--
-- If no name is given, a counter starting from 0 is used. If names
-- conflict, successive @MVar@s with the same name are given a numeric
-- suffix, counting up from 1.
newMVarN :: MonadConc m => String -> a -> m (MVar m a)
newMVarN n a = do
  cvar <- newEmptyMVarN n
  putMVar cvar a
  pure cvar

-- | Compare-and-swap a value in a @CRef@, returning an indication of
-- success and the new value.
cas :: MonadConc m => CRef m a -> a -> m (Bool, a)
cas cref a = do
  tick         <- readForCAS cref
  (suc, tick') <- casCRef cref tick a
  a'           <- peekTicket tick'

  pure (suc, a')

-------------------------------------------------------------------------------
-- Concrete instances

instance MonadConc IO where
  type STM      IO = IO.STM
  type MVar     IO = IO.MVar
  type CRef     IO = IO.IORef
  type Ticket   IO = IO.Ticket
  type ThreadId IO = IO.ThreadId

  fork   = IO.forkIO
  forkOn = IO.forkOn

  forkWithUnmask   = IO.forkIOWithUnmask
  forkOnWithUnmask = IO.forkOnWithUnmask

  getNumCapabilities = IO.getNumCapabilities
  setNumCapabilities = IO.setNumCapabilities
  readMVar           = IO.readMVar
  myThreadId         = IO.myThreadId
  yield              = IO.yield
  threadDelay        = IO.threadDelay
  throwTo            = IO.throwTo
  newEmptyMVar       = IO.newEmptyMVar
  putMVar            = IO.putMVar
  tryPutMVar         = IO.tryPutMVar
  takeMVar           = IO.takeMVar
  tryTakeMVar        = IO.tryTakeMVar
  newCRef            = IO.newIORef
  readCRef           = IO.readIORef
  modifyCRef         = IO.atomicModifyIORef
  writeCRef          = IO.writeIORef
  atomicWriteCRef    = IO.atomicWriteIORef
  readForCAS         = IO.readForCAS
  peekTicket         = pure . IO.peekTicket
  casCRef            = IO.casIORef
  modifyCRefCAS      = IO.atomicModifyIORefCAS
  atomically         = IO.atomically

-------------------------------------------------------------------------------
-- Transformer instances

instance MonadConc m => MonadConc (ReaderT r m) where
  type STM      (ReaderT r m) = STM m
  type MVar     (ReaderT r m) = MVar m
  type CRef     (ReaderT r m) = CRef m
  type Ticket   (ReaderT r m) = Ticket m
  type ThreadId (ReaderT r m) = ThreadId m

  fork   = liftedF id fork
  forkOn = liftedF id . forkOn

  forkWithUnmask        = liftedFork id forkWithUnmask
  forkWithUnmaskN   n   = liftedFork id (forkWithUnmaskN   n  )
  forkOnWithUnmask    i = liftedFork id (forkOnWithUnmask    i)
  forkOnWithUnmaskN n i = liftedFork id (forkOnWithUnmaskN n i)

  getNumCapabilities = lift getNumCapabilities
  setNumCapabilities = lift . setNumCapabilities
  myThreadId         = lift myThreadId
  yield              = lift yield
  threadDelay        = lift . threadDelay
  throwTo t          = lift . throwTo t
  newEmptyMVar       = lift newEmptyMVar
  newEmptyMVarN      = lift . newEmptyMVarN
  readMVar           = lift . readMVar
  putMVar v          = lift . putMVar v
  tryPutMVar v       = lift . tryPutMVar v
  takeMVar           = lift . takeMVar
  tryTakeMVar        = lift . tryTakeMVar
  newCRef            = lift . newCRef
  newCRefN n         = lift . newCRefN n
  readCRef           = lift . readCRef
  modifyCRef r       = lift . modifyCRef r
  writeCRef r        = lift . writeCRef r
  atomicWriteCRef r  = lift . atomicWriteCRef r
  readForCAS         = lift . readForCAS
  peekTicket         = lift . peekTicket
  casCRef r t        = lift . casCRef r t
  modifyCRefCAS r    = lift . modifyCRefCAS r
  atomically         = lift . atomically

  _concKnowsAbout = lift . _concKnowsAbout
  _concForgets    = lift . _concForgets
  _concAllKnown   = lift _concAllKnown
  _concMessage    = lift . _concMessage

instance (MonadConc m, Monoid w) => MonadConc (WL.WriterT w m) where
  type STM      (WL.WriterT w m) = STM m
  type MVar     (WL.WriterT w m) = MVar m
  type CRef     (WL.WriterT w m) = CRef m
  type Ticket   (WL.WriterT w m) = Ticket m
  type ThreadId (WL.WriterT w m) = ThreadId m

  fork   = liftedF fst fork
  forkOn = liftedF fst . forkOn

  forkWithUnmask        = liftedFork fst forkWithUnmask
  forkWithUnmaskN   n   = liftedFork fst (forkWithUnmaskN   n  )
  forkOnWithUnmask    i = liftedFork fst (forkOnWithUnmask    i)
  forkOnWithUnmaskN n i = liftedFork fst (forkOnWithUnmaskN n i)

  getNumCapabilities = lift getNumCapabilities
  setNumCapabilities = lift . setNumCapabilities
  myThreadId         = lift myThreadId
  yield              = lift yield
  threadDelay        = lift . threadDelay
  throwTo t          = lift . throwTo t
  newEmptyMVar       = lift newEmptyMVar
  newEmptyMVarN      = lift . newEmptyMVarN
  readMVar           = lift . readMVar
  putMVar v          = lift . putMVar v
  tryPutMVar v       = lift . tryPutMVar v
  takeMVar           = lift . takeMVar
  tryTakeMVar        = lift . tryTakeMVar
  newCRef            = lift . newCRef
  newCRefN n         = lift . newCRefN n
  readCRef           = lift . readCRef
  modifyCRef r       = lift . modifyCRef r
  writeCRef r        = lift . writeCRef r
  atomicWriteCRef r  = lift . atomicWriteCRef r
  readForCAS         = lift . readForCAS
  peekTicket         = lift . peekTicket
  casCRef r t        = lift . casCRef r t
  modifyCRefCAS r    = lift . modifyCRefCAS r
  atomically         = lift . atomically

  _concKnowsAbout = lift . _concKnowsAbout
  _concForgets    = lift . _concForgets
  _concAllKnown   = lift _concAllKnown
  _concMessage    = lift . _concMessage

instance (MonadConc m, Monoid w) => MonadConc (WS.WriterT w m) where
  type STM      (WS.WriterT w m) = STM m
  type MVar     (WS.WriterT w m) = MVar m
  type CRef     (WS.WriterT w m) = CRef m
  type Ticket   (WS.WriterT w m) = Ticket m
  type ThreadId (WS.WriterT w m) = ThreadId m

  fork   = liftedF fst fork
  forkOn = liftedF fst . forkOn

  forkWithUnmask        = liftedFork fst forkWithUnmask
  forkWithUnmaskN   n   = liftedFork fst (forkWithUnmaskN   n  )
  forkOnWithUnmask    i = liftedFork fst (forkOnWithUnmask    i)
  forkOnWithUnmaskN n i = liftedFork fst (forkOnWithUnmaskN n i)

  getNumCapabilities = lift getNumCapabilities
  setNumCapabilities = lift . setNumCapabilities
  myThreadId         = lift myThreadId
  yield              = lift yield
  threadDelay        = lift . threadDelay
  throwTo t          = lift . throwTo t
  newEmptyMVar       = lift newEmptyMVar
  newEmptyMVarN      = lift . newEmptyMVarN
  readMVar           = lift . readMVar
  putMVar v          = lift . putMVar v
  tryPutMVar v       = lift . tryPutMVar v
  takeMVar           = lift . takeMVar
  tryTakeMVar        = lift . tryTakeMVar
  newCRef            = lift . newCRef
  newCRefN n         = lift . newCRefN n
  readCRef           = lift . readCRef
  modifyCRef r       = lift . modifyCRef r
  writeCRef r        = lift . writeCRef r
  atomicWriteCRef r  = lift . atomicWriteCRef r
  readForCAS         = lift . readForCAS
  peekTicket         = lift . peekTicket
  casCRef r t        = lift . casCRef r t
  modifyCRefCAS r    = lift . modifyCRefCAS r
  atomically         = lift . atomically

  _concKnowsAbout = lift . _concKnowsAbout
  _concForgets    = lift . _concForgets
  _concAllKnown   = lift _concAllKnown
  _concMessage    = lift . _concMessage

instance MonadConc m => MonadConc (SL.StateT s m) where
  type STM      (SL.StateT s m) = STM m
  type MVar     (SL.StateT s m) = MVar m
  type CRef     (SL.StateT s m) = CRef m
  type Ticket   (SL.StateT s m) = Ticket m
  type ThreadId (SL.StateT s m) = ThreadId m

  fork   = liftedF fst fork
  forkOn = liftedF fst . forkOn

  forkWithUnmask        = liftedFork fst forkWithUnmask
  forkWithUnmaskN   n   = liftedFork fst (forkWithUnmaskN   n  )
  forkOnWithUnmask    i = liftedFork fst (forkOnWithUnmask    i)
  forkOnWithUnmaskN n i = liftedFork fst (forkOnWithUnmaskN n i)

  getNumCapabilities = lift getNumCapabilities
  setNumCapabilities = lift . setNumCapabilities
  myThreadId         = lift myThreadId
  yield              = lift yield
  threadDelay        = lift . threadDelay
  throwTo t          = lift . throwTo t
  newEmptyMVar       = lift newEmptyMVar
  newEmptyMVarN      = lift . newEmptyMVarN
  readMVar           = lift . readMVar
  putMVar v          = lift . putMVar v
  tryPutMVar v       = lift . tryPutMVar v
  takeMVar           = lift . takeMVar
  tryTakeMVar        = lift . tryTakeMVar
  newCRef            = lift . newCRef
  newCRefN n         = lift . newCRefN n
  readCRef           = lift . readCRef
  modifyCRef r       = lift . modifyCRef r
  writeCRef r        = lift . writeCRef r
  atomicWriteCRef r  = lift . atomicWriteCRef r
  readForCAS         = lift . readForCAS
  peekTicket         = lift . peekTicket
  casCRef r t        = lift . casCRef r t
  modifyCRefCAS r    = lift . modifyCRefCAS r
  atomically         = lift . atomically

  _concKnowsAbout = lift . _concKnowsAbout
  _concForgets    = lift . _concForgets
  _concAllKnown   = lift _concAllKnown
  _concMessage    = lift . _concMessage

instance MonadConc m => MonadConc (SS.StateT s m) where
  type STM      (SS.StateT s m) = STM m
  type MVar     (SS.StateT s m) = MVar m
  type CRef     (SS.StateT s m) = CRef m
  type Ticket   (SS.StateT s m) = Ticket m
  type ThreadId (SS.StateT s m) = ThreadId m

  fork   = liftedF fst fork
  forkOn = liftedF fst . forkOn

  forkWithUnmask        = liftedFork fst forkWithUnmask
  forkWithUnmaskN   n   = liftedFork fst (forkWithUnmaskN   n  )
  forkOnWithUnmask    i = liftedFork fst (forkOnWithUnmask    i)
  forkOnWithUnmaskN n i = liftedFork fst (forkOnWithUnmaskN n i)

  getNumCapabilities = lift getNumCapabilities
  setNumCapabilities = lift . setNumCapabilities
  myThreadId         = lift myThreadId
  yield              = lift yield
  threadDelay        = lift . threadDelay
  throwTo t          = lift . throwTo t
  newEmptyMVar       = lift newEmptyMVar
  newEmptyMVarN      = lift . newEmptyMVarN
  readMVar           = lift . readMVar
  putMVar v          = lift . putMVar v
  tryPutMVar v       = lift . tryPutMVar v
  takeMVar           = lift . takeMVar
  tryTakeMVar        = lift . tryTakeMVar
  newCRef            = lift . newCRef
  newCRefN n         = lift . newCRefN n
  readCRef           = lift . readCRef
  modifyCRef r       = lift . modifyCRef r
  writeCRef r        = lift . writeCRef r
  atomicWriteCRef r  = lift . atomicWriteCRef r
  readForCAS         = lift . readForCAS
  peekTicket         = lift . peekTicket
  casCRef r t        = lift . casCRef r t
  modifyCRefCAS r    = lift . modifyCRefCAS r
  atomically         = lift . atomically

  _concKnowsAbout = lift . _concKnowsAbout
  _concForgets    = lift . _concForgets
  _concAllKnown   = lift _concAllKnown
  _concMessage    = lift . _concMessage

instance (MonadConc m, Monoid w) => MonadConc (RL.RWST r w s m) where
  type STM      (RL.RWST r w s m) = STM m
  type MVar     (RL.RWST r w s m) = MVar m
  type CRef     (RL.RWST r w s m) = CRef m
  type Ticket   (RL.RWST r w s m) = Ticket m
  type ThreadId (RL.RWST r w s m) = ThreadId m

  fork   = liftedF (\(a,_,_) -> a) fork
  forkOn = liftedF (\(a,_,_) -> a) . forkOn

  forkWithUnmask        = liftedFork (\(a,_,_) -> a) forkWithUnmask
  forkWithUnmaskN   n   = liftedFork (\(a,_,_) -> a) (forkWithUnmaskN   n  )
  forkOnWithUnmask    i = liftedFork (\(a,_,_) -> a) (forkOnWithUnmask    i)
  forkOnWithUnmaskN n i = liftedFork (\(a,_,_) -> a) (forkOnWithUnmaskN n i)

  getNumCapabilities = lift getNumCapabilities
  setNumCapabilities = lift . setNumCapabilities
  myThreadId         = lift myThreadId
  yield              = lift yield
  threadDelay        = lift . threadDelay
  throwTo t          = lift . throwTo t
  newEmptyMVar       = lift newEmptyMVar
  newEmptyMVarN      = lift . newEmptyMVarN
  readMVar           = lift . readMVar
  putMVar v          = lift . putMVar v
  tryPutMVar v       = lift . tryPutMVar v
  takeMVar           = lift . takeMVar
  tryTakeMVar        = lift . tryTakeMVar
  newCRef            = lift . newCRef
  newCRefN n         = lift . newCRefN n
  readCRef           = lift . readCRef
  modifyCRef r       = lift . modifyCRef r
  writeCRef r        = lift . writeCRef r
  atomicWriteCRef r  = lift . atomicWriteCRef r
  readForCAS         = lift . readForCAS
  peekTicket         = lift . peekTicket
  casCRef r t        = lift . casCRef r t
  modifyCRefCAS r    = lift . modifyCRefCAS r
  atomically         = lift . atomically

  _concKnowsAbout = lift . _concKnowsAbout
  _concForgets    = lift . _concForgets
  _concAllKnown   = lift _concAllKnown
  _concMessage    = lift . _concMessage

instance (MonadConc m, Monoid w) => MonadConc (RS.RWST r w s m) where
  type STM      (RS.RWST r w s m) = STM m
  type MVar     (RS.RWST r w s m) = MVar m
  type CRef     (RS.RWST r w s m) = CRef m
  type Ticket   (RS.RWST r w s m) = Ticket m
  type ThreadId (RS.RWST r w s m) = ThreadId m

  fork   = liftedF (\(a,_,_) -> a) fork
  forkOn = liftedF (\(a,_,_) -> a) . forkOn

  forkWithUnmask        = liftedFork (\(a,_,_) -> a) forkWithUnmask
  forkWithUnmaskN   n   = liftedFork (\(a,_,_) -> a) (forkWithUnmaskN   n  )
  forkOnWithUnmask    i = liftedFork (\(a,_,_) -> a) (forkOnWithUnmask    i)
  forkOnWithUnmaskN n i = liftedFork (\(a,_,_) -> a) (forkOnWithUnmaskN n i)

  getNumCapabilities = lift getNumCapabilities
  setNumCapabilities = lift . setNumCapabilities
  myThreadId         = lift myThreadId
  yield              = lift yield
  threadDelay        = lift . threadDelay
  throwTo t          = lift . throwTo t
  newEmptyMVar       = lift newEmptyMVar
  newEmptyMVarN      = lift . newEmptyMVarN
  readMVar           = lift . readMVar
  putMVar v          = lift . putMVar v
  tryPutMVar v       = lift . tryPutMVar v
  takeMVar           = lift . takeMVar
  tryTakeMVar        = lift . tryTakeMVar
  newCRef            = lift . newCRef
  newCRefN n         = lift . newCRefN n
  readCRef           = lift . readCRef
  modifyCRef r       = lift . modifyCRef r
  writeCRef r        = lift . writeCRef r
  atomicWriteCRef r  = lift . atomicWriteCRef r
  readForCAS         = lift . readForCAS
  peekTicket         = lift . peekTicket
  casCRef r t        = lift . casCRef r t
  modifyCRefCAS r    = lift . modifyCRefCAS r
  atomically         = lift . atomically

  _concKnowsAbout = lift . _concKnowsAbout
  _concForgets    = lift . _concForgets
  _concAllKnown   = lift _concAllKnown
  _concMessage    = lift . _concMessage

-------------------------------------------------------------------------------

-- | Make an instance @MonadConc m => MonadConc (t m)@ for a given
-- transformer, @t@. The parameter should be the name of a function
-- @:: forall a. StT t a -> a@.
makeTransConc :: Name -> DecsQ
makeTransConc unstN = do
  unstI <- reify unstN
  case unstI of
    VarI _ (ForallT _ _ (AppT (AppT ArrowT (AppT (AppT (ConT _) t) _)) _)) _ _ ->
      [d|
        instance (MonadConc m) => MonadConc ($(pure t) m) where
          type STM      ($(pure t) m) = STM m
          type MVar     ($(pure t) m) = MVar m
          type CRef     ($(pure t) m) = CRef m
          type Ticket   ($(pure t) m) = Ticket m
          type ThreadId ($(pure t) m) = ThreadId m

          fork   = liftedF $(varE unstN) fork
          forkOn = liftedF $(varE unstN) . forkOn

          forkWithUnmask        = liftedFork $(varE unstN) forkWithUnmask
          forkWithUnmaskN   n   = liftedFork $(varE unstN) (forkWithUnmaskN   n  )
          forkOnWithUnmask    i = liftedFork $(varE unstN) (forkOnWithUnmask    i)
          forkOnWithUnmaskN n i = liftedFork $(varE unstN) (forkOnWithUnmaskN n i)

          getNumCapabilities = lift getNumCapabilities
          setNumCapabilities = lift . setNumCapabilities
          myThreadId         = lift myThreadId
          yield              = lift yield
          threadDelay        = lift . threadDelay
          throwTo tid        = lift . throwTo tid
          newEmptyMVar       = lift newEmptyMVar
          newEmptyMVarN      = lift . newEmptyMVarN
          readMVar           = lift . readMVar
          putMVar v          = lift . putMVar v
          tryPutMVar v       = lift . tryPutMVar v
          takeMVar           = lift . takeMVar
          tryTakeMVar        = lift . tryTakeMVar
          newCRef            = lift . newCRef
          newCRefN n         = lift . newCRefN n
          readCRef           = lift . readCRef
          modifyCRef r       = lift . modifyCRef r
          writeCRef r        = lift . writeCRef r
          atomicWriteCRef r  = lift . atomicWriteCRef r
          readForCAS         = lift . readForCAS
          peekTicket         = lift . peekTicket
          casCRef r tick     = lift . casCRef r tick
          modifyCRefCAS r    = lift . modifyCRefCAS r
          atomically         = lift . atomically

          _concKnowsAbout = lift . _concKnowsAbout
          _concForgets    = lift . _concForgets
          _concAllKnown   = lift _concAllKnown
          _concMessage    = lift . _concMessage
      |]
    _ -> fail "Expected a value of type (forall a -> StT t a -> a)"

-- | Given a function to remove the transformer-specific state, lift
-- a function invocation.
liftedF :: (MonadTransControl t, MonadConc m)
  => (forall x. StT t x -> x)
  -> (m a -> m b)
  -> t m a
  -> t m b
liftedF unst f ma = liftWith $ \run -> f (unst <$> run ma)

-- | Given a function to remove the transformer-specific state, lift
-- a @fork(on)WithUnmask@ invocation.
liftedFork :: (MonadTransControl t, MonadConc m)
  => (forall x. StT t x -> x)
  -> (((forall x. m x -> m x) -> m a) -> m b)
  -> ((forall x. t m x -> t m x) -> t m a)
  -> t m b
liftedFork unst f ma = liftWith $ \run ->
  f (\unmask -> unst <$> run (ma $ liftedF unst unmask))
