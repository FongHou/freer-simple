module Main (main) where

import Control.Monad (replicateM_)
import Data.DList

import Control.Monad.Freer
import Control.Monad.Freer.Error (runError)
import Control.Monad.Freer.NonDet (runNonDetA)
import Control.Monad.Freer.State (get, runState)

import qualified Control.Monad.Free as Free
import qualified Control.Monad.State as MTL

-- import qualified Polysemy as Poly
-- import qualified Polysemy.Error as Poly
-- import qualified Polysemy.State as Poly

import qualified Control.Algebra as Eff
import qualified Control.Carrier.Error.Either as Eff
import qualified Control.Carrier.NonDet.Church as Eff
import qualified Control.Carrier.State.Strict as Eff

import qualified CountDown
import NonDet

import Criterion (bench, bgroup, whnf)
import Criterion.Main (defaultMain)

--------------------------------------------------------------------------------
-- State Benchmarks --
--------------------------------------------------------------------------------

oneGet :: Int -> (Int, Int)
oneGet n = run (runState n get)

oneGetMTL :: Int -> (Int, Int)
oneGetMTL = MTL.runState MTL.get

-- oneGetPoly :: Int -> (Int, Int)
-- oneGetPoly n = Poly.run (Poly.runState n Poly.get)

countDown :: Int -> (Int, Int)
countDown n = if n <= 0 then (n, n) else countDown (n - 1)

countDownFreer :: Int -> (Int, Int)
countDownFreer start = run (runState start CountDown.freer)

-- countDownPoly :: Int -> (Int, Int)
-- countDownPoly start = Poly.run (Poly.runState start go)
--  where
--   go = Poly.get >>= (\n -> if n <= 0 then pure n else Poly.put (n -1) >> go)

countDownMTL :: Int -> (Int, Int)
countDownMTL = MTL.runState CountDown.mtl

countDownEff :: Int -> (Int, Int)
countDownEff start = Eff.run (Eff.runState start CountDown.fused)

--------------------------------------------------------------------------------
-- Exception + State --
--------------------------------------------------------------------------------
countDownExc :: Int -> Either String (Int, Int)
countDownExc start = run $ runError (runState start CountDown.freer2)

-- countDownExcPoly :: Int -> Either String (Int, Int)
-- countDownExcPoly start = Poly.run $ Poly.runError (Poly.runState start go)
--  where
--   go = Poly.get >>= (\n -> if n <= (0 :: Int) then Poly.throw "wat" else Poly.put (n -1) >> go)

countDownExcMTL :: Int -> Either String (Int, Int)
countDownExcMTL = MTL.runStateT CountDown.mtl2

countDownExcEff :: Int -> Either String (Int, Int)
countDownExcEff start = Eff.run $ Eff.runError (Eff.runState start CountDown.fused2)

--------------------------------------------------------------------------------
-- Freer: Interpreter --
--------------------------------------------------------------------------------
data Http out where
  Open :: String -> Http ()
  Close :: Http ()
  Post :: String -> Http String
  Get :: Http String

open' :: Member Http r => String -> Eff r ()
open' = send . Open

close' :: Member Http r => Eff r ()
close' = send Close

post' :: Member Http r => String -> Eff r String
post' = send . Post

get' :: Member Http r => Eff r String
get' = send Get

runHttp :: Eff (Http ': r) w -> Eff r w
runHttp = interpret $ \case
  (Open _) -> pure ()
  Close -> pure ()
  (Post d) -> pure d
  Get -> pure ""

--------------------------------------------------------------------------------
-- Free: Interpreter --
--------------------------------------------------------------------------------
data FHttpT x
  = FOpen String x
  | FClose x
  | FPost String (String -> x)
  | FGet (String -> x)
  deriving (Functor)

type FHttp = Free.Free FHttpT

fopen' :: String -> FHttp ()
fopen' s = Free.liftF $ FOpen s ()

fclose' :: FHttp ()
fclose' = Free.liftF $ FClose ()

fpost' :: String -> FHttp String
fpost' s = Free.liftF $ FPost s id

fget' :: FHttp String
fget' = Free.liftF $ FGet id

runFHttp :: FHttp a -> Maybe a
runFHttp (Free.Pure x) = pure x
runFHttp (Free.Free (FOpen _ n)) = runFHttp n
runFHttp (Free.Free (FClose n)) = runFHttp n
runFHttp (Free.Free (FPost s n)) = pure s >>= runFHttp . n
runFHttp (Free.Free (FGet n)) = pure "" >>= runFHttp . n

--------------------------------------------------------------------------------
-- Benchmark Suite --
--------------------------------------------------------------------------------
prog :: Member Http r => Eff r ()
prog = open' "cats" >> get' >> post' "cats" >> close'

prog' :: FHttp ()
prog' = fopen' "cats" >> fget' >> fpost' "cats" >> fclose'

p :: Member Http r => Int -> Eff r ()
p count = open' "cats" >> replicateM_ count (get' >> post' "cats") >> close'

p' :: Int -> FHttp ()
p' count = fopen' "cats" >> replicateM_ count (fget' >> fpost' "cats") >> fclose'

main :: IO ()
main =
  defaultMain
    [ bgroup
        "State"
        [ bench "mtl.get" $ whnf oneGetMTL 0
        , bench "freer.get" $ whnf oneGet 0
        -- , bench "polysemy.get" $ whnf oneGetPoly 0
        ]
    , bgroup
        "Countdown Bench"
        [ bench "reference" $ whnf countDown 10000
        , bench "mtl.State (inline)" $ whnf countDownMTL 10000
        , bench "fused.State (inline)" $ whnf countDownEff 10000
        , bench "freer.State (inline)" $ whnf countDownFreer 10000
        -- , bench "polysemy.State (inline)" $ whnf countDownPoly 10000
        ]
    , bgroup
        "Countdown+Except Bench"
        [ bench "mtl.ExceptState (inline)" $ whnf countDownExcMTL 10000
        , bench "fused.ExceptState (inline)" $ whnf countDownExcEff 10000
        , bench "freer.ExcState (inline)" $ whnf countDownExc 10000
        -- , bench "polysemy.ExcState (inline)" $ whnf countDownExcPoly 10000
        ]
    , bgroup
        "NQueens"
        [ bench "[]" $ whnf (id @[_]) $ queens 8
        , bench "fused.NonDet" $ whnf Eff.run . Eff.runNonDetA @[] $ queens 8
        , bench "freer.NonDet @[]" $ whnf run . runNonDetA @[] $ queens 8
        , bench "freer.NonDet @DList" $ whnf run . runNonDetA @DList $ queens 8
        ]
    , bgroup
        "HTTP Simple DSL"
        [ bench "freer" $ whnf (run . runHttp) prog
        , bench "free" $ whnf runFHttp prog'
        , bench "freerN" $ whnf (run . runHttp . p) 1000
        , bench "freeN" $ whnf (runFHttp . p') 1000
        ]
    ]
