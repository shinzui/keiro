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
    unOutputObligationKey,
    EventOutputMapping (..),
    EventOutputError (..),
    eventOutputMapping,
    eventOutputMappingFromGraph,
    eventOutputMappingFromGraphResult,
    eventOutputCanonical,
  )
where

import Data.List (find)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.AggregateType
import Keiro.Dsl.Grammar
import Keiro.Dsl.PrettyPrint (renderExpr)
import Keiro.Dsl.TypeGraph (TypeGraph, TypeGraphError, resolveTypeGraph)

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

unOutputObligationKey :: OutputObligationKey -> Text
unOutputObligationKey (OutputObligationKey value) = value

-- | Exclusive ownership of one event term emitted by one transition.
data EventOutputMapping
  = GeneratedCommandIdentity
      { sourceCommand :: !Name,
        fields :: ![CheckedFieldCopy]
      }
  | HandOwnedEventOutput
      { obligation :: !OutputObligationKey
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
eventOutputMapping spec = eventOutputMappingFromGraphResult (resolveTypeGraph spec) spec

eventOutputMappingFromGraph :: TypeGraph -> Spec -> Aggregate -> Transition -> Int -> Name -> Either EventOutputError EventOutputMapping
eventOutputMappingFromGraph graph = eventOutputMappingFromGraphResult (Right graph)

eventOutputMappingFromGraphResult :: Either (NonEmpty TypeGraphError) TypeGraph -> Spec -> Aggregate -> Transition -> Int -> Name -> Either EventOutputError EventOutputMapping
eventOutputMappingFromGraphResult typeGraphResult spec aggregate transition emitIndex eventName = do
  event <- maybe (Left (OutputEventMissing eventName)) Right (find ((== eventName) . (.name)) ((.events) aggregate))
  case ((.implementation) transition, (.body) event) of
    (LegacyHoleImplementation, _) -> pure handOwned
    (_, EventFields _) -> pure handOwned
    (_, EventFromCommand sourceCommand)
      | sourceCommand /= (.command) transition ->
          Left
            OutputCommandMismatch
              { declaredSourceCommand = sourceCommand,
                consumingTransitionCommand = (.command) transition,
                emittedEventName = eventName
              }
      | otherwise -> do
          command <- maybe (Left (OutputSourceCommandMissing sourceCommand)) Right (find ((== sourceCommand) . (.name)) ((.commands) aggregate))
          fields <- traverse checkedCopy ((.fields) command)
          pure
            GeneratedCommandIdentity
              { sourceCommand = sourceCommand,
                fields = fields
              }
  where
    symbols = aggregateSymbolsFromGraphResult typeGraphResult spec
    handOwned =
      HandOwnedEventOutput
        { obligation =
            OutputObligationKey
              ( T.intercalate
                  "/"
                  [ "event-output-v1",
                    (.name) aggregate,
                    transitionModeName ((.mode) transition),
                    (.source) transition,
                    (.command) transition,
                    maybe "unguarded" renderExpr ((.guard) transition),
                    T.intercalate ";" [register <> ":=" <> renderExpr expression | (register, expression) <- (.writes) transition],
                    T.intercalate "," ((.emits) transition),
                    (.goto) transition,
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
              { outputSelector = (.name) field,
                outputWireName = (.name) field,
                outputFieldType = commandType
              }
        else Left (OutputFieldTypeMismatch ((.name) field) commandType eventType)

-- | Canonical ownership text used by fold and behavior fingerprints.
eventOutputCanonical :: EventOutputMapping -> Text
eventOutputCanonical mapping = case mapping of
  GeneratedCommandIdentity command fields ->
    "generated-command-identity:"
      <> command
      <> "["
      <> T.intercalate
        ","
        [ (.outputSelector) field
            <> "="
            <> (.outputWireName) field
            <> ":"
            <> aggregateCanonicalName ((.outputFieldType) field)
        | field <- fields
        ]
      <> "]"
  HandOwnedEventOutput obligation -> "hand-owned:" <> unOutputObligationKey obligation

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft f = either (Left . f) Right

transitionModeName :: TransitionMode -> Text
transitionModeName TmLive = "live"
transitionModeName TmReplayOnly = "replay-only"
