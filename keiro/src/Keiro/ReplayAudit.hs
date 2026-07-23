{-# LANGUAGE GADTs #-}

{- | Read-only, differential replay audits for aggregate event streams.

Routine deploys should first consume @keiro-dsl diff@'s replay-impact verdict:
a replay-neutral deploy touches no data, while an affected verdict supplies the
event types for 'AuditTargeted'. 'AuditFull' is intentionally reserved for
one-time runtime cutovers and forensics.

Selection is read-only and server-side. It uses Kiroku's indexed category,
event-type, and global-position schema to discover only candidate stream names;
each candidate is then hydrated through the public Store effect. The audit
never appends events, calls @verifyAndSnapshot@, or writes snapshots.

Hand-written services have no spec from which to derive an affected set. They
must supply a conservative set explicitly or choose 'AuditFull'.
-}
module Keiro.ReplayAudit (
    AuditMode (..),
    AffectedSet (..),
    AuditBudget (..),
    defaultAuditBudget,
    AuditTarget (..),
    SomeAuditTarget (..),
    streamInCategory,
    AuditOutcome (..),
    StreamAuditResult (..),
    AuditReport (..),
    auditStream,
    auditStreams,
    auditTargets,
    renderAuditReport,
    auditExitCode,
) where

import Contravariant.Extras (contrazip3, contrazip5)
import Data.Int (Int32)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Concurrent.Async qualified as Async
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (
    CommandError,
    Hydrated (..),
    RunCommandOptions,
    defaultRunCommandOptions,
    hydrateFull,
    hydrateSeeded,
 )
import Keiro.EventStream (EventStream, StateCodec)
import Keiro.EventStream.Validate (ValidatedEventStream, unvalidated)
import Keiro.Prelude
import Keiro.ReplayDigest (canonicalJsonBytes, replayDigest)
import Keiro.Snapshot (SnapshotLookup (..), lookupSnapshotSeed)
import Keiro.Stream (Stream (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read (lookupStreamNames)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (
    CategoryName (..),
    EventType (..),
    GlobalPosition (..),
    StreamId (..),
    StreamName (..),
    StreamVersion,
 )
import Kiroku.Store.Types qualified as StoreTypes
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

-- | Which streams to inspect.
data AuditMode
    = AuditFull
    | AuditTargeted !AffectedSet
    deriving stock (Eq, Show, Generic)

-- | Conservative stored-data surface emitted by the DSL replay-impact diff.
data AffectedSet = AffectedSet
    { affectedEventTypes :: !(Set EventType)
    , includeSnapshotStreams :: !Bool
    }
    deriving stock (Eq, Show, Generic)

{- | Per-run cost and resume controls.

The checkpoint is the maximum global position of the last audited stream at
the selection snapshot. Re-running with that checkpoint selects only streams
whose latest event lies after it. A category that receives new events during
or after a run may intentionally cause a previously checked stream to be
selected again: its durable history changed and warrants another verdict.
-}
data AuditBudget = AuditBudget
    { maxStreams :: !(Maybe Int)
    , parallelism :: !Int
    , resumeFrom :: !(Maybe GlobalPosition)
    }
    deriving stock (Eq, Show, Generic)

defaultAuditBudget :: AuditBudget
defaultAuditBudget =
    AuditBudget
        { maxStreams = Nothing
        , parallelism = 4
        , resumeFrom = Nothing
        }

-- | One typed aggregate/category assembly.
data AuditTarget phi rs s ci co = AuditTarget
    { eventStream :: !(ValidatedEventStream phi rs s ci co)
    , category :: !Text
    , mkStream :: !(StreamName -> Maybe (Stream (EventStream phi rs s ci co)))
    }
    deriving stock (Generic)

-- | Existential packaging for services with multiple aggregate types.
data SomeAuditTarget where
    SomeAuditTarget ::
        (BoolAlg phi (RegFile rs, ci), Eq co) =>
        AuditTarget phi rs s ci co ->
        SomeAuditTarget

-- | Accept a raw store name only when it belongs to the expected category.
streamInCategory :: Text -> StreamName -> Maybe (Stream eventStream)
streamInCategory expected streamName =
    case StoreTypes.categoryName streamName of
        CategoryName actual
            | actual == expected -> Just (Stream streamName)
        _ -> Nothing

-- | Replay result for one accepted stream name.
data AuditOutcome
    = ReplayOk
        { streamVersion :: !StreamVersion
        , digest :: !(Maybe Text)
        }
    | ReplayFailed
        { commandError :: !CommandError
        }
    | SeedDivergence
        { seedVersion :: !StreamVersion
        , seededDigest :: !Text
        , fullDigest :: !Text
        }
    deriving stock (Eq, Show, Generic)

data StreamAuditResult = StreamAuditResult
    { streamName :: !StreamName
    , outcome :: !AuditOutcome
    }
    deriving stock (Eq, Show, Generic)

data AuditReport = AuditReport
    { targetCategory :: !Text
    , mode :: !Text
    , results :: ![StreamAuditResult]
    , rejectedStreams :: ![StreamName]
    , streamsSelected :: !Int
    , streamsSkipped :: !Int
    , failures :: !Int
    , divergences :: !Int
    , checkpoint :: !(Maybe GlobalPosition)
    }
    deriving stock (Eq, Show, Generic)

auditStream ::
    forall phi rs s ci co es.
    (Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    AuditTarget phi rs s ci co ->
    Stream (EventStream phi rs s ci co) ->
    Eff es AuditOutcome
auditStream target stream = do
    let raw = unvalidated (target ^. #eventStream)
        options = defaultRunCommandOptions
    hydrateFull options raw stream >>= \case
        Left err -> pure (ReplayFailed err)
        Right full ->
            case raw ^. #stateCodec of
                Nothing ->
                    pure
                        ReplayOk
                            { streamVersion = full ^. #streamVersion
                            , digest = Nothing
                            }
                Just codec -> auditSeed options raw codec full
  where
    auditSeed ::
        RunCommandOptions ->
        EventStream phi rs s ci co ->
        StateCodec (s, RegFile rs) ->
        Hydrated rs s ->
        Eff es AuditOutcome
    auditSeed options raw codec full = do
        let name = (raw ^. #resolveStreamName) stream
            fullValue = (codec ^. #encode) (full ^. #state, full ^. #registers)
            fullBytes = canonicalJsonBytes fullValue
            fullHash = replayDigest fullValue
        lookupSnapshotSeed name codec >>= \case
            SnapshotUnavailable _ ->
                pure
                    ReplayOk
                        { streamVersion = full ^. #streamVersion
                        , digest = Just fullHash
                        }
            SnapshotHit seed ->
                hydrateSeeded
                    options
                    raw
                    stream
                    (seed ^. #state)
                    (seed ^. #registers)
                    (seed ^. #streamVersion)
                    >>= \case
                        Left err ->
                            pure
                                SeedDivergence
                                    { seedVersion = seed ^. #streamVersion
                                    , seededDigest = "replay-failed:" <> Text.pack (show err)
                                    , fullDigest = fullHash
                                    }
                        Right seeded ->
                            let seededValue =
                                    (codec ^. #encode)
                                        (seeded ^. #state, seeded ^. #registers)
                                seededHash = replayDigest seededValue
                             in if canonicalJsonBytes seededValue == fullBytes
                                    then
                                        pure
                                            ReplayOk
                                                { streamVersion = full ^. #streamVersion
                                                , digest = Just fullHash
                                                }
                                    else
                                        pure
                                            SeedDivergence
                                                { seedVersion = seed ^. #streamVersion
                                                , seededDigest = seededHash
                                                , fullDigest = fullHash
                                                }

auditStreams ::
    forall phi rs s ci co es.
    (IOE :> es, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
    AuditMode ->
    AuditBudget ->
    AuditTarget phi rs s ci co ->
    Eff es AuditReport
auditStreams auditMode budget target = do
    totalStreams <- categoryStreamCount (target ^. #category)
    selectedTotal <- selectedStreamCount auditMode (target ^. #category)
    let skipped =
            case auditMode of
                AuditFull -> 0
                AuditTargeted _ -> Prelude.max 0 (totalStreams Prelude.- selectedTotal)
        workerCount = Prelude.max 1 (budget ^. #parallelism)
        remaining0 = fmap (Prelude.max 0) (budget ^. #maxStreams)
        cursor0 = fromMaybe (GlobalPosition 0) (budget ^. #resumeFrom)
    (allResults, rejected, selected, finalCursor) <-
        go workerCount remaining0 cursor0 [] [] 0
    let failureCount =
            Prelude.length rejected
                Prelude.+ Prelude.length
                    [ ()
                    | StreamAuditResult{outcome = ReplayFailed{}} <- allResults
                    ]
        divergenceCount =
            Prelude.length
                [ ()
                | StreamAuditResult{outcome = SeedDivergence{}} <- allResults
                ]
    pure
        AuditReport
            { targetCategory = target ^. #category
            , mode = case auditMode of AuditFull -> "full"; AuditTargeted _ -> "targeted"
            , results = allResults
            , rejectedStreams = rejected
            , streamsSelected = selected
            , streamsSkipped = skipped
            , failures = failureCount
            , divergences = divergenceCount
            , checkpoint =
                if selected == 0
                    then budget ^. #resumeFrom
                    else Just finalCursor
            }
  where
    pageSize = 128

    go ::
        Int ->
        Maybe Int ->
        GlobalPosition ->
        [StreamAuditResult] ->
        [StreamName] ->
        Int ->
        Eff es ([StreamAuditResult], [StreamName], Int, GlobalPosition)
    go workerCount remaining cursor resultAcc rejectedAcc selectedAcc
        | Just 0 <- remaining =
            pure
                ( Prelude.reverse resultAcc
                , Prelude.reverse rejectedAcc
                , selectedAcc
                , cursor
                )
        | otherwise = do
            let requestSize =
                    maybe pageSize (Prelude.min pageSize) remaining
            page <- selectStreamPage auditMode (target ^. #category) cursor requestSize
            if Vector.null page
                then
                    pure
                        ( Prelude.reverse resultAcc
                        , Prelude.reverse rejectedAcc
                        , selectedAcc
                        , cursor
                        )
                else do
                    names <- lookupStreamNames (Prelude.fst <$> Vector.toList page)
                    let resolved =
                            [ (streamName, streamValue)
                            | (streamId, _watermark) <- Vector.toList page
                            , Just streamName <- [Map.lookup streamId names]
                            , Just streamValue <- [(target ^. #mkStream) streamName]
                            ]
                        acceptedNames = Set.fromList (Prelude.fst <$> resolved)
                        pageNames =
                            [ streamName
                            | (streamId, _watermark) <- Vector.toList page
                            , Just streamName <- [Map.lookup streamId names]
                            ]
                        rejected =
                            Prelude.filter (`Set.notMember` acceptedNames) pageNames
                    audited <-
                        runConcurrent
                            $ Async.pooledMapConcurrentlyN
                                workerCount
                                ( \(name, streamValue) ->
                                    StreamAuditResult name <$> auditStream target streamValue
                                )
                                resolved
                    let nextCursor = Prelude.snd (Vector.last page)
                        pageCount = Vector.length page
                        nextRemaining = (Prelude.- pageCount) <$> remaining
                    go
                        workerCount
                        nextRemaining
                        nextCursor
                        (Prelude.reverse audited <> resultAcc)
                        (Prelude.reverse rejected <> rejectedAcc)
                        (selectedAcc Prelude.+ pageCount)

auditTargets ::
    (IOE :> es, Store :> es) =>
    AuditMode ->
    AuditBudget ->
    [SomeAuditTarget] ->
    Eff es [AuditReport]
auditTargets auditMode budget =
    traverse $ \(SomeAuditTarget target) -> auditStreams auditMode budget target

renderAuditReport :: AuditReport -> Text
renderAuditReport report =
    Text.intercalate
        " "
        [ "replay-audit"
        , "category=" <> report ^. #targetCategory
        , "mode=" <> report ^. #mode
        , "selected=" <> textShow (report ^. #streamsSelected)
        , "skipped=" <> textShow (report ^. #streamsSkipped)
        , "failures=" <> textShow (report ^. #failures)
        , "divergences=" <> textShow (report ^. #divergences)
        , "checkpoint=" <> maybe "none" textShow (report ^. #checkpoint)
        ]
  where
    textShow :: (Show a) => a -> Text
    textShow = Text.pack . show

auditExitCode :: [AuditReport] -> Int
auditExitCode reports
    | Prelude.any
        (\report -> report ^. #failures > 0 Prelude.|| report ^. #divergences > 0)
        reports =
        1
    | otherwise = 0

-- Selection -----------------------------------------------------------------

categoryStreamCount :: (Store :> es) => Text -> Eff es Int
categoryStreamCount category =
    Prelude.fromIntegral <$> runTransaction (Tx.statement category categoryStreamCountStmt)

selectedStreamCount :: (Store :> es) => AuditMode -> Text -> Eff es Int
selectedStreamCount auditMode category =
    case auditMode of
        AuditFull -> categoryStreamCount category
        AuditTargeted affected ->
            Prelude.fromIntegral
                <$> runTransaction
                    ( Tx.statement
                        (category, eventTypeTexts affected, affected ^. #includeSnapshotStreams)
                        targetedStreamCountStmt
                    )

selectStreamPage ::
    (Store :> es) =>
    AuditMode ->
    Text ->
    GlobalPosition ->
    Int ->
    Eff es (Vector (StreamId, GlobalPosition))
selectStreamPage auditMode category (GlobalPosition cursor) limit =
    case auditMode of
        AuditFull ->
            runTransaction
                $ Tx.statement
                    (category, cursor, Prelude.fromIntegral limit)
                    fullStreamPageStmt
        AuditTargeted affected ->
            runTransaction
                $ Tx.statement
                    ( category
                    , eventTypeTexts affected
                    , affected ^. #includeSnapshotStreams
                    , cursor
                    , Prelude.fromIntegral limit
                    )
                    targetedStreamPageStmt

eventTypeTexts :: AffectedSet -> Vector Text
eventTypeTexts affected =
    Vector.fromList
        [ text
        | EventType text <- Set.toAscList (affected ^. #affectedEventTypes)
        ]

categoryStreamCountStmt :: Statement Text Int64
categoryStreamCountStmt =
    preparable
        """
        SELECT count(*)
        FROM kiroku.streams
        WHERE category = $1
          AND stream_version > 0
        """
        (E.param (E.nonNullable E.text))
        (D.singleRow (D.column (D.nonNullable D.int8)))

fullStreamPageStmt :: Statement (Text, Int64, Int32) (Vector (StreamId, GlobalPosition))
fullStreamPageStmt =
    preparable
        """
        SELECT s.stream_id, max(all_events.stream_version) AS watermark
        FROM kiroku.streams s
        JOIN kiroku.stream_events all_events
          ON all_events.stream_id = 0
         AND all_events.original_stream_id = s.stream_id
        WHERE s.category = $1
        GROUP BY s.stream_id
        HAVING max(all_events.stream_version) > $2
        ORDER BY watermark ASC
        LIMIT $3
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.int4))
        )
        streamPageDecoder

targetedStreamCountStmt :: Statement (Text, Vector Text, Bool) Int64
targetedStreamCountStmt =
    preparable
        (targetedSelectionCte <> "SELECT count(*) FROM selected")
        targetedSelectionEncoder
        (D.singleRow (D.column (D.nonNullable D.int8)))

targetedStreamPageStmt ::
    Statement
        (Text, Vector Text, Bool, Int64, Int32)
        (Vector (StreamId, GlobalPosition))
targetedStreamPageStmt =
    preparable
        ( targetedSelectionCte
            <> """
               SELECT stream_id, watermark
               FROM selected
               WHERE watermark > $4
               ORDER BY watermark ASC
               LIMIT $5
               """
        )
        ( contrazip5
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
            (E.param (E.nonNullable E.bool))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.int4))
        )
        streamPageDecoder

targetedSelectionEncoder :: E.Params (Text, Vector Text, Bool)
targetedSelectionEncoder =
    contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        (E.param (E.nonNullable E.bool))

targetedSelectionCte :: Text
targetedSelectionCte =
    """
    WITH candidate_streams AS (
      SELECT DISTINCT s.stream_id
      FROM kiroku.streams s
      JOIN kiroku.stream_events source_events
        ON source_events.stream_id = 0
       AND source_events.original_stream_id = s.stream_id
      JOIN kiroku.events e ON e.event_id = source_events.event_id
      WHERE s.category = $1
        AND e.event_type = ANY($2::text[])
      UNION
      SELECT s.stream_id
      FROM kiroku.streams s
      JOIN keiro.keiro_snapshots snapshots ON snapshots.stream_id = s.stream_id
      WHERE $3
        AND s.category = $1
    ),
    selected AS (
      SELECT candidates.stream_id, max(all_events.stream_version) AS watermark
      FROM candidate_streams candidates
      JOIN kiroku.stream_events all_events
        ON all_events.stream_id = 0
       AND all_events.original_stream_id = candidates.stream_id
      GROUP BY candidates.stream_id
    )
    """

streamPageDecoder :: D.Result (Vector (StreamId, GlobalPosition))
streamPageDecoder =
    D.rowVector
        $ (,)
        <$> (StreamId <$> D.column (D.nonNullable D.int8))
        <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
