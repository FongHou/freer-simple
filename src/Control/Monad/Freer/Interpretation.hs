{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE MonoLocalBinds        #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeOperators         #-}

module Control.Monad.Freer.Interpretation where

import           Control.Monad.Freer.Internal
import           Control.Monad.Morph (MFunctor (..))
import           Control.Monad.Trans.Class (MonadTrans (..))
import           Control.Monad.Trans.Cont
import qualified Control.Monad.Trans.Except as E
import qualified Control.Monad.Trans.State.Strict as S
import           Data.OpenUnion.Internal


------------------------------------------------------------------------------
-- | Interpret as an effect in terms of another effect in the stack.
natural
    :: Member eff' r
    => (eff ~> eff')
    -> Eff (eff ': r) ~> Eff r
natural = naturally id
{-# INLINE natural #-}


------------------------------------------------------------------------------
-- | Interpret an effect as a monadic action in 'Eff r'.
interpret :: (eff ~> Eff r) -> Eff (eff ': r) ~> Eff r
interpret f (Freer m) = Freer $ \k -> m $ \u ->
  case decomp u of
    Left x -> k x
    Right y -> runFreer (f y) k
{-# INLINE[3] interpret #-}


------------------------------------------------------------------------------
-- | Like 'interpret', but with access to intermediate state.
stateful
    :: (eff ~> S.StateT s (Eff r))
    -> s
    -> Eff (eff ': r) a -> Eff r (a, s)
stateful f s (Freer m) = Freer $ \k -> flip S.runStateT s $ m $ \u ->
  case decomp u of
    Left  x -> lift $ k x
    Right y -> hoist (usingFreer k) $ f y
{-# INLINE stateful #-}
-- NB: @stateful f s = transform (flip S.runStateT s) f@, but is not
-- implemented as such, since 'transform' is available only >= 8.6.0


------------------------------------------------------------------------------
-- | Like 'interpret', but with access to intermediate state.
withStateful
    :: s
    -> (eff ~> S.StateT s (Eff r))
    -> Eff (eff ': r) a -> Eff r (a, s)
withStateful s f = stateful f s
{-# INLINE withStateful #-}


------------------------------------------------------------------------------
-- | Replace the topmost layer of the effect stack with another. This is often
-- useful for interpreters which would like to introduce some intermediate
-- effects before immediately handling them.
replace
    :: (eff1 ~> eff2)
    -> Eff (eff1 ': r) ~> Eff (eff2 ': r)
replace = naturally weaken
{-# INLINE replace #-}


#if __GLASGOW_HASKELL__ >= 806
------------------------------------------------------------------------------
-- | Run an effect via the side-effects of a monad transformer.
transform
    :: ( MonadTrans t
       , MFunctor t
       , forall m. Monad m => Monad (t m)
       )
    => (forall m. Monad m => t m a -> m b)
       -- ^ The strategy for getting out of the monad transformer.
    -> (eff ~> t (Eff r))
    -> Eff (eff ': r) a
    -> Eff r b
transform lower f (Freer m) = Freer $ \k -> lower $ m $ \u ->
  case decomp u of
    Left  x -> lift $ k x
    Right y -> hoist (usingFreer k) $ f y
{-# INLINE[3] transform #-}
#endif


------------------------------------------------------------------------------
-- | Run an effect, potentially short circuiting in its evaluation.
shortCircuit
    :: (eff ~> E.ExceptT e (Eff r))
    -> Eff (eff ': r) a
    -> Eff r (Either e a)
shortCircuit f (Freer m) = Freer $ \k -> E.runExceptT $ m $ \u ->
  case decomp u of
    Left  x -> lift $ k x
    Right y -> hoist (usingFreer k) $ f y
{-# INLINE shortCircuit #-}
-- NB: @shortCircuit = transform E.runExceptT@, but is not implemented as such,
-- since 'transform' is available only >= 8.6.0


------------------------------------------------------------------------------
-- | Intercept an effect without removing it from the effect stack.
intercept
    :: Member eff r
    => (eff ~> Eff r)
    -> Eff r ~> Eff r
intercept f (Freer m) = Freer $ \k -> m $ \u ->
  case prj u of
    Nothing -> k u
    Just e  -> usingFreer k $ f e
{-# INLINE intercept #-}

------------------------------------------------------------------------------
-- | Like 'interpret', but with access to intermediate state.
interceptS
    :: Member eff r
    => (eff ~> S.StateT s (Eff r))
    -> s
    -> Eff r a -> Eff r (a, s)
interceptS f s (Freer m) = Freer $ \k ->
  usingFreer k $ flip S.runStateT s $ m $ \u ->
    case prj u of
      Nothing -> lift $ liftEff u
      Just e  -> f e
{-# INLINE interceptS #-}


------------------------------------------------------------------------------
-- | Run an effect with an explicit continuation to the final result. If you're
-- not sure why you might need this, you probably don't.
--
-- Note that this method is slow---roughly 10x slower than the other combinators
-- available here. If you just need short circuiting, consider using
-- 'shortCircuit' instead.
relay
    :: (a -> Eff r b)
    -> (forall x. eff x -> (x -> Eff r b) -> Eff r b)
    -> Eff (eff ': r) a
    -> Eff r b
relay pure' bind' (Freer m) = Freer $ \k ->
  usingFreer k $ flip runContT pure' $ m $ \u ->
    case decomp u of
      Left  x -> lift $ liftEff x
      Right y -> ContT $ bind' y
{-# INLINE relay #-}


------------------------------------------------------------------------------
-- | Like 'interpret' and 'relay'.
interceptRelay
    :: Member eff r
    => (a -> Eff r b)
    -> (forall x. eff x -> (x -> Eff r b) -> Eff r b)
    -> Eff r a
    -> Eff r b
interceptRelay pure' bind' (Freer m) = Freer $ \k ->
  usingFreer k $ flip runContT pure' $ m $ \u ->
    case prj u of
      Nothing -> lift $ liftEff u
      Just y  -> ContT $ bind' y
{-# INLINE interceptRelay #-}


------------------------------------------------------------------------------
-- | Run an effect, potentially changing the entire effect stack underneath it.
naturally
    :: Member eff' r'
    => (Union r ~> Union r')
    -> (eff ~> eff')
    -> Eff (eff ': r) ~> Eff r'
naturally z f (Freer m) = Freer $ \k -> m $ \u ->
  case decomp u of
    Left x  -> k $ z x
    Right y -> k . inj $ f y
{-# INLINE naturally #-}


------------------------------------------------------------------------------
-- | Introduce a new effect directly underneath the top of the stack. This is
-- often useful for interpreters which would like to introduce some intermediate
-- effects before immediately handling them.
--
-- Also see 'replace'.
introduce :: Eff (eff ': r) a -> Eff (eff ': u ': r) a
introduce = hoistEff intro1
{-# INLINE introduce #-}

introduce2 :: Eff (eff ': r) a -> Eff (eff ': u ': v ': r) a
introduce2 = hoistEff intro2
{-# INLINE introduce2 #-}

introduce3 :: Eff (eff ': r) a -> Eff (eff ': u ': v ': x ': r) a
introduce3 = hoistEff intro3
{-# INLINE introduce3 #-}

introduce4 :: Eff (eff ': r) a -> Eff (eff ': u ': v ':x ': y ': r) a
introduce4 = hoistEff intro4
{-# INLINE introduce4 #-}


------------------------------------------------------------------------------

{-# RULES

"interpret/send"
  forall (f :: f ~> g).
    interpret (\e -> send (f e)) = natural f
    ;

"interpret/send/id pointfree"
    interpret send = natural id
    ;

"interpret/send/id"
    interpret (\e -> send e) = natural id
    ;

-- "transform/transform"
--   forall (m :: Eff (eff1 ': eff2 ': r) a)
--          (lower1 :: forall m. Monad m => t1 m a -> m b)
--          (f1 :: eff1 ~> t1 (Eff (eff2 ': r)))
--          (lower2 :: forall m. Monad m => t2 m b -> m c)
--          (f2 :: eff2 ~> t2 (Eff r)).
--     transform lower2 f2 (transform lower1 f1 m) = transform (lower2 . lower1) (f2 . f1) m
--     ;

#-}


