module Main (main) where

import Jitsurei.Ops (jitsureiOpsHooks)
import Keiro.Ops.Http (mainWithHooks)

main :: IO ()
main = mainWithHooks (jitsureiOpsHooks Nothing)
