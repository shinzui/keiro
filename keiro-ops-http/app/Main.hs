module Main (main) where

import Keiro.Ops (emptyAppHooks)
import Keiro.Ops.Http (mainWithHooks)

main :: IO ()
main = mainWithHooks emptyAppHooks
