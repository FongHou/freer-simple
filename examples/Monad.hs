module Monad where

import Control.Monad (ap, join)
import Prelude

-----------------------------------------------------------------------------
-- Free Monad

data Free f a
  = Pure a
  | Join (f (Free f a))

newtype F f a = F
  {runF :: forall r. (f r -> r) -> (a -> r) -> r}
  deriving (Functor)

instance Monad (F f) where
  return a = F $ \_ return' -> return' a
  m >>= f = F $ \alg return' -> runF m alg (\a -> runF (f a) alg return')

fromF :: F f a -> Free f a
fromF (F f) = f Join Pure

foldF :: Monad m => (forall x. f x -> m x) -> F f a -> m a
foldF alg (F f) = f (join . alg) pure

-----------------------------------------------------------------------------
-- Freer Monad

newtype Eff f a = Eff
  {foldEff :: forall m. Monad m => (forall x. f x -> m x) -> m a}

instance Monad (Eff f) where
  return a = Eff $ \_ -> return a
  m >>= f = Eff $ \alg -> foldEff m alg >>= (\a -> foldEff (f a) alg)

-----------------------------------------------------------------------------
-- Effect Handler

data Monad' f a where
  Return :: a -> Monad' f a
  Bind :: f a -> (a -> Monad' f b) -> Monad' f b

data State' s a where
  Get :: State' s s
  Put :: s -> State' s ()

runState' :: s -> Monad' (State' s) a -> (s, a)
runState' s (Return x) = (s, x)
runState' s (Get `Bind` k) = runState' s (k s)
runState' _ (Put s `Bind` k) = runState' s (k ())

-----------------------------------------------------------------------------
-- https://blog.poisson.chat/posts/2019-10-26-reasonable-continuations.html

newtype Cont r a = Cont {(>>-) :: (a -> r) -> r}
  deriving (Functor)

instance Monad (Cont r) where
  return a = Cont $ \return' -> return' a
  m >>= f = Cont $ \return' -> m >>- (\a -> f a >>- return')

runC :: Cont r r -> r
runC m = m >>- id

reset :: Cont a a -> Cont r a
reset = return . runC

shift :: ((a -> r) -> Cont r r) -> Cont r a
shift f = Cont (runC . f)

type Pure a = forall r. Cont r a

runPure :: Pure a -> a
runPure (Cont m) = m id

type Except e a = forall r. Cont (Either e r) a

runExcept :: Except e a -> Either e a
runExcept (Cont m) = m Right

throw :: e -> Except e a
throw e = Cont (\_k -> Left e)

type State s a = forall r. Cont (s -> r) a

runState :: Cont (s -> (a, s)) a -> s -> (a, s)
runState (Cont m) = m (,)

get :: Cont (s -> s) s
get = Cont (\k s -> k s s)

put :: s -> Cont (s -> s) ()
put s = Cont (\k _s -> k () s)

type ContT r m a = Cont (m r) a

lift :: Monad m => m a -> ContT r m a
lift m = Cont (m >>=)

type Codensity m a = forall r. Cont (m r) a

-------------------------------------------------------------------------------

instance Applicative (F f) where
  pure = return
  (<*>) = ap

instance Functor (Eff f) where
  fmap f a = pure f <*> a

instance Applicative (Eff f) where
  pure = return
  (<*>) = ap

instance Applicative (Cont r) where
  pure = return
  (<*>) = ap
