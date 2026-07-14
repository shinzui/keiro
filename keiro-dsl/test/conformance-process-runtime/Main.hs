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
import Data.Text (Text)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Generated.HospitalCapacity.HospitalSurge.Process (
    hospitalSurgeFireOutcome,
    hospitalSurgeProcessName,
    hospitalSurgeProcessWorkerOptions,
    hospitalSurgeTimerRequest,
 )
import Keiro.Command (CommandError (..))
import Keiro.Dsl.Validate (sagaCategoryError)
import Keiro.ProcessManager (PoisonPolicy (..), RejectedCommandPolicy (..), WorkerOptions (..))
import Keiro.Stream (CategoryError, StreamCategory, category)
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
        ambiguousOk = hospitalSurgeFireOutcome (Left (CommandAmbiguous [0, 1]) :: Either CommandError ()) == Nothing
        rejectedPolicyOk = rejectedCommandPolicy hospitalSurgeProcessWorkerOptions == RejectedHalt
        poisonPolicyOk = poisonIsHalt hospitalSurgeProcessWorkerOptions
        categoryMirrorOk = all categoryAgreement ["hospitalSurge", "surge", "", "$all", "hospital-surge", "hospital surge", "bad\NULcategory"]
        colonReservedOk = sagaCategoryError "wf:surge" /= Nothing && not (runtimeRejectsCategory "wf:surge")
    putStrLn ("process name: " <> show nameOk)
    putStrLn ("timer request builds against Keiro.Timer: " <> show reqOk)
    putStrLn ("on-ok => Fired: " <> show okOk)
    putStrLn ("on-reject => Fired (benign inversion): " <> show rejectOk)
    putStrLn ("on-ambiguous => Retry: " <> show ambiguousOk)
    putStrLn ("rejected policy lowered: " <> show rejectedPolicyOk)
    putStrLn ("poison policy lowered: " <> show poisonPolicyOk)
    putStrLn ("DSL saga category mirror agrees with Keiro.Stream.category: " <> show categoryMirrorOk)
    putStrLn ("DSL additionally reserves ':' for workflow streams: " <> show colonReservedOk)
    unless (nameOk && reqOk && okOk && rejectOk && ambiguousOk && rejectedPolicyOk && poisonPolicyOk && categoryMirrorOk && colonReservedOk) exitFailure

categoryAgreement :: Text -> Bool
categoryAgreement value = (sagaCategoryError value /= Nothing) == runtimeRejectsCategory value

runtimeRejectsCategory :: Text -> Bool
runtimeRejectsCategory value = case category value :: Either CategoryError (StreamCategory ()) of
    Left _ -> True
    Right _ -> False

poisonIsHalt :: WorkerOptions es msg -> Bool
poisonIsHalt options = case poisonPolicy options of
    PoisonHalt -> True
    _ -> False
