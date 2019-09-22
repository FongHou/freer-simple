{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main (main) where

import qualified Control.Exception.Safe as X
import Control.Monad (forever, when)
import Data.Maybe (fromMaybe)
import Data.List (intercalate)
import System.Environment (getArgs)

import Control.Monad.Freer (Eff, Member, runM, send)
import Control.Monad.Freer.Resource
import Control.Monad.Freer.Error

import Capitalize (Capitalize, capitalize, runCapitalize)
import Console
  ( Console
  , exitSuccess'
  , getLine'
  , putStrLn'
  , runConsolePure
  , runConsoleM
  )
import Coroutine ()
import Fresh ()
import Trace ()
import Error ()

-------------------------------------------------------------------------------
-- Example
-------------------------------------------------------------------------------
capitalizingService :: (Member Console r, Member Capitalize r) => Eff r ()
capitalizingService = forever $ do
    putStrLn' "Send something to capitalize..."
    l <- getLine'
    when (null l) exitSuccess'
    capitalize l >>= putStrLn'
-------------------------------------------------------------------------------

mainPure :: IO ()
mainPure = print
    . runConsolePure ["cat", "fish", "dog", "bird", ""]
    $ runCapitalize capitalizingService

mainConsoleA :: IO ()
mainConsoleA = runM (runConsoleM (runCapitalize capitalizingService))
--             |     |            |             |
--      IO () -'     |            |             |
--     Eff '[IO] () -'            |             |
--         Eff '[Console, IO] () -'             |
--           Eff '[Capitalize, Console, IO] () -'

mainConsoleB :: IO ()
mainConsoleB = runM (runCapitalize (runConsoleM capitalizingService))
--             |     |              |           |
--      IO () -'     |              |           |
--     Eff '[IO] () -'              |           |
--        Eff '[Capitalize, IO] () -'           |
--           Eff '[Console, Capitalize, IO] () -'

printEff :: Member IO r => String -> Eff r ()
printEff = send @IO . putStrLn

mainBracket :: IO ()
mainBracket =
  X.handleAny (\e -> print e) $ 
    runResource (unsafeRunError @String) $ do 
      bracket (printEff "alloc") (const $ printEff "dealloc") $ const $ do
        printEff "hi"
        -- _ <- error "fuck"
        _ <- throwError "fuck"
        printEff "bye"

examples :: [(String, IO ())]
examples =
    [ ("pure", mainPure)
    , ("bracket", mainBracket)
    , ("consoleA", mainConsoleA)
    , ("consoleB", mainConsoleB)
    ]

main :: IO ()
main = getArgs >>= \case
    [x] -> fromMaybe e $ lookup x examples
    _ -> e
  where
    e = putStrLn msg
    msg = "Usage: prog [" ++ intercalate "|" (map fst examples) ++ "]"
