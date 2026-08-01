{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Checked ownership for values emitted by aggregate transitions.
--
-- The source grammar preserves whether an event copied a command with
-- @fields(Command)@ or declared an explicit field list.  This module turns that
-- provenance into the one semantic model consumed by validation, fingerprints,
-- scaffolding, and behavior coverage.  No downstream consumer may infer
-- ownership merely from coincidentally equal field names.
module Keiro.Dsl.EventOutput
  ( CheckedFieldCopy (..),
    OutputObligationKey (..),
    EventOutputMapping (..),
    EventOutputError (..),
    eventOutputMapping,
    eventOutputCanonical,
  )
where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.AggregateType
import Keiro.Dsl.Grammar
import Keiro.Dsl.PrettyPrint (renderExpr)

-- | One field in a checked identity copy.  The selector and current wire name
-- are retained separately so a future aggregate-field alias can change the wire
-- identity without changing how generated Haskell reads the command payload.
data CheckedFieldCopy = CheckedFieldCopy
  { outputSelector :: !Name,
    outputWireName :: !Text,
    outputFieldType :: !ResolvedAggregateType
  }
  deriving stock (Eq, Ord, Show)

-- | Stable, semantic name for one consumer-owned event-output obligation.
newtype OutputObligationKey = OutputObligationKey {unOutputObligationKey :: Text}
  deriving stock (Eq, Ord, Show)

-- | Exclusive ownership of one event term emitted by one transition.
data EventOutputMapping
  = GeneratedCommandIdentity
      { outputSourceCommand :: !Name,
        outputFields :: ![CheckedFieldCopy]
      }
  | HandOwnedEventOutput
      { outputObligation :: !OutputObligationKey
      }
  deriving stock (Eq, Ord, Show)

data EventOutputError
  = OutputEventMissing !Name
  | OutputSourceCommandMissing !Name
  | OutputCommandMismatch
      { declaredSourceCommand :: !Name,
        consumingTransitionCommand :: !Name,
        emittedEventName :: !Name
      }
  | OutputFieldTypeInvalid !AggregateTypeError
  | OutputFieldTypeMismatch !Name !ResolvedAggregateType !ResolvedAggregateType
  deriving stock (Eq, Show)

-- | Resolve one transition/event pair.  @fields(Command)@ is generated-owned
-- only for a transition consuming that exact command.  Explicit event fields
-- remain hand-owned even when their names happen to match command fields.
eventOutputMapping :: Spec -> Aggregate -> Transition -> Int -> Name -> Either EventOutputError EventOutputMapping
eventOutputMapping spec aggregate transition emitIndex eventName = do
  event <- maybe (Left (OutputEventMissing eventName)) Right (find ((== eventName) . evName) (aggEvents aggregate))
  case (tImplementation transition, evBody event) of
    (LegacyHoleImplementation, _) -> pure handOwned
    (_, EventFields _) -> pure handOwned
    (_, EventFromCommand sourceCommand)
      | sourceCommand /= tCommand transition ->
          Left
            OutputCommandMismatch
              { declaredSourceCommand = sourceCommand,
                consumingTransitionCommand = tCommand transition,
                emittedEventName = eventName
              }
      | otherwise -> do
          command <- maybe (Left (OutputSourceCommandMissing sourceCommand)) Right (find ((== sourceCommand) . cmdName) (aggCommands aggregate))
          fields <- traverse checkedCopy (cmdFields command)
          pure
            GeneratedCommandIdentity
              { outputSourceCommand = sourceCommand,
                outputFields = fields
              }
  where
    symbols = aggregateSymbols spec
    handOwned =
      HandOwnedEventOutput
        { outputObligation =
            OutputObligationKey
              ( T.intercalate
                  "/"
                  [ "event-output-v1",
                    aggName aggregate,
                    transitionModeName (tMode transition),
                    tSource transition,
                    tCommand transition,
                    maybe "unguarded" renderExpr (tGuard transition),
                    T.intercalate ";" [register <> ":=" <> renderExpr expression | (register, expression) <- tWrites transition],
                    T.intercalate "," (tEmits transition),
                    tGoto transition,
                    T.pack (show emitIndex),
                    eventName
                  ]
              )
        }
    checkedCopy field = do
      commandType <- mapLeft OutputFieldTypeInvalid (inferAggregateFieldType symbols aggregate CommandFieldUse field)
      eventType <- mapLeft OutputFieldTypeInvalid (inferAggregateFieldType symbols aggregate EventFieldUse field)
      if commandType == eventType
        then
          pure
            CheckedFieldCopy
              { outputSelector = aggregateFieldName field,
                outputWireName = aggregateFieldName field,
                outputFieldType = commandType
              }
        else Left (OutputFieldTypeMismatch (aggregateFieldName field) commandType eventType)

-- | Canonical ownership text used by fold and behavior fingerprints.
eventOutputCanonical :: EventOutputMapping -> Text
eventOutputCanonical mapping = case mapping of
  GeneratedCommandIdentity command fields ->
    "generated-command-identity:"
      <> command
      <> "["
      <> T.intercalate
        ","
        [ outputSelector field
            <> "="
            <> outputWireName field
            <> ":"
            <> aggregateCanonicalName (outputFieldType field)
        | field <- fields
        ]
      <> "]"
  HandOwnedEventOutput obligation -> "hand-owned:" <> unOutputObligationKey obligation

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft f = either (Left . f) Right

transitionModeName :: TransitionMode -> Text
transitionModeName TmLive = "live"
transitionModeName TmReplayOnly = "replay-only"
