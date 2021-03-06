-- |
-- Module      : Test.DejaFu.Common
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : portable
--
-- Common types and functions used throughout DejaFu. This module is
-- NOT considered to form part of the public interface of this
-- library.
module Test.DejaFu.Common
  ( -- * Identifiers
    ThreadId(..)
  , CRefId(..)
  , MVarId(..)
  , TVarId(..)
  , initialThread
  -- ** Identifier source
  , IdSource(..)
  , nextCRId
  , nextMVId
  , nextTVId
  , nextTId
  , initialIdSource

  -- * Actions
  -- ** Thread actions
  , ThreadAction(..)
  , isBlock
  , tvarsOf
  -- ** Lookahead
  , Lookahead(..)
  , rewind
  , willRelease
  -- ** Simplified actions
  , ActionType(..)
  , isBarrier
  , isCommit
  , synchronises
  , crefOf
  , mvarOf
  , simplifyAction
  , simplifyLookahead
  -- ** STM actions
  , TTrace
  , TAction(..)

  -- * Traces
  , Trace
  , Decision(..)
  , showTrace
  , preEmpCount

  -- * Failures
  , Failure(..)
  , showFail

  -- * Memory models
  , MemType(..)
  ) where

import Control.DeepSeq (NFData(..))
import Control.Exception (MaskingState(..))
import Data.List (sort, nub, intercalate)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as S

-------------------------------------------------------------------------------
-- Identifiers

-- | Every live thread has a unique identitifer.
data ThreadId = ThreadId (Maybe String) Int
  deriving Eq

instance Ord ThreadId where
  compare (ThreadId _ i) (ThreadId _ j) = compare i j

instance Show ThreadId where
  show (ThreadId (Just n) _) = n
  show (ThreadId Nothing  i) = show i

instance NFData ThreadId where
  rnf (ThreadId n i) = rnf (n, i)

-- | Every @CRef@ has a unique identifier.
data CRefId = CRefId (Maybe String) Int
  deriving Eq

instance Ord CRefId where
  compare (CRefId _ i) (CRefId _ j) = compare i j

instance Show CRefId where
  show (CRefId (Just n) _) = n
  show (CRefId Nothing  i) = show i

instance NFData CRefId where
  rnf (CRefId n i) = rnf (n, i)

-- | Every @MVar@ has a unique identifier.
data MVarId = MVarId (Maybe String) Int
  deriving Eq

instance Ord MVarId where
  compare (MVarId _ i) (MVarId _ j) = compare i j

instance Show MVarId where
  show (MVarId (Just n) _) = n
  show (MVarId Nothing  i) = show i

instance NFData MVarId where
  rnf (MVarId n i) = rnf (n, i)

-- | Every @TVar@ has a unique identifier.
data TVarId = TVarId (Maybe String) Int
  deriving Eq

instance Ord TVarId where
  compare (TVarId _ i) (TVarId _ j) = compare i j

instance Show TVarId where
  show (TVarId (Just n) _) = n
  show (TVarId Nothing  i) = show i

instance NFData TVarId where
  rnf (TVarId n i) = rnf (n, i)

-- | The ID of the initial thread.
initialThread :: ThreadId
initialThread = ThreadId (Just "main") 0

---------------------------------------
-- Identifier source

-- | The number of ID parameters was getting a bit unwieldy, so this
-- hides them all away.
data IdSource = Id
  { _nextCRId  :: Int
  , _nextMVId  :: Int
  , _nextTVId  :: Int
  , _nextTId   :: Int
  , _usedCRNames :: [String]
  , _usedMVNames :: [String]
  , _usedTVNames :: [String]
  , _usedTNames  :: [String]
  } deriving (Eq, Ord, Show)

instance NFData IdSource where
  rnf idsource = rnf ( _nextCRId idsource
                     , _nextMVId idsource
                     , _nextTVId idsource
                     , _nextTId  idsource
                     , _usedCRNames idsource
                     , _usedMVNames idsource
                     , _usedTVNames idsource
                     , _usedTNames  idsource
                     )

-- | Get the next free 'CRefId'.
nextCRId :: String -> IdSource -> (IdSource, CRefId)
nextCRId name idsource = (newIdSource, newCRId) where
  newIdSource = idsource { _nextCRId = newId, _usedCRNames = newUsed }
  newCRId     = CRefId newName newId
  newId       = _nextCRId idsource + 1
  (newName, newUsed) = nextId name (_usedCRNames idsource)

-- | Get the next free 'MVarId'.
nextMVId :: String -> IdSource -> (IdSource, MVarId)
nextMVId name idsource = (newIdSource, newMVId) where
  newIdSource = idsource { _nextMVId = newId, _usedMVNames = newUsed }
  newMVId     = MVarId newName newId
  newId       = _nextMVId idsource + 1
  (newName, newUsed) = nextId name (_usedMVNames idsource)

-- | Get the next free 'TVarId'.
nextTVId :: String -> IdSource -> (IdSource, TVarId)
nextTVId name idsource = (newIdSource, newTVId) where
  newIdSource = idsource { _nextTVId = newId, _usedTVNames = newUsed }
  newTVId     = TVarId newName newId
  newId       = _nextTVId idsource + 1
  (newName, newUsed) = nextId name (_usedTVNames idsource)

-- | Get the next free 'ThreadId'.
nextTId :: String -> IdSource -> (IdSource, ThreadId)
nextTId name idsource = (newIdSource, newTId) where
  newIdSource = idsource { _nextTId = newId, _usedTNames = newUsed }
  newTId      = ThreadId newName newId
  newId       = _nextTId idsource + 1
  (newName, newUsed) = nextId name (_usedTNames idsource)

-- | The initial ID source.
initialIdSource :: IdSource
initialIdSource = Id 0 0 0 0 [] [] [] []

-------------------------------------------------------------------------------
-- Actions

---------------------------------------
-- Thread actions

-- | All the actions that a thread can perform.
data ThreadAction =
    Fork ThreadId
  -- ^ Start a new thread.
  | MyThreadId
  -- ^ Get the 'ThreadId' of the current thread.
  | GetNumCapabilities Int
  -- ^ Get the number of Haskell threads that can run simultaneously.
  | SetNumCapabilities Int
  -- ^ Set the number of Haskell threads that can run simultaneously.
  | Yield
  -- ^ Yield the current thread.
  | NewMVar MVarId
  -- ^ Create a new 'MVar'.
  | PutMVar MVarId [ThreadId]
  -- ^ Put into a 'MVar', possibly waking up some threads.
  | BlockedPutMVar MVarId
  -- ^ Get blocked on a put.
  | TryPutMVar MVarId Bool [ThreadId]
  -- ^ Try to put into a 'MVar', possibly waking up some threads.
  | ReadMVar MVarId
  -- ^ Read from a 'MVar'.
  | TryReadMVar MVarId Bool
  -- ^ Try to read from a 'MVar'.
  | BlockedReadMVar MVarId
  -- ^ Get blocked on a read.
  | TakeMVar MVarId [ThreadId]
  -- ^ Take from a 'MVar', possibly waking up some threads.
  | BlockedTakeMVar MVarId
  -- ^ Get blocked on a take.
  | TryTakeMVar MVarId Bool [ThreadId]
  -- ^ Try to take from a 'MVar', possibly waking up some threads.
  | NewCRef CRefId
  -- ^ Create a new 'CRef'.
  | ReadCRef CRefId
  -- ^ Read from a 'CRef'.
  | ReadCRefCas CRefId
  -- ^ Read from a 'CRef' for a future compare-and-swap.
  | ModCRef CRefId
  -- ^ Modify a 'CRef'.
  | ModCRefCas CRefId
  -- ^ Modify a 'CRef' using a compare-and-swap.
  | WriteCRef CRefId
  -- ^ Write to a 'CRef' without synchronising.
  | CasCRef CRefId Bool
  -- ^ Attempt to to a 'CRef' using a compare-and-swap, synchronising
  -- it.
  | CommitCRef ThreadId CRefId
  -- ^ Commit the last write to the given 'CRef' by the given thread,
  -- so that all threads can see the updated value.
  | STM TTrace [ThreadId]
  -- ^ An STM transaction was executed, possibly waking up some
  -- threads.
  | BlockedSTM TTrace
  -- ^ Got blocked in an STM transaction.
  | Catching
  -- ^ Register a new exception handler
  | PopCatching
  -- ^ Pop the innermost exception handler from the stack.
  | Throw
  -- ^ Throw an exception.
  | ThrowTo ThreadId
  -- ^ Throw an exception to a thread.
  | BlockedThrowTo ThreadId
  -- ^ Get blocked on a 'throwTo'.
  | Killed
  -- ^ Killed by an uncaught exception.
  | SetMasking Bool MaskingState
  -- ^ Set the masking state. If 'True', this is being used to set the
  -- masking state to the original state in the argument passed to a
  -- 'mask'ed function.
  | ResetMasking Bool MaskingState
  -- ^ Return to an earlier masking state.  If 'True', this is being
  -- used to return to the state of the masked block in the argument
  -- passed to a 'mask'ed function.
  | LiftIO
  -- ^ Lift an IO action. Note that this can only happen with
  -- 'ConcIO'.
  | Return
  -- ^ A 'return' or 'pure' action was executed.
  | Stop
  -- ^ Cease execution and terminate.
  | Subconcurrency
  -- ^ Start executing an action with @subconcurrency@.
  | StopSubconcurrency
  -- ^ Stop executing an action with @subconcurrency@.
  deriving (Eq, Show)

instance NFData ThreadAction where
  rnf (Fork t) = rnf t
  rnf (GetNumCapabilities c) = rnf c
  rnf (SetNumCapabilities c) = rnf c
  rnf (NewMVar m) = rnf m
  rnf (PutMVar m ts) = rnf (m, ts)
  rnf (BlockedPutMVar m) = rnf m
  rnf (TryPutMVar m b ts) = rnf (m, b, ts)
  rnf (ReadMVar m) = rnf m
  rnf (TryReadMVar m b) = rnf (m, b)
  rnf (BlockedReadMVar m) = rnf m
  rnf (TakeMVar m ts) = rnf (m, ts)
  rnf (BlockedTakeMVar m) = rnf m
  rnf (TryTakeMVar m b ts) = rnf (m, b, ts)
  rnf (NewCRef c) = rnf c
  rnf (ReadCRef c) = rnf c
  rnf (ReadCRefCas c) = rnf c
  rnf (ModCRef c) = rnf c
  rnf (ModCRefCas c) = rnf c
  rnf (WriteCRef c) = rnf c
  rnf (CasCRef c b) = rnf (c, b)
  rnf (CommitCRef t c) = rnf (t, c)
  rnf (STM tr ts) = rnf (tr, ts)
  rnf (BlockedSTM tr) = rnf tr
  rnf (ThrowTo t) = rnf t
  rnf (BlockedThrowTo t) = rnf t
  rnf (SetMasking b m) = b `seq` m `seq` ()
  rnf (ResetMasking b m) = b `seq` m `seq` ()
  rnf a = a `seq` ()

-- | Check if a @ThreadAction@ immediately blocks.
isBlock :: ThreadAction -> Bool
isBlock (BlockedThrowTo  _) = True
isBlock (BlockedTakeMVar _) = True
isBlock (BlockedReadMVar _) = True
isBlock (BlockedPutMVar  _) = True
isBlock (BlockedSTM _) = True
isBlock _ = False

-- | Get the @TVar@s affected by a @ThreadAction@.
tvarsOf :: ThreadAction -> Set TVarId
tvarsOf act = S.fromList $ case act of
  STM trc _ -> concatMap tvarsOf' trc
  BlockedSTM trc -> concatMap tvarsOf' trc
  _ -> []

  where
    tvarsOf' (TRead  tv) = [tv]
    tvarsOf' (TWrite tv) = [tv]
    tvarsOf' (TOrElse ta tb) = concatMap tvarsOf' (ta ++ fromMaybe [] tb)
    tvarsOf' (TCatch  ta tb) = concatMap tvarsOf' (ta ++ fromMaybe [] tb)
    tvarsOf' _ = []

---------------------------------------
-- Lookahead

-- | A one-step look-ahead at what a thread will do next.
data Lookahead =
    WillFork
  -- ^ Will start a new thread.
  | WillMyThreadId
  -- ^ Will get the 'ThreadId'.
  | WillGetNumCapabilities
  -- ^ Will get the number of Haskell threads that can run
  -- simultaneously.
  | WillSetNumCapabilities Int
  -- ^ Will set the number of Haskell threads that can run
  -- simultaneously.
  | WillYield
  -- ^ Will yield the current thread.
  | WillNewMVar
  -- ^ Will create a new 'MVar'.
  | WillPutMVar MVarId
  -- ^ Will put into a 'MVar', possibly waking up some threads.
  | WillTryPutMVar MVarId
  -- ^ Will try to put into a 'MVar', possibly waking up some threads.
  | WillReadMVar MVarId
  -- ^ Will read from a 'MVar'.
  | WillTryReadMVar MVarId
  -- ^ Will try to read from a 'MVar'.
  | WillTakeMVar MVarId
  -- ^ Will take from a 'MVar', possibly waking up some threads.
  | WillTryTakeMVar MVarId
  -- ^ Will try to take from a 'MVar', possibly waking up some threads.
  | WillNewCRef
  -- ^ Will create a new 'CRef'.
  | WillReadCRef CRefId
  -- ^ Will read from a 'CRef'.
  | WillReadCRefCas CRefId
  -- ^ Will read from a 'CRef' for a future compare-and-swap.
  | WillModCRef CRefId
  -- ^ Will modify a 'CRef'.
  | WillModCRefCas CRefId
  -- ^ Will modify a 'CRef' using a compare-and-swap.
  | WillWriteCRef CRefId
  -- ^ Will write to a 'CRef' without synchronising.
  | WillCasCRef CRefId
  -- ^ Will attempt to to a 'CRef' using a compare-and-swap,
  -- synchronising it.
  | WillCommitCRef ThreadId CRefId
  -- ^ Will commit the last write by the given thread to the 'CRef'.
  | WillSTM
  -- ^ Will execute an STM transaction, possibly waking up some
  -- threads.
  | WillCatching
  -- ^ Will register a new exception handler
  | WillPopCatching
  -- ^ Will pop the innermost exception handler from the stack.
  | WillThrow
  -- ^ Will throw an exception.
  | WillThrowTo ThreadId
  -- ^ Will throw an exception to a thread.
  | WillSetMasking Bool MaskingState
  -- ^ Will set the masking state. If 'True', this is being used to
  -- set the masking state to the original state in the argument
  -- passed to a 'mask'ed function.
  | WillResetMasking Bool MaskingState
  -- ^ Will return to an earlier masking state.  If 'True', this is
  -- being used to return to the state of the masked block in the
  -- argument passed to a 'mask'ed function.
  | WillLiftIO
  -- ^ Will lift an IO action. Note that this can only happen with
  -- 'ConcIO'.
  | WillReturn
  -- ^ Will execute a 'return' or 'pure' action.
  | WillStop
  -- ^ Will cease execution and terminate.
  | WillSubconcurrency
  -- ^ Will execute an action with @subconcurrency@.
  | WillStopSubconcurrency
  -- ^ Will stop executing an extion with @subconcurrency@.
  deriving (Eq, Show)

instance NFData Lookahead where
  rnf (WillSetNumCapabilities c) = rnf c
  rnf (WillPutMVar m) = rnf m
  rnf (WillTryPutMVar m) = rnf m
  rnf (WillReadMVar m) = rnf m
  rnf (WillTryReadMVar m) = rnf m
  rnf (WillTakeMVar m) = rnf m
  rnf (WillTryTakeMVar m) = rnf m
  rnf (WillReadCRef c) = rnf c
  rnf (WillReadCRefCas c) = rnf c
  rnf (WillModCRef c) = rnf c
  rnf (WillModCRefCas c) = rnf c
  rnf (WillWriteCRef c) = rnf c
  rnf (WillCasCRef c) = rnf c
  rnf (WillCommitCRef t c) = rnf (t, c)
  rnf (WillThrowTo t) = rnf t
  rnf (WillSetMasking b m) = b `seq` m `seq` ()
  rnf (WillResetMasking b m) = b `seq` m `seq` ()
  rnf l = l `seq` ()

-- | Convert a 'ThreadAction' into a 'Lookahead': \"rewind\" what has
-- happened. 'Killed' has no 'Lookahead' counterpart.
rewind :: ThreadAction -> Maybe Lookahead
rewind (Fork _) = Just WillFork
rewind MyThreadId = Just WillMyThreadId
rewind (GetNumCapabilities _) = Just WillGetNumCapabilities
rewind (SetNumCapabilities i) = Just (WillSetNumCapabilities i)
rewind Yield = Just WillYield
rewind (NewMVar _) = Just WillNewMVar
rewind (PutMVar c _) = Just (WillPutMVar c)
rewind (BlockedPutMVar c) = Just (WillPutMVar c)
rewind (TryPutMVar c _ _) = Just (WillTryPutMVar c)
rewind (ReadMVar c) = Just (WillReadMVar c)
rewind (BlockedReadMVar c) = Just (WillReadMVar c)
rewind (TryReadMVar c _) = Just (WillTryReadMVar c)
rewind (TakeMVar c _) = Just (WillTakeMVar c)
rewind (BlockedTakeMVar c) = Just (WillTakeMVar c)
rewind (TryTakeMVar c _ _) = Just (WillTryTakeMVar c)
rewind (NewCRef _) = Just WillNewCRef
rewind (ReadCRef c) = Just (WillReadCRef c)
rewind (ReadCRefCas c) = Just (WillReadCRefCas c)
rewind (ModCRef c) = Just (WillModCRef c)
rewind (ModCRefCas c) = Just (WillModCRefCas c)
rewind (WriteCRef c) = Just (WillWriteCRef c)
rewind (CasCRef c _) = Just (WillCasCRef c)
rewind (CommitCRef t c) = Just (WillCommitCRef t c)
rewind (STM _ _) = Just WillSTM
rewind (BlockedSTM _) = Just WillSTM
rewind Catching = Just WillCatching
rewind PopCatching = Just WillPopCatching
rewind Throw = Just WillThrow
rewind (ThrowTo t) = Just (WillThrowTo t)
rewind (BlockedThrowTo t) = Just (WillThrowTo t)
rewind Killed = Nothing
rewind (SetMasking b m) = Just (WillSetMasking b m)
rewind (ResetMasking b m) = Just (WillResetMasking b m)
rewind LiftIO = Just WillLiftIO
rewind Return = Just WillReturn
rewind Stop = Just WillStop
rewind Subconcurrency = Just WillSubconcurrency
rewind StopSubconcurrency = Just WillStopSubconcurrency

-- | Check if an operation could enable another thread.
willRelease :: Lookahead -> Bool
willRelease WillFork = True
willRelease WillYield = True
willRelease (WillPutMVar _) = True
willRelease (WillTryPutMVar _) = True
willRelease (WillReadMVar _) = True
willRelease (WillTakeMVar _) = True
willRelease (WillTryTakeMVar _) = True
willRelease WillSTM = True
willRelease WillThrow = True
willRelease (WillSetMasking _ _) = True
willRelease (WillResetMasking _ _) = True
willRelease WillStop = True
willRelease _ = False

---------------------------------------
-- Simplified actions

-- | A simplified view of the possible actions a thread can perform.
data ActionType =
    UnsynchronisedRead  CRefId
  -- ^ A 'readCRef' or a 'readForCAS'.
  | UnsynchronisedWrite CRefId
  -- ^ A 'writeCRef'.
  | UnsynchronisedOther
  -- ^ Some other action which doesn't require cross-thread
  -- communication.
  | PartiallySynchronisedCommit CRefId
  -- ^ A commit.
  | PartiallySynchronisedWrite  CRefId
  -- ^ A 'casCRef'
  | PartiallySynchronisedModify CRefId
  -- ^ A 'modifyCRefCAS'
  | SynchronisedModify  CRefId
  -- ^ An 'atomicModifyCRef'.
  | SynchronisedRead    MVarId
  -- ^ A 'readMVar' or 'takeMVar' (or @try@/@blocked@ variants).
  | SynchronisedWrite   MVarId
  -- ^ A 'putMVar' (or @try@/@blocked@ variant).
  | SynchronisedOther
  -- ^ Some other action which does require cross-thread
  -- communication.
  deriving (Eq, Show)

instance NFData ActionType where
  rnf (UnsynchronisedRead c) = rnf c
  rnf (UnsynchronisedWrite c) = rnf c
  rnf (PartiallySynchronisedCommit c) = rnf c
  rnf (PartiallySynchronisedWrite c) = rnf c
  rnf (PartiallySynchronisedModify c) = rnf c
  rnf (SynchronisedModify c) = rnf c
  rnf (SynchronisedRead m) = rnf m
  rnf (SynchronisedWrite m) = rnf m
  rnf a = a `seq` ()

-- | Check if an action imposes a write barrier.
isBarrier :: ActionType -> Bool
isBarrier (SynchronisedModify _) = True
isBarrier (SynchronisedRead   _) = True
isBarrier (SynchronisedWrite  _) = True
isBarrier SynchronisedOther = True
isBarrier _ = False

-- | Check if an action commits a given 'CRef'.
isCommit :: ActionType -> CRefId -> Bool
isCommit (PartiallySynchronisedCommit c) r = c == r
isCommit (PartiallySynchronisedWrite  c) r = c == r
isCommit (PartiallySynchronisedModify c) r = c == r
isCommit _ _ = False

-- | Check if an action synchronises a given 'CRef'.
synchronises :: ActionType -> CRefId -> Bool
synchronises a r = isCommit a r || isBarrier a

-- | Get the 'CRef' affected.
crefOf :: ActionType -> Maybe CRefId
crefOf (UnsynchronisedRead  r) = Just r
crefOf (UnsynchronisedWrite r) = Just r
crefOf (SynchronisedModify  r) = Just r
crefOf (PartiallySynchronisedCommit r) = Just r
crefOf (PartiallySynchronisedWrite  r) = Just r
crefOf (PartiallySynchronisedModify r) = Just r
crefOf _ = Nothing

-- | Get the 'MVar' affected.
mvarOf :: ActionType -> Maybe MVarId
mvarOf (SynchronisedRead  c) = Just c
mvarOf (SynchronisedWrite c) = Just c
mvarOf _ = Nothing

-- | Throw away information from a 'ThreadAction' and give a
-- simplified view of what is happening.
--
-- This is used in the SCT code to help determine interesting
-- alternative scheduling decisions.
simplifyAction :: ThreadAction -> ActionType
simplifyAction = maybe UnsynchronisedOther simplifyLookahead . rewind

-- | Variant of 'simplifyAction' that takes a 'Lookahead'.
simplifyLookahead :: Lookahead -> ActionType
simplifyLookahead (WillPutMVar c)     = SynchronisedWrite c
simplifyLookahead (WillTryPutMVar c)  = SynchronisedWrite c
simplifyLookahead (WillReadMVar c)    = SynchronisedRead c
simplifyLookahead (WillTryReadMVar c) = SynchronisedRead c
simplifyLookahead (WillTakeMVar c)    = SynchronisedRead c
simplifyLookahead (WillTryTakeMVar c)  = SynchronisedRead c
simplifyLookahead (WillReadCRef r)     = UnsynchronisedRead r
simplifyLookahead (WillReadCRefCas r)  = UnsynchronisedRead r
simplifyLookahead (WillModCRef r)      = SynchronisedModify r
simplifyLookahead (WillModCRefCas r)   = PartiallySynchronisedModify r
simplifyLookahead (WillWriteCRef r)    = UnsynchronisedWrite r
simplifyLookahead (WillCasCRef r)      = PartiallySynchronisedWrite r
simplifyLookahead (WillCommitCRef _ r) = PartiallySynchronisedCommit r
simplifyLookahead WillSTM         = SynchronisedOther
simplifyLookahead (WillThrowTo _) = SynchronisedOther
simplifyLookahead _ = UnsynchronisedOther

---------------------------------------
-- STM actions

-- | A trace of an STM transaction is just a list of actions that
-- occurred, as there are no scheduling decisions to make.
type TTrace = [TAction]

-- | All the actions that an STM transaction can perform.
data TAction =
    TNew
  -- ^ Create a new @TVar@
  | TRead  TVarId
  -- ^ Read from a @TVar@.
  | TWrite TVarId
  -- ^ Write to a @TVar@.
  | TRetry
  -- ^ Abort and discard effects.
  | TOrElse TTrace (Maybe TTrace)
  -- ^ Execute a transaction until it succeeds (@STMStop@) or aborts
  -- (@STMRetry@) and, if it aborts, execute the other transaction.
  | TThrow
  -- ^ Throw an exception, abort, and discard effects.
  | TCatch TTrace (Maybe TTrace)
  -- ^ Execute a transaction until it succeeds (@STMStop@) or aborts
  -- (@STMThrow@). If the exception is of the appropriate type, it is
  -- handled and execution continues; otherwise aborts, propagating
  -- the exception upwards.
  | TStop
  -- ^ Terminate successfully and commit effects.
  deriving (Eq, Show)

instance NFData TAction where
  rnf (TRead t) = rnf t
  rnf (TWrite t) = rnf t
  rnf (TOrElse tr mtr) = rnf (tr, mtr)
  rnf (TCatch tr mtr) = rnf (tr, mtr)
  rnf ta = ta `seq` ()

-------------------------------------------------------------------------------
-- Traces

-- | One of the outputs of the runner is a @Trace@, which is a log of
-- decisions made, all the runnable threads and what they would do,
-- and the action a thread took in its step.
type Trace
  = [(Decision, [(ThreadId, NonEmpty Lookahead)], ThreadAction)]

-- | Scheduling decisions are based on the state of the running
-- program, and so we can capture some of that state in recording what
-- specific decision we made.
data Decision =
    Start ThreadId
  -- ^ Start a new thread, because the last was blocked (or it's the
  -- start of computation).
  | Continue
  -- ^ Continue running the last thread for another step.
  | SwitchTo ThreadId
  -- ^ Pre-empt the running thread, and switch to another.
  deriving (Eq, Show)

instance NFData Decision where
  rnf (Start t) = rnf t
  rnf (SwitchTo t) = rnf t
  rnf d = d `seq` ()

-- | Pretty-print a trace, including a key of the thread IDs (not
-- including thread 0). Each line of the key is indented by two
-- spaces.
showTrace :: Trace -> String
showTrace trc = intercalate "\n" $ concatMap go trc : strkey where
  go (_,_,CommitCRef _ _) = "C-"
  go (Start    (ThreadId _ i),_,_) = "S" ++ show i ++ "-"
  go (SwitchTo (ThreadId _ i),_,_) = "P" ++ show i ++ "-"
  go (Continue,_,_) = "-"

  strkey = ["  " ++ show i ++ ": " ++ name | (i, name) <- key]

  key = sort . nub $ mapMaybe toKey trc where
    toKey (Start (ThreadId (Just name) i), _, _)
      | i > 0 = Just (i, name)
    toKey _ = Nothing

-- | Count the number of pre-emptions in a schedule prefix.
--
-- Commit threads complicate this a bit. Conceptually, commits are
-- happening truly in parallel, nondeterministically. The commit
-- thread implementation is just there to unify the two sources of
-- nondeterminism: commit timing and thread scheduling.
--
-- SO, we don't count a switch TO a commit thread as a
-- preemption. HOWEVER, the switch FROM a commit thread counts as a
-- preemption if it is not to the thread that the commit interrupted.
preEmpCount :: [(Decision, ThreadAction)]
            -> (Decision, Lookahead)
            -> Int
preEmpCount (x:xs) (d, _) = go initialThread x xs where
  go _ (_, Yield) (r@(SwitchTo t, _):rest) = go t r rest
  go tid prior (r@(SwitchTo t, _):rest)
    | isCommitThread t = go tid prior (skip rest)
    | otherwise = 1 + go t r rest
  go _   _ (r@(Start t,  _):rest) = go t   r rest
  go tid _ (r@(Continue, _):rest) = go tid r rest
  go _ prior [] = case (prior, d) of
    ((_, Yield), SwitchTo _) -> 0
    (_, SwitchTo _) -> 1
    _ -> 0

  -- Commit threads have negative thread IDs for easy identification.
  isCommitThread = (< initialThread)

  -- Skip until the next context switch.
  skip = dropWhile (not . isContextSwitch . fst)
  isContextSwitch Continue = False
  isContextSwitch _ = True
preEmpCount [] _ = 0

-------------------------------------------------------------------------------
-- Failures


-- | An indication of how a concurrent computation failed.
data Failure =
    InternalError
  -- ^ Will be raised if the scheduler does something bad. This should
  -- never arise unless you write your own, faulty, scheduler! If it
  -- does, please file a bug report.
  | Abort
  -- ^ The scheduler chose to abort execution. This will be produced
  -- if, for example, all possible decisions exceed the specified
  -- bounds (there have been too many pre-emptions, the computation
  -- has executed for too long, or there have been too many yields).
  | Deadlock
  -- ^ The computation became blocked indefinitely on @MVar@s.
  | STMDeadlock
  -- ^ The computation became blocked indefinitely on @TVar@s.
  | UncaughtException
  -- ^ An uncaught exception bubbled to the top of the computation.
  | IllegalSubconcurrency
  -- ^ Calls to @subconcurrency@ were nested, or attempted when
  -- multiple threads existed.
  deriving (Eq, Show, Read, Ord, Enum, Bounded)

instance NFData Failure where
  rnf f = f `seq` ()

-- | Pretty-print a failure
showFail :: Failure -> String
showFail Abort = "[abort]"
showFail Deadlock = "[deadlock]"
showFail STMDeadlock = "[stm-deadlock]"
showFail InternalError = "[internal-error]"
showFail UncaughtException = "[exception]"
showFail IllegalSubconcurrency = "[illegal-subconcurrency]"

-------------------------------------------------------------------------------
-- Memory Models

-- | The memory model to use for non-synchronised 'CRef' operations.
data MemType =
    SequentialConsistency
  -- ^ The most intuitive model: a program behaves as a simple
  -- interleaving of the actions in different threads. When a 'CRef'
  -- is written to, that write is immediately visible to all threads.
  | TotalStoreOrder
  -- ^ Each thread has a write buffer. A thread sees its writes
  -- immediately, but other threads will only see writes when they are
  -- committed, which may happen later. Writes are committed in the
  -- same order that they are created.
  | PartialStoreOrder
  -- ^ Each 'CRef' has a write buffer. A thread sees its writes
  -- immediately, but other threads will only see writes when they are
  -- committed, which may happen later. Writes to different 'CRef's
  -- are not necessarily committed in the same order that they are
  -- created.
  deriving (Eq, Show, Read, Ord, Enum, Bounded)

instance NFData MemType where
  rnf m = m `seq` ()

-------------------------------------------------------------------------------
-- Utilities

-- | Helper for @next*@
nextId :: String -> [String] -> (Maybe String, [String])
nextId name used = (newName, newUsed) where
  newName
    | null name = Nothing
    | occurrences > 0 = Just (name ++ "-" ++ show occurrences)
    | otherwise = Just name
  newUsed
    | null name = used
    | otherwise = name : used
  occurrences = length (filter (==name) used)
