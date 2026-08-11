{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Conformance.DeclarativeRouter.Domain (TransferRouteInput (..))
import Control.Monad (unless)
import Data.Aeson (Value (Null))
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Generated.TransferRouting.Hospital.Domain
  ( HospitalCommand (RouteAcceptedTransferNeed),
    RouteAcceptedTransferNeedData (..),
  )
import Generated.TransferRouting.Hospital.EventStream (hospitalCommandCategory, hospitalEventStream)
import Generated.TransferRouting.HospitalTransferRouter.Router
  ( hospitalTransferRouter,
    hospitalTransferRouterName,
    hospitalTransferRouterSelect,
    hospitalTransferRouterSelectionContract,
    hospitalTransferRouterSelectionFingerprint,
  )
import Generated.TransferRouting.HospitalTransferRouter.RouterHarness (routerHarnessValues)
import Generated.TransferRouting.StructuralConformance (structuralConformanceAssertions)
import Keiro.Command (defaultRunCommandOptions)
import Keiro.ProcessManager (PMCommand (..), PMCommandResult (..))
import Keiro.ReadModel (registerReadModel)
import Keiro.Router
  ( DeclarativeRouter (..),
    DeclarativeRouterResult (..),
    RouterResult (..),
    RouterSelectionFailure (..),
    mkRecipientLimit,
    normalizeRecipients,
    runDeclarativeRouterOnce,
  )
import Keiro.Stream (entityStream, streamName)
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withMigratedSuite)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types
  ( EventId (..),
    EventType (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
  )
import Hasql.Transaction qualified as Tx

main :: IO ()
main =
  withMigratedSuite $ \fixture ->
    withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
      mapM_ (uncurry assert) structuralConformanceAssertions
      assert "generated selection fingerprint is observable" (lengthText hospitalTransferRouterSelectionFingerprint == 64)
      assert "generated harness owns selection" (("resolverOwnership", "generated-declarative") `elem` routerHarnessValues)

      expectRight =<< runStore (Store.runTransaction (Tx.sql initialRowsSql))
      _ <- expectRight =<< runStore (registerReadModel readModelName 1 readModelShape)

      let input = TransferRouteInput "transfer-7" "west"
      selected <- expectRight =<< runStore (hospitalTransferRouterSelect input)
      selectedCommands <- expectSelection selected
      assert
        "query deliberately returns unstable order with an exact duplicate"
        (commandStreamNames selectedCommands == map StreamName ["hospital-hospital-b", "hospital-hospital-a", "hospital-hospital-a"])

      recipientLimit <- expectSelection (mkRecipientLimit 64)
      normalized <- expectSelection (normalizeRecipients recipientLimit selectedCommands)
      assert
        "generated selection normalizes to sorted unique physical targets"
        (commandStreamNames normalized == map StreamName ["hospital-hospital-a", "hospital-hospital-b"])

      first <- expectRight =<< runStore (runDeclarativeRouterOnce defaultRunCommandOptions hospitalTransferRouter sourceEvent input)
      assert "first attempt appends A and B in normalized order" (appendedThenAppended first)

      expectRight =<< runStore (Store.runTransaction (Tx.sql driftRowsSql))
      second <- expectRight =<< runStore (runDeclarativeRouterOnce defaultRunCommandOptions hospitalTransferRouter sourceEvent input)
      assert "redelivery keeps B and appends C" (duplicateThenAppended second)

      mapM_ (assertOneEvent runStore) ["hospital-hospital-a", "hospital-hospital-b", "hospital-hospital-c"]

      let conflictTarget = entityStream hospitalCommandCategory "conflict"
          conflictingCommands =
            [ PMCommand conflictTarget (RouteAcceptedTransferNeed (RouteAcceptedTransferNeedData "transfer-7" "conflict")),
              PMCommand conflictTarget (RouteAcceptedTransferNeed (RouteAcceptedTransferNeedData "transfer-mutated" "conflict"))
            ]
      conflict <-
        expectRight
          =<< runStore
            ( runDeclarativeRouterOnce
                defaultRunCommandOptions
                DeclarativeRouter
                  { name = hospitalTransferRouterName,
                    key = const "transfer-7",
                    selectionContract = hospitalTransferRouterSelectionContract,
                    select = \_ -> pure (Right conflictingCommands),
                    targetEventStream = hospitalEventStream,
                    targetProjections = const []
                  }
                sourceEvent
                input
            )
      assert "conflicting commands fail before dispatch" (isConflict conflict)
      assertNoEvents runStore "hospital-conflict"

      putStrLn "declarative router conformance: PASS"

readModelName :: Text
readModelName = "transfer-routing-hospital-load"

readModelShape :: Text
readModelShape = "fnv1a:3c07a19c552c3547"

initialRowsSql :: ByteString
initialRowsSql =
  """
  CREATE TABLE public.hospital_load (
    hospital_id text NOT NULL,
    region text NOT NULL,
    available_beds integer NOT NULL,
    query_order integer NOT NULL
  );
  INSERT INTO public.hospital_load (hospital_id, region, available_beds, query_order) VALUES
    ('hospital-b', 'west', 1, 1),
    ('hospital-a', 'west', 2, 2),
    ('hospital-a', 'west', 2, 3),
    ('hospital-z', 'west', 0, 4),
    ('hospital-east', 'east', 5, 5);
  """

driftRowsSql :: ByteString
driftRowsSql =
  """
  TRUNCATE public.hospital_load;
  INSERT INTO public.hospital_load (hospital_id, region, available_beds, query_order) VALUES
    ('hospital-c', 'west', 3, 1),
    ('hospital-b', 'west', 1, 2);
  """

sourceEvent :: RecordedEvent
sourceEvent =
  RecordedEvent
    { eventId = EventId sourceUuid,
      eventType = EventType "AcceptedHospitalTransferNeed",
      streamVersion = StreamVersion 1,
      globalPosition = GlobalPosition 1,
      originalStreamId = StreamId 1,
      originalVersion = StreamVersion 1,
      payload = Null,
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0)
    }

sourceUuid :: UUID.UUID
sourceUuid = case UUID.fromString "123e4567-e89b-12d3-a456-426614174000" of
  Just value -> value
  Nothing -> error "invalid static source UUID"

commandStreamNames :: [PMCommand command] -> [StreamName]
commandStreamNames = map (\(PMCommand target _) -> streamName target)

appendedThenAppended :: DeclarativeRouterResult target -> Bool
appendedThenAppended = \case
  DeclarativeSelectionDispatched (RouterResult [PMCommandAppended {}, PMCommandAppended {}]) -> True
  _ -> False

duplicateThenAppended :: DeclarativeRouterResult target -> Bool
duplicateThenAppended = \case
  DeclarativeSelectionDispatched (RouterResult [PMCommandDuplicate {}, PMCommandAppended {}]) -> True
  _ -> False

isConflict :: DeclarativeRouterResult target -> Bool
isConflict = \case
  DeclarativeSelectionFailed SelectionConflictingCommands {} -> True
  _ -> False

assertOneEvent runStore streamNameValue = do
  events <- expectRight =<< runStore (Store.readStreamForward (StreamName streamNameValue) (StreamVersion 0) 10)
  assert ("one event in " <> show streamNameValue) (Vector.length events == 1)

assertNoEvents runStore streamNameValue = do
  events <- expectRight =<< runStore (Store.readStreamForward (StreamName streamNameValue) (StreamVersion 0) 10)
  assert ("no event in " <> show streamNameValue) (Vector.null events)

expectRight :: (Show problem) => Either problem value -> IO value
expectRight = either (error . show) pure

expectSelection :: (Show problem) => Either problem value -> IO value
expectSelection = expectRight

lengthText :: Text -> Int
lengthText = Text.length

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("declarative router conformance failed: " <> label))
