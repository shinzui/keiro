{-# LANGUAGE NoFieldSelectors #-}

-- | Closed runtime semantics for bounded declarative router selection.
module Keiro.Router.Selection
  ( RecipientLimit,
    mkRecipientLimit,
    recipientLimitValue,
    SelectionIdentity (..),
    SelectionVersion,
    mkSelectionVersion,
    selectionVersionValue,
    SelectionFingerprint (..),
    SelectionOrder (..),
    SelectionDedupe (..),
    RedeliveryPolicy (..),
    PartialDispatchPolicy (..),
    EmptySelectionPolicy (..),
    SelectionFailurePolicy (..),
    RouterSelectionContract (..),
    RouterSelectionFailure (..),
    normalizeRecipients,
    emptySelectionDeadLetterReason,
    selectionFailureDeadLetterReason,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Keiro.Prelude
import Keiro.ProcessManager (PMCommand (..))
import Keiro.Stream (streamName)
import Kiroku.Store.Types (StreamName (..))
import Numeric.Natural (Natural)
import Shibuya.Core.Ack (DeadLetterCode, DeadLetterReason (ApplicationFailure), mkDeadLetterCode)
import Prelude (all, fromIntegral, length)

-- | A positive post-deduplication recipient bound.
newtype RecipientLimit = RecipientLimit Natural
  deriving stock (Generic, Eq, Ord, Show)

mkRecipientLimit :: Natural -> Either RouterSelectionFailure RecipientLimit
mkRecipientLimit 0 = Left (SelectionEvaluationFailed "recipient limit must be positive")
mkRecipientLimit value = Right (RecipientLimit value)

recipientLimitValue :: RecipientLimit -> Natural
recipientLimitValue (RecipientLimit value) = value

-- | Stable operator-facing identity for one declarative selection contract.
newtype SelectionIdentity = SelectionIdentity Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Positive author-controlled semantic edition.
newtype SelectionVersion = SelectionVersion Natural
  deriving stock (Generic, Eq, Ord, Show)

mkSelectionVersion :: Natural -> Either RouterSelectionFailure SelectionVersion
mkSelectionVersion 0 = Left (SelectionEvaluationFailed "selection version must be positive")
mkSelectionVersion value = Right (SelectionVersion value)

selectionVersionValue :: SelectionVersion -> Natural
selectionVersionValue (SelectionVersion value) = value

-- | Lowercase hexadecimal digest of checked selection semantics.
newtype SelectionFingerprint = SelectionFingerprint Text
  deriving stock (Generic, Eq, Ord, Show)

data SelectionOrder = OrderByTargetStream
  deriving stock (Generic, Eq, Ord, Show)

data SelectionDedupe = DedupeByTargetStream
  deriving stock (Generic, Eq, Ord, Show)

data RedeliveryPolicy = StableUnion
  deriving stock (Generic, Eq, Ord, Show)

data PartialDispatchPolicy = RetainSuccesses
  deriving stock (Generic, Eq, Ord, Show)

data EmptySelectionPolicy
  = EmptyAck
  | EmptyRetry
  | EmptyDeadLetter
  | EmptyHalt
  deriving stock (Generic, Eq, Ord, Show)

data SelectionFailurePolicy
  = FailureRetry
  | FailureDeadLetter
  | FailureHalt
  deriving stock (Generic, Eq, Ord, Show)

data RouterSelectionContract = RouterSelectionContract
  { identity :: !SelectionIdentity,
    version :: !SelectionVersion,
    fingerprint :: !SelectionFingerprint,
    limit :: !RecipientLimit,
    order :: !SelectionOrder,
    dedupe :: !SelectionDedupe,
    emptyPolicy :: !EmptySelectionPolicy,
    failurePolicy :: !SelectionFailurePolicy,
    redeliveryPolicy :: !RedeliveryPolicy,
    partialPolicy :: !PartialDispatchPolicy
  }
  deriving stock (Generic, Eq, Show)

data RouterSelectionFailure
  = SelectionQueryFailed !Text
  | SelectionEvaluationFailed !Text
  | SelectionConflictingCommands !StreamName
  | SelectionRecipientOverflow !RecipientLimit !Natural
  deriving stock (Generic, Eq, Show)

-- | Sort by physical target stream, collapse exact duplicates, reject unequal
-- commands for one target, and apply the positive cap after deduplication.
normalizeRecipients :: (Eq targetCi) => RecipientLimit -> [PMCommand targetCi] -> Either RouterSelectionFailure [PMCommand targetCi]
normalizeRecipients recipientLimit commands = do
  normalized <- traverse normalizeTarget (Map.toAscList commandsByTarget)
  let actual = fromIntegral (length normalized)
  if actual <= recipientLimitValue recipientLimit
    then Right normalized
    else Left (SelectionRecipientOverflow recipientLimit actual)
  where
    commandsByTarget =
      Map.fromListWith
        (<>)
        [ (streamName (command ^. #target), command :| [])
        | command <- commands
        ]

    normalizeTarget (targetName, first :| rest)
      | all (== first) rest = Right first
      | otherwise = Left (SelectionConflictingCommands targetName)

emptySelectionDeadLetterReason :: RouterSelectionContract -> DeadLetterReason
emptySelectionDeadLetterReason contract =
  ApplicationFailure emptySelectionCode (contractDetail contract <> " returned no recipients")

selectionFailureDeadLetterReason :: RouterSelectionContract -> RouterSelectionFailure -> DeadLetterReason
selectionFailureDeadLetterReason contract failure =
  ApplicationFailure code detail
  where
    prefix = contractDetail contract
    (code, detail) = case failure of
      SelectionQueryFailed _ -> (queryFailedCode, prefix <> " query failed")
      SelectionEvaluationFailed _ -> (evaluationFailedCode, prefix <> " evaluation failed")
      SelectionConflictingCommands (StreamName targetName) ->
        (targetConflictCode, prefix <> " produced conflicting commands for target " <> Text.take 128 targetName)
      SelectionRecipientOverflow recipientLimit actual ->
        ( recipientOverflowCode,
          prefix
            <> " selected "
            <> Text.pack (show actual)
            <> " recipients after deduplication; limit is "
            <> Text.pack (show (recipientLimitValue recipientLimit))
        )

contractDetail :: RouterSelectionContract -> Text
contractDetail contract =
  "selection "
    <> Text.take 128 identityText
    <> " version "
    <> Text.pack (show (selectionVersionValue (contract ^. #version)))
  where
    SelectionIdentity identityText = contract ^. #identity

emptySelectionCode :: DeadLetterCode
emptySelectionCode = staticDeadLetterCode "keiro.router.selection.empty"

queryFailedCode :: DeadLetterCode
queryFailedCode = staticDeadLetterCode "keiro.router.selection.query_failed"

evaluationFailedCode :: DeadLetterCode
evaluationFailedCode = staticDeadLetterCode "keiro.router.selection.evaluation_failed"

targetConflictCode :: DeadLetterCode
targetConflictCode = staticDeadLetterCode "keiro.router.selection.target_conflict"

recipientOverflowCode :: DeadLetterCode
recipientOverflowCode = staticDeadLetterCode "keiro.router.selection.recipient_overflow"

staticDeadLetterCode :: Text -> DeadLetterCode
staticDeadLetterCode value = case mkDeadLetterCode value of
  Right code -> code
  Left err -> error ("Keiro.Router.Selection: invalid static dead-letter code: " <> Text.unpack err)
