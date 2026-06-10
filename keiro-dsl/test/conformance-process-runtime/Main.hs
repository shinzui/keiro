{- | EP-3 runtime conformance: the scaffolded process @Process@ module's
deterministic wiring — the timer-request builder (a real
@Keiro.Timer.TimerRequest@ with a v5-derived @TimerId@) and the fire
disposition over @Keiro.Command.CommandError@ — compiled against the LIVE
keiro runtime (not just emitted as text). Running it checks the
@on-reject => Fired@ benign inversion lowered correctly. (The full
ProcessManager value with a filled @handle@ remains the agent-written hole.)
-}
module Main (main) where

import Control.Monad (unless)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Generated.HospitalCapacity.HospitalSurge.Process (
    hospitalSurgeFireOutcome,
    hospitalSurgeProcessName,
    hospitalSurgeTimerRequest,
 )
import Keiro.Command (CommandError (..))
import Keiro.Timer (TimerRequest (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    let nameOk = hospitalSurgeProcessName == "hospital-surge"
        -- the builder compiles against Keiro.Timer and names the queue.
        reqOk = processManagerName (hospitalSurgeTimerRequest "hosp-1" (posixSecondsToUTCTime 0)) == "hospital-surge"
        -- the disposition lowered from the spec: on-ok Fired, on-reject Fired.
        okOk = hospitalSurgeFireOutcome (Right () :: Either CommandError ()) == Just ()
        rejectOk = hospitalSurgeFireOutcome (Left CommandRejected :: Either CommandError ()) == Just ()
    putStrLn ("process name: " <> show nameOk)
    putStrLn ("timer request builds against Keiro.Timer: " <> show reqOk)
    putStrLn ("on-ok => Fired: " <> show okOk)
    putStrLn ("on-reject => Fired (benign inversion): " <> show rejectOk)
    unless (nameOk && reqOk && okOk && rejectOk) exitFailure
