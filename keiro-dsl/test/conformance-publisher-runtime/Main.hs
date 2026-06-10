{- | EP-4 publisher runtime conformance: the scaffolded @Publisher@ config —
ordering policy, backoff curve, max-attempts — compiled against the LIVE
@Keiro.Outbox.Types@ (OrderingPolicy / BackoffSchedule).
-}
module Main (main) where

import Control.Monad (unless)
import Generated.HospitalCapacity.HospitalPublisher.Publisher (
    publisherBackoff,
    publisherMaxAttempts,
    publisherOrdering,
 )
import Keiro.Outbox.Types (BackoffSchedule (..), OrderingPolicy (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    let orderingOk = publisherOrdering == PerKeyHeadOfLine
        backoffOk = case publisherBackoff of ConstantBackoff d -> d == 2; _ -> False
        attemptsOk = publisherMaxAttempts == 10
    putStrLn ("ordering = PerKeyHeadOfLine: " <> show orderingOk)
    putStrLn ("backoff = ConstantBackoff 2s: " <> show backoffOk)
    putStrLn ("maxAttempts = 10: " <> show attemptsOk)
    unless (orderingOk && backoffOk && attemptsOk) exitFailure
