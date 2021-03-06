{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      : Test.DejaFu.SCT
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : GeneralizedNewtypeDeriving
--
-- Systematic testing for concurrent computations.
module Test.DejaFu.SCT
  ( -- * Running Concurrent Programs
    Way(..)
  , runSCT
  , runSCT'
  , resultsSet
  , resultsSet'

  -- * Bounded Partial-order Reduction

  -- | We can characterise the state of a concurrent computation by
  -- considering the ordering of dependent events. This is a partial
  -- order: independent events can be performed in any order without
  -- affecting the result, and so are /not/ ordered.
  --
  -- Partial-order reduction is a technique for computing these
  -- partial orders, and only testing one total order for each partial
  -- order. This cuts down the amount of work to be done
  -- significantly. /Bounded/ partial-order reduction is a further
  -- optimisation, which only considers schedules within some bound.
  --
  -- This module provides a combination pre-emption, fair, and length
  -- bounding runner:
  --
  -- * Pre-emption + fair bounding is useful for programs which use
  --   loop/yield control flows but are otherwise terminating.
  --
  -- * Pre-emption, fair + length bounding is useful for
  --   non-terminating programs, and used by the testing functionality
  --   in @Test.DejaFu@.
  --
  -- See /Bounded partial-order reduction/, K. Coons, M. Musuvathi,
  -- K. McKinley for more details.

  , Bounds(..)
  , noBounds
  , sctBound

  -- ** Pre-emption Bounding

  -- | BPOR using pre-emption bounding. This adds conservative
  -- backtracking points at the prior context switch whenever a
  -- non-conervative backtracking point is added, as alternative
  -- decisions can influence the reachability of different states.
  --
  -- See the BPOR paper for more details.

  , PreemptionBound(..)
  , sctPreBound

  -- ** Fair Bounding

  -- | BPOR using fair bounding. This bounds the maximum difference
  -- between the number of yield operations different threads have
  -- performed.
  --
  -- See the BPOR paper for more details.

  , FairBound(..)
  , sctFairBound

  -- ** Length Bounding

  -- | BPOR using length bounding. This bounds the maximum length (in
  -- terms of primitive actions) of an execution.

  , LengthBound(..)
  , sctLengthBound

  -- * Random Scheduling

  -- | By greatly sacrificing completeness, testing of a large
  -- concurrent system can be greatly sped-up. Counter-intuitively,
  -- random scheduling has better bug-finding behaviour than just
  -- executing a program \"for real\" many times. This is perhaps
  -- because a random scheduler is more chaotic than the real
  -- scheduler.

  , sctRandom
  ) where

import Control.DeepSeq (NFData(..))
import Control.Monad.Ref (MonadRef)
import Data.List (foldl')
import qualified Data.Map.Strict as M
import Data.Maybe (fromJust)
import Data.Set (Set)
import qualified Data.Set as S
import System.Random (RandomGen)

import Test.DejaFu.Common
import Test.DejaFu.Conc
import Test.DejaFu.SCT.Internal

-------------------------------------------------------------------------------
-- Running Concurrent Programs

-- | How to explore the possible executions of a concurrent program.
data Way g
  = Systematically Bounds
  -- ^ Systematically explore all executions within the bounds.
  | Randomly g Int
  -- ^ Explore a fixed number of random executions, with the given
  -- PRNG.
  deriving (Eq, Ord, Read, Show)

instance NFData g => NFData (Way g) where
  rnf (Systematically bs) = rnf bs
  rnf (Randomly g n) = rnf (g, n)

-- | Explore possible executions of a concurrent program.
--
-- * If the 'Way' is @Systematically@, 'sctBound' is used.
--
-- * If the 'Way' is @Randomly@, 'sctRandom' is used.
runSCT :: (MonadRef r n, RandomGen g)
  => Way g
  -- ^ How to run the concurrent program.
  -> MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> Conc n r a
  -- ^ The computation to run many times.
  -> n [(Either Failure a, Trace)]
runSCT (Systematically cb) memtype = sctBound memtype cb
runSCT (Randomly g lim)    memtype = sctRandom memtype g lim

-- | A strict variant of 'runSCT'.
--
-- Demanding the result of this will force it to normal form, which
-- may be more efficient in some situations.
runSCT' :: (MonadRef r n, RandomGen g, NFData a)
  => Way g -> MemType -> Conc n r a -> n [(Either Failure a, Trace)]
runSCT' way memtype conc = do
  res <- runSCT way memtype conc
  rnf res `seq` pure res

-- | Return the set of results of a concurrent program.
resultsSet :: (MonadRef r n, RandomGen g, Ord a)
  => Way g
  -- ^ How to run the concurrent program.
  -> MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> Conc n r a
  -- ^ The computation to run many times.
  -> n (Set (Either Failure a))
resultsSet way memtype conc =
  S.fromList . map fst <$> runSCT way memtype conc

-- | A strict variant of 'resultsSet'.
--
-- Demanding the result of this will force it to normal form, which
-- may be more efficient in some situations.
resultsSet' :: (MonadRef r n, RandomGen g, Ord a, NFData a)
  => Way g -> MemType -> Conc n r a -> n (Set (Either Failure a))
resultsSet' way memtype conc = do
  res <- resultsSet' way memtype conc
  rnf res `seq` pure res

-------------------------------------------------------------------------------
-- Combined Bounds

data Bounds = Bounds
  { boundPreemp :: Maybe PreemptionBound
  , boundFair   :: Maybe FairBound
  , boundLength :: Maybe LengthBound
  } deriving (Eq, Ord, Read, Show)

instance NFData Bounds where
  rnf bs = rnf ( boundPreemp bs
               , boundFair   bs
               , boundLength bs
               )

-- | No bounds enabled. This forces the scheduler to just use
-- partial-order reduction and sleep sets to prune the search
-- space. This will /ONLY/ work if your computation always terminates!
noBounds :: Bounds
noBounds = Bounds
  { boundPreemp = Nothing
  , boundFair   = Nothing
  , boundLength = Nothing
  }

-- | Combination bound function
cBound :: Bounds -> BoundFunc
cBound (Bounds pb fb lb) =
  maybe trueBound pBound pb &+&
  maybe trueBound fBound fb &+&
  maybe trueBound lBound lb

-- | Combination backtracking function. Add all backtracking points
-- corresponding to enabled bound functions.
--
-- If no bounds are enabled, just backtrack to the given point.
cBacktrack :: Bounds -> BacktrackFunc
cBacktrack (Bounds (Just _) _ _) = pBacktrack
cBacktrack (Bounds _ (Just _) _) = fBacktrack
cBacktrack (Bounds _ _ (Just _)) = lBacktrack
cBacktrack _ = backtrackAt (\_ _ -> False)

-------------------------------------------------------------------------------
-- Pre-emption bounding

newtype PreemptionBound = PreemptionBound Int
  deriving (Enum, Eq, Ord, Num, Real, Integral, Read, Show, NFData)

-- | An SCT runner using a pre-emption bounding scheduler.
sctPreBound :: MonadRef r n
  => MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> PreemptionBound
  -- ^ The maximum number of pre-emptions to allow in a single
  -- execution
  -> Conc n r a
  -- ^ The computation to run many times
  -> n [(Either Failure a, Trace)]
sctPreBound memtype pb = sctBound memtype $ Bounds (Just pb) Nothing Nothing

-- | Pre-emption bound function. This does not count pre-emptive
-- context switches to a commit thread.
pBound :: PreemptionBound -> BoundFunc
pBound (PreemptionBound pb) ts dl = preEmpCount ts dl <= pb

-- | Add a backtrack point, and also conservatively add one prior to
-- the most recent transition before that point. This may result in
-- the same state being reached multiple times, but is needed because
-- of the artificial dependency imposed by the bound.
pBacktrack :: BacktrackFunc
pBacktrack bs = backtrackAt (\_ _ -> False) bs . concatMap addConservative where
  addConservative o@(i, _, tid) = o : case conservative i of
    Just j  -> [(j, True, tid)]
    Nothing -> []

  -- index of conservative point
  conservative i = go (reverse (take (i-1) bs)) (i-1) where
    go _ (-1) = Nothing
    go (b1:rest@(b2:_)) j
      | bcktThreadid b1 /= bcktThreadid b2
        && not (isCommitRef $ bcktAction b1)
        && not (isCommitRef $ bcktAction b2) = Just j
      | otherwise = go rest (j-1)
    go _ _ = Nothing

-------------------------------------------------------------------------------
-- Fair bounding

newtype FairBound = FairBound Int
  deriving (Enum, Eq, Ord, Num, Real, Integral, Read, Show, NFData)

-- | An SCT runner using a fair bounding scheduler.
sctFairBound :: MonadRef r n
  => MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> FairBound
  -- ^ The maximum difference between the number of yield operations
  -- performed by different threads.
  -> Conc n r a
  -- ^ The computation to run many times
  -> n [(Either Failure a, Trace)]
sctFairBound memtype fb = sctBound memtype $ Bounds Nothing (Just fb) Nothing

-- | Fair bound function
fBound :: FairBound -> BoundFunc
fBound (FairBound fb) ts (_, l) = maxYieldCountDiff ts l <= fb

-- | Add a backtrack point. If the thread isn't runnable, or performs
-- a release operation, add all runnable threads.
fBacktrack :: BacktrackFunc
fBacktrack = backtrackAt check where
  -- True if a release operation is performed.
  check t b = Just True == (willRelease <$> M.lookup t (bcktRunnable b))

-------------------------------------------------------------------------------
-- Length bounding

newtype LengthBound = LengthBound Int
  deriving (Enum, Eq, Ord, Num, Real, Integral, Read, Show, NFData)

-- | An SCT runner using a length bounding scheduler.
sctLengthBound :: MonadRef r n
  => MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> LengthBound
  -- ^ The maximum length of a schedule, in terms of primitive
  -- actions.
  -> Conc n r a
  -- ^ The computation to run many times
  -> n [(Either Failure a, Trace)]
sctLengthBound memtype lb = sctBound memtype $ Bounds Nothing Nothing (Just lb)

-- | Length bound function
lBound :: LengthBound -> BoundFunc
lBound (LengthBound lb) ts _ = length ts < lb

-- | Add a backtrack point. If the thread isn't runnable, add all
-- runnable threads.
lBacktrack :: BacktrackFunc
lBacktrack = backtrackAt (\_ _ -> False)

-------------------------------------------------------------------------------
-- Systematic concurrency testing

-- | SCT via BPOR.
--
-- Schedules are generated by running the computation with a
-- deterministic scheduler with some initial list of decisions. At
-- each step of execution, possible-conflicting actions are looked
-- for, if any are found, \"backtracking points\" are added, to cause
-- the events to happen in a different order in a future execution.
--
-- Note that unlike with non-bounded partial-order reduction, this may
-- do some redundant work as the introduction of a bound can make
-- previously non-interfering events interfere with each other.
sctBound :: MonadRef r n
  => MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> Bounds
  -- ^ The combined bounds.
  -> Conc n r a
  -- ^ The computation to run many times
  -> n [(Either Failure a, Trace)]
sctBound memtype cb conc = go initialState where
  -- Repeatedly run the computation gathering all the results and
  -- traces into a list until there are no schedules remaining to try.
  go dp = case nextPrefix dp of
    Just (prefix, conservative, sleep) -> do
      (res, s, trace) <- runConcurrent scheduler
                                       memtype
                                       (initialDPORSchedState sleep prefix)
                                       conc

      let bpoints = findBacktracks (schedBoundKill s) (schedBPoints s) trace
      let newDPOR = addTrace conservative trace dp

      if schedIgnore s
      then go newDPOR
      else ((res, trace):) <$> go (addBacktracks bpoints newDPOR)

    Nothing -> pure []

  -- Find the next schedule prefix.
  nextPrefix = findSchedulePrefix (>=initialThread)

  -- The DPOR scheduler.
  scheduler = dporSched memtype (cBound cb)

  -- Find the new backtracking steps.
  findBacktracks = findBacktrackSteps memtype (cBacktrack cb)

  -- Incorporate a trace into the DPOR tree.
  addTrace = incorporateTrace memtype

  -- Incorporate the new backtracking steps into the DPOR tree.
  addBacktracks = incorporateBacktrackSteps (cBound cb)

-- | SCT via random scheduling.
--
-- Schedules are generated by assigning to each new thread a random
-- weight. Threads are then scheduled by a weighted random selection.
--
-- This is not guaranteed to find all distinct results.
sctRandom :: (MonadRef r n, RandomGen g)
  => MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> g
  -- ^ The random number generator.
  -> Int
  -- ^ The number of executions to perform.
  -> Conc n r a
  -- ^ The computation to run many times.
  -> n [(Either Failure a, Trace)]
sctRandom memtype g0 lim0 conc = go g0 lim0 where
  go _ 0 = pure []
  go g n = do
    (res, s, trace) <- runConcurrent randSched
                                     memtype
                                     (initialRandSchedState g)
                                     conc

    ((res, trace):) <$> go (schedGen s) (n-1)

-------------------------------------------------------------------------------
-- Utilities

-- | Determine if an action is a commit or not.
isCommitRef :: ThreadAction -> Bool
isCommitRef (CommitCRef _ _) = True
isCommitRef _ = False

-- | Extra threads created in a fork.
forkTids :: ThreadAction -> [ThreadId]
forkTids (Fork t) = [t]
forkTids _ = []

-- | Count the number of yields by a thread in a schedule prefix.
yieldCount :: ThreadId
  -- ^ The thread to count yields for.
  -> [(Decision, ThreadAction)]
  -> Lookahead
  -> Int
yieldCount tid ts l = go initialThread ts where
  go t ((Start    t', act):rest) = go' t t' act rest
  go t ((SwitchTo t', act):rest) = go' t t' act rest
  go t ((Continue,    act):rest) = go' t t  act rest
  go t []
    | t == tid && willYield l = 1
    | otherwise = 0

  {-# INLINE go' #-}
  go' t t' act rest
    | t == tid && didYield act = 1 + go t' rest
    | otherwise = go t' rest

-- | Get the maximum difference between the yield counts of all
-- threads in this schedule prefix.
maxYieldCountDiff :: [(Decision, ThreadAction)]
  -> Lookahead
  -> Int
maxYieldCountDiff ts l = go 0 yieldCounts where
  go m (yc:ycs) =
    let m' = m `max` foldl' (go' yc) 0 ycs
    in go m' ycs
  go m [] = m
  go' yc0 m yc = m `max` abs (yc0 - yc)

  yieldCounts = [yieldCount t ts l | t <- allTids ts]

  -- All the threads created during the lifetime of the system.
  allTids ((_, act):rest) =
    let tids' = forkTids act
    in if null tids' then allTids rest else tids' ++ allTids rest
  allTids [] = [initialThread]

-- | The \"true\" bound, which allows everything.
trueBound :: BoundFunc
trueBound _ _ = True

-- | Combine two bounds into a larger bound, where both must be
-- satisfied.
(&+&) :: BoundFunc -> BoundFunc -> BoundFunc
(&+&) b1 b2 ts dl = b1 ts dl && b2 ts dl
