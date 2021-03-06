{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Control.Monad.STM.Class
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : CPP, RankNTypes, TemplateHaskell, TypeFamilies
--
-- This module provides an abstraction over 'STM', which can be used
-- with 'MonadConc'.
--
-- This module only defines the 'STM' class; you probably want to
-- import "Control.Concurrent.Classy.STM" (which exports
-- "Control.Monad.STM.Class").
--
-- __Deviations:__ An instance of @MonadSTM@ is not required to be an
-- @Alternative@, @MonadPlus@, and @MonadFix@, unlike @STM@. The
-- @always@ and @alwaysSucceeds@ functions are not provided; if you
-- need these file an issue and I'll look into it.
module Control.Monad.STM.Class
  ( MonadSTM(..)
  , check
  , throwSTM
  , catchSTM

  -- * Utilities for instance writers
  , liftedOrElse
  ) where

import Control.Exception (Exception)
import Control.Monad (unless)
import Control.Monad.Reader (ReaderT)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Control (MonadTransControl, StT, liftWith)
import Control.Monad.Trans.Identity (IdentityT)

import qualified Control.Concurrent.STM as STM
import qualified Control.Monad.Catch as Ca
import qualified Control.Monad.RWS.Lazy as RL
import qualified Control.Monad.RWS.Strict as RS
import qualified Control.Monad.State.Lazy as SL
import qualified Control.Monad.State.Strict as SS
import qualified Control.Monad.Writer.Lazy as WL
import qualified Control.Monad.Writer.Strict as WS

-- | @MonadSTM@ is an abstraction over 'STM'.
--
-- This class does not provide any way to run transactions, rather
-- each 'MonadConc' has an associated @MonadSTM@ from which it can
-- atomically run a transaction.
class Ca.MonadCatch stm => MonadSTM stm where
  {-# MINIMAL
        retry
      , orElse
      , (newTVar | newTVarN)
      , readTVar
      , writeTVar
    #-}

  -- | The mutable reference type. These behave like 'TVar's, in that
  -- they always contain a value and updates are non-blocking and
  -- synchronised.
  type TVar stm :: * -> *

  -- | Retry execution of this transaction because it has seen values
  -- in @TVar@s that it shouldn't have. This will result in the
  -- thread running the transaction being blocked until any @TVar@s
  -- referenced in it have been mutated.
  retry :: stm a

  -- | Run the first transaction and, if it @retry@s, run the second
  -- instead. If the monad is an instance of
  -- 'Alternative'/'MonadPlus', 'orElse' should be the '(<|>)'/'mplus'
  -- function.
  orElse :: stm a -> stm a -> stm a

  -- | Create a new @TVar@ containing the given value.
  --
  -- > newTVar = newTVarN ""
  newTVar :: a -> stm (TVar stm a)
  newTVar = newTVarN ""

  -- | Create a new @TVar@ containing the given value, but it is
  -- given a name which may be used to present more useful debugging
  -- information.
  --
  -- If an empty name is given, a counter starting from 0 is used. If
  -- names conflict, successive @TVar@s with the same name are given
  -- a numeric suffix, counting up from 1.
  --
  -- > newTVarN _ = newTVar
  newTVarN :: String -> a -> stm (TVar stm a)
  newTVarN _ = newTVar

  -- | Return the current value stored in a @TVar@.
  readTVar :: TVar stm a -> stm a

  -- | Write the supplied value into the @TVar@.
  writeTVar :: TVar stm a -> a -> stm ()

-- | Check whether a condition is true and, if not, call @retry@.
check :: MonadSTM stm => Bool -> stm ()
check b = unless b retry

-- | Throw an exception. This aborts the transaction and propagates
-- the exception.
throwSTM :: (MonadSTM stm, Exception e) => e -> stm a
throwSTM = Ca.throwM

-- | Handling exceptions from 'throwSTM'.
catchSTM :: (MonadSTM stm, Exception e) => stm a -> (e -> stm a) -> stm a
catchSTM = Ca.catch

instance MonadSTM STM.STM where
  type TVar STM.STM = STM.TVar

  retry     = STM.retry
  orElse    = STM.orElse
  newTVar   = STM.newTVar
  readTVar  = STM.readTVar
  writeTVar = STM.writeTVar

-------------------------------------------------------------------------------
-- Transformer instances

#define INSTANCE(T,C,F)                                  \
instance C => MonadSTM (T stm) where { \
  type TVar (T stm) = TVar stm      ; \
                                      \
  retry       = lift retry          ; \
  orElse      = liftedOrElse F      ; \
  newTVar     = lift . newTVar      ; \
  newTVarN n  = lift . newTVarN n   ; \
  readTVar    = lift . readTVar     ; \
  writeTVar v = lift . writeTVar v  }

INSTANCE(ReaderT r, MonadSTM stm, id)

INSTANCE(IdentityT, MonadSTM stm, id)

INSTANCE(WL.WriterT w, (MonadSTM stm, Monoid w), fst)
INSTANCE(WS.WriterT w, (MonadSTM stm, Monoid w), fst)

INSTANCE(SL.StateT s, MonadSTM stm, fst)
INSTANCE(SS.StateT s, MonadSTM stm, fst)

INSTANCE(RL.RWST r w s, (MonadSTM stm, Monoid w), (\(a,_,_) -> a))
INSTANCE(RS.RWST r w s, (MonadSTM stm, Monoid w), (\(a,_,_) -> a))

#undef INSTANCE

-------------------------------------------------------------------------------

-- | Given a function to remove the transformer-specific state, lift
-- an @orElse@ invocation.
liftedOrElse :: (MonadTransControl t, MonadSTM stm)
  => (forall x. StT t x -> x)
  -> t stm a -> t stm a -> t stm a
liftedOrElse unst ma mb = liftWith $ \run ->
  let ma' = unst <$> run ma
      mb' = unst <$> run mb
  in ma' `orElse` mb'
