module ReactionInspectionSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Keiki.Core
import Keiro
import Keiro.Ops qualified as Ops
import Keiro.Ops.Env
import Keiro.Ops.Render
import Keiro.ProcessManager.Inspect qualified as Inspect
import Keiro.ProcessManager.Reaction qualified as Reaction
import Keiro.Stream qualified as Stream
import Keiro.Test.Postgres
import Keiro.Timer qualified as Timer
import Kiroku.Store.Types hiding (id)
import Options.Applicative qualified as Options
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = describe "reaction process-manager commands" $
  around (withFreshResourceStore fixture) $
    it "mounts a handwritten reaction inspector through pm show and pm list" $ \(store, StoreRunner run) -> do
      clock <- getCurrentTime
      let source = RecordedEvent (EventId UUID.nil) (EventType "Input") (StreamVersion 1) (GlobalPosition 1) (StreamId 1) (StreamVersion 1) Null Nothing Nothing Nothing clock
          timer = Timer.TimerRequest (Timer.TimerId UUID.nil) "modern" "one" clock (object [])
          manager =
            Reaction.ReactiveProcessManager
              "modern"
              id
              handler
              (\cid -> stream ("opsreaction-" <> cid))
              definition
              (const [])
              (const (Reaction.AdvanceReaction Go [] [Reaction.FollowSchedule Reaction.Once timer]))
          descriptor = Inspect.reactiveProcessManagerInspector manager (Stream.categoryUnsafe "opsreaction") (\state _ -> String (Text.pack (show state)))
          hooks = Ops.emptyAppHooks {Ops.processManagers = Just (Map.singleton "modern" (Inspect.SomeProcessManagerInspector descriptor))}
          invoke args = case Options.execParserPure Options.defaultPrefs (Options.info (Ops.commandParser hooks) mempty) args of
            Options.Success command ->
              Ops.runCommand hooks (OpsEnv store Json False [] False) command >>= \case
                Succeeded result -> pure result.jsonValue
                other -> fail (show other)
            _ -> fail "inspection command did not parse"
      Right (Right _) <- run (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions manager source "one")
      shown <- invoke ["pm", "show", "--name", "modern", "--correlation", "one"]
      field "state" shown `shouldBe` Just (String "Finished")
      field "state_version" shown `shouldBe` Just (Number 1)
      case field "last_reaction" shown of
        Just last -> do
          field "provenance_status" last `shouldBe` Just (String "unavailable")
          field "provenance" last `shouldBe` Just Null
        Nothing -> expectationFailure "accepted saga event is missing"
      case field "pending_timers" shown >>= field "items" of
        Just (Array items) -> length items `shouldBe` 1
        _ -> expectationFailure "reaction timer is missing"
      case field "waiting_for" shown of
        Just (Array items) -> length items `shouldBe` 1
        _ -> expectationFailure "live input candidate is missing"
      listed <- invoke ["pm", "list", "--name", "modern", "--limit", "1"]
      case field "items" listed of
        Just (Array rows) -> map (field "correlation_id") (foldr (:) [] rows) `shouldBe` [Just (String "one")]
        _ -> expectationFailure "reaction journal is missing from the manager catalog"

field :: Text -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup (Key.fromText key) fields
field _ _ = Nothing

data State = Ready | Finished deriving stock (Eq, Show, Ord, Enum, Bounded)

data Cmd = Go deriving stock (Eq, Show)

data Event = Observed deriving stock (Eq, Show)

definition :: ValidatedEventStream (HsPred '[] Cmd) '[] State Cmd Event
definition =
  mkEventStreamOrThrow
    "ops-reaction-inspection"
    EventStream
      { transducer =
          SymTransducer
            { edgesOut = const [Edge {guard = matchInCtor goCtor, update = UKeep, output = [pack goCtor eventCtor oNil], target = Finished, mode = Live}],
              initial = Ready,
              initialRegs = RNil,
              isFinal = const False
            },
        initialState = Ready,
        initialRegisters = RNil,
        eventCodec =
          Codec
            { eventTypes = EventType "Observed" :| [],
              eventType = const (EventType "Observed"),
              schemaVersion = 1,
              encode = const Null,
              decode = \kind _ -> if kind == EventType "Observed" then Right Observed else Left "unknown fixture event",
              upcasters = []
            },
        resolveStreamName = Stream.streamName,
        snapshotPolicy = Never,
        stateCodec = Nothing
      }

handler :: DomainCommandHandler (HsPred '[] Cmd) '[] State Cmd Event Text Text
handler = DomainCommandHandler definition (const (SilentNoOp "unused"))

goCtor :: InCtor Cmd '[]
goCtor = unavailableInCtor "Go" (const (Just RNil)) (\RNil -> Go)

eventCtor :: WireCtor Event ()
eventCtor = unavailableWireCtor "Observed" (const (Just ())) (const Observed)
