{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import Effectful (runPureEff)
import Generated.TransferRouting.Hospital.Domain qualified as Hospital
import Generated.TransferRouting.Hospital.EventStream (hospitalCategory, hospitalEventStream)
import Generated.TransferRouting.Hospital.Harness (harnessAssertions)
import Generated.TransferRouting.HospitalTransferRouter.RouterHarness (routerHarnessValues)
import Generated.TransferRouting.Hospital_load.ReadModelHarness (runReadModelFacts)
import Keiro.ProcessManager (PMCommand (..))
import Keiro.Router (Router (..))
import Keiro.Stream (entityStream)
import System.Exit (exitFailure)
import TransferRouting.HospitalTransferRouter.RouterValue (
    AcceptedHospitalTransferNeed (..),
    hospitalTransferRouter,
 )

main :: IO ()
main = do
    readModelFactsPass <- runReadModelFacts
    let input =
            AcceptedHospitalTransferNeed
                { transferNeedId = "need-42"
                , region = "north"
                }
        commands = runPureEff (hospitalTransferRouter.resolve input)
        checks =
            [("aggregate: " <> label, passed) | (label, passed) <- harnessAssertions]
                <> [ ("validated hospital event stream constructs", hospitalEventStream `seq` True)
                   , ("read-model facts", readModelFactsPass)
                   , ("router name", hospitalTransferRouter.name == "hospital-transfer-router")
                   , ("router key", hospitalTransferRouter.key input == "need-42")
                   ,
                       ( "resolver source is hospital_load"
                       , lookup "resolveSource" routerHarnessValues == Just "read-model hospital_load"
                       )
                   ,
                       ( "rejected commands dead-letter"
                       , lookup "rejectedPolicy" routerHarnessValues == Just "deadLetter"
                       )
                   ,
                       ( "resolver targets the selected hospital aggregate"
                       , map target commands == [entityStream hospitalCategory "north-general"]
                       )
                   ,
                       ( "resolver dispatches the accepted need"
                       , map command commands
                            == [ Hospital.RouteAcceptedTransferNeed
                                    (Hospital.RouteAcceptedTransferNeedData "need-42" "north-general")
                               ]
                       )
                   ]
    mapM_ printCheck checks
    unless (all snd checks) exitFailure

printCheck :: (String, Bool) -> IO ()
printCheck (label, passed) =
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
