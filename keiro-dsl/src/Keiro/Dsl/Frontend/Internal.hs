-- | Shared implementation behind the public frontend and parser compatibility
-- facade. This module is intentionally not exposed by the package.
module Keiro.Dsl.Frontend.Internal
  ( FrontendContext (..),
    frontendLanguageVersion,
    frontendSupportsFeature,
    FrontendPhase (..),
    FrontendErrorCode (..),
    frontendErrorCodeText,
    FrontendFailure (..),
    frontendCompatibilityFailure,
    frontendFailureFromSourceDiagnostic,
    frontendFailureFromBody,
    frontendFailureFromLowering,
    renderFrontendFailure,
    LoweringFailureCode (..),
    LoweringFailure (..),
    renderLoweringFailure,
    lowerSurfaceDocument,
    lowerSurfaceSource,
  )
where

import Data.Foldable (traverse_)
import Data.List (find)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
  ( LanguageDefinition (..),
    LanguageFeature,
    LanguageVersion,
    ParseFailure (..),
    ParsedSource (..),
    SourceLanguage,
    SourceLanguageDiagnostic (..),
    SourceLanguageErrorCode,
    languageSupportsFeature,
    renderParseFailure,
    sourceLanguageDiagnosticMessage,
    sourceLanguageErrorCodeText,
  )
import Keiro.Dsl.Source
import Keiro.Dsl.SourceIndex
import Keiro.Dsl.Syntax
import Prelude hiding (span)

-- | The single released-language selection threaded through the modular
-- grammar. Grammar productions ask this context about exact profile
-- membership rather than comparing version numbers.
data FrontendContext = FrontendContext
  { source :: !FilePath,
    language :: !SourceLanguage,
    definition :: !LanguageDefinition
  }
  deriving stock (Eq, Show, Generic)

frontendLanguageVersion :: FrontendContext -> LanguageVersion
frontendLanguageVersion FrontendContext {definition} = (.version) definition

frontendSupportsFeature :: FrontendContext -> LanguageFeature -> Bool
frontendSupportsFeature context feature = languageSupportsFeature (frontendLanguageVersion context) feature

data FrontendPhase
  = SourceSelectionPhase
  | BodyParsingPhase
  | LoweringPhase
  deriving stock (Eq, Ord, Show, Generic)

data FrontendErrorCode
  = SourceLanguageError !SourceLanguageErrorCode
  | SourceSelectionSyntaxError
  | BodySyntaxError
  | LoweringError !LoweringFailureCode
  deriving stock (Eq, Ord, Show, Generic)

frontendErrorCodeText :: FrontendErrorCode -> Text
frontendErrorCodeText = \case
  SourceLanguageError code -> sourceLanguageErrorCodeText code
  SourceSelectionSyntaxError -> "SourceSelectionSyntaxError"
  BodySyntaxError -> "BodySyntaxError"
  LoweringError code -> T.pack (show code)

-- | A source-aware frontend failure. The compatibility projection is retained
-- as data so the released parser facade can render byte-identical diagnostics
-- without exposing Megaparsec types.
data FrontendFailure = FrontendFailure
  { phase :: !FrontendPhase,
    code :: !FrontendErrorCode,
    span :: !SourceSpan,
    message :: !Text,
    expected :: ![Text],
    supportedVersions :: ![LanguageVersion],
    compatibility :: !ParseFailure
  }
  deriving stock (Eq, Show, Generic)

renderFrontendFailure :: FrontendFailure -> Text
renderFrontendFailure FrontendFailure {compatibility} = renderParseFailure compatibility

frontendCompatibilityFailure :: FrontendFailure -> ParseFailure
frontendCompatibilityFailure FrontendFailure {compatibility} = compatibility

frontendFailureFromSourceDiagnostic :: FrontendPhase -> SourceSpan -> Maybe [LanguageVersion] -> SourceLanguageDiagnostic -> FrontendFailure
frontendFailureFromSourceDiagnostic phase span supportedOverride diagnostic =
  FrontendFailure
    { phase,
      code = SourceLanguageError ((.errorCode) diagnostic),
      span,
      message = sourceLanguageDiagnosticMessage diagnostic,
      expected = [],
      supportedVersions = fromMaybe (NE.toList ((.supportedVersions) diagnostic)) supportedOverride,
      compatibility = SourceLanguageFailure diagnostic
    }

frontendFailureFromBody :: FrontendPhase -> SourceSpan -> Text -> [Text] -> ParseFailure -> FrontendFailure
frontendFailureFromBody phase span message expected compatibility =
  FrontendFailure
    { phase,
      code = case phase of
        SourceSelectionPhase -> SourceSelectionSyntaxError
        BodyParsingPhase -> BodySyntaxError
        LoweringPhase -> BodySyntaxError,
      span,
      message,
      expected,
      supportedVersions = [],
      compatibility
    }

data LoweringFailureCode
  = InvalidSourceSpan
  | SourceNameMismatch
  | SurfaceOrderInvalid
  | SemanticSourceIndexInvalid !SourceIndexFailureCode
  deriving stock (Eq, Ord, Show, Generic)

-- | A failure found while converting surface evidence to the semantic graph.
data LoweringFailure = LoweringFailure
  { code :: !LoweringFailureCode,
    span :: !SourceSpan,
    message :: !Text
  }
  deriving stock (Eq, Show, Generic)

renderLoweringFailure :: LoweringFailure -> Text
renderLoweringFailure
  LoweringFailure
    { code,
      span = SourceSpan {source, start = SourcePoint {line, column}},
      message
    } =
    T.pack source
      <> ":"
      <> T.pack (show line)
      <> ":"
      <> T.pack (show column)
      <> ": error ["
      <> T.pack (show code)
      <> "]: "
      <> message

frontendFailureFromLowering :: LoweringFailure -> FrontendFailure
frontendFailureFromLowering failure@LoweringFailure {code, span, message} =
  FrontendFailure
    { phase = LoweringPhase,
      code = LoweringError code,
      span,
      message,
      expected = [],
      supportedVersions = [],
      compatibility = BodyGrammarFailure (renderLoweringFailure failure)
    }

-- | Lower semantic data and retain a checked exact source index beside it.
lowerSurfaceDocument :: SurfaceSource -> Either LoweringFailure ParsedSourceDocument
lowerSurfaceDocument surfaceSource@SurfaceSource {spec = locatedSpec} = do
  parsedSource <- lowerSurfaceSource surfaceSource
  let fallbackSpan = case locatedSpec of Located {span = sourceSpan} -> sourceSpan
  sourceIndex <-
    either
      (Left . sourceIndexLoweringFailure fallbackSpan)
      Right
      ( exactSemanticSourceIndex
          (case surfaceSource of SurfaceSource {source} -> source)
          (semanticSourceSubjects ((.spec) parsedSource))
          (surfaceSourceEntries surfaceSource)
      )
  pure
    ParsedSourceDocument
      { parsedSource = parsedSource,
        sourceIndex = sourceIndex
      }

-- | Compatibility lowering for syntax-valid semantic graphs, including graphs
-- whose duplicate names make an exact semantic index ambiguous. Production
-- source-aware paths use 'lowerSurfaceDocument'.
lowerSurfaceSource :: SurfaceSource -> Either LoweringFailure ParsedSource
lowerSurfaceSource surfaceSource@SurfaceSource {language, spec = locatedSpec} = do
  validateSurfaceSource surfaceSource
  pure
    ParsedSource
      { sourceLanguage = language,
        spec = lowerSpec locatedSpec
      }

surfaceSourceEntries :: SurfaceSource -> [(SourceSubject, SourceSpan)]
surfaceSourceEntries SurfaceSource {spec = Located {value = SurfaceSpec {elements}}} =
  concatMap sourceEntry elements
  where
    sourceEntry Located {span = sourceSpan, value = surfaceElement} = case surfaceElement of
      SurfaceAggregateState aggregateName stateName ->
        [(AggregateStateSubject aggregateName stateName, sourceSpan)]
      SurfaceAggregateTransition aggregateName ordinal ->
        [(AggregateTransitionSubject aggregateName (TransitionOrdinal ordinal), sourceSpan)]
      SurfaceField {} -> []
      SurfaceExpression {} -> []

sourceIndexLoweringFailure :: SourceSpan -> SourceIndexFailure -> LoweringFailure
sourceIndexLoweringFailure fallback SourceIndexFailure {code = indexCode, span, message} =
  LoweringFailure
    { code = SemanticSourceIndexInvalid indexCode,
      span = maybe fallback id span,
      message = message
    }

lowerSpec :: Located SurfaceSpec -> Spec
lowerSpec
  Located
    { value =
        SurfaceSpec
          { context = Located {value = name},
            moduleRoot,
            layout,
            items
          }
    } =
    Spec
      { context = name,
        moduleRoot = locatedValue <$> moduleRoot,
        layout = locatedValue <$> layout,
        ids = [setIdLoc (spanLoc span) value | Located {span, value = SurfaceId value} <- items],
        enums = [setEnumLoc (spanLoc span) value | Located {span, value = SurfaceEnum value} <- items],
        rules = [setRuleLoc (spanLoc span) value | Located {span, value = SurfaceRule value} <- items],
        nominalScalars = [setNominalScalarLoc (spanLoc span) value | Located {span, value = SurfaceNominalScalar value} <- items],
        mapped = [declaration | Located {span, value = SurfaceMapped value} <- items, let declaration = setMappedLoc (spanLoc span) value],
        nodes = [node | Located {span, value = SurfaceNode value} <- items, let node = setNodeLoc (spanLoc span) value]
      }

locatedValue :: Located a -> a
locatedValue Located {value} = value

spanLoc :: SourceSpan -> Loc
spanLoc sourceSpan = Loc (startLine sourceSpan)

setIdLoc :: Loc -> IdDecl -> IdDecl
setIdLoc loc IdDecl {name, prefix, binding} = IdDecl {name, prefix, binding, loc}

setEnumLoc :: Loc -> EnumDecl -> EnumDecl
setEnumLoc loc EnumDecl {name, ctors, binding} = EnumDecl {name, ctors, binding, loc}

setRuleLoc :: Loc -> RuleDecl -> RuleDecl
setRuleLoc loc RuleDecl {name, domain, codomain, cases} = RuleDecl {name, domain, codomain, cases, loc}

setNominalScalarLoc :: Loc -> NominalScalarDecl -> NominalScalarDecl
setNominalScalarLoc loc NominalScalarDecl {name, representation, binding} =
  NominalScalarDecl {name, representation, binding, loc}

setMappedLoc :: Loc -> MappedDecl -> MappedDecl
setMappedLoc loc (MappedStructural name haskell binding bindingVersion canonical fixtures initial shape _) =
  MappedStructural name haskell binding bindingVersion canonical fixtures initial shape loc
setMappedLoc loc (MappedOpaque name haskell codecId codecVersion fixtures initial _) =
  MappedOpaque name haskell codecId codecVersion fixtures initial loc

setNodeLoc :: Loc -> Node -> Node
setNodeLoc loc = \case
  NAggregate (Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot _) ->
    NAggregate (Aggregate name regs states commands events transitions domainOutcomeTypes domainOutcomeDuplicateLocs wire projection snapshot loc)
  NProcess (ProcessNode nodeId name input correlate saga target projections handle rejected poison timer _) ->
    NProcess (ProcessNode nodeId name input correlate saga target projections handle rejected poison timer loc)
  NRouter (RouterNode nodeId name input key resolve target projections dispatch rejected poison _) ->
    NRouter (RouterNode nodeId name input key resolve target projections dispatch rejected poison loc)
  NContract (ContractNode name schemaVersion discriminator topics events _) ->
    NContract (ContractNode name schemaVersion discriminator topics events loc)
  NIntake (IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist decode disposition _) ->
    NIntake (IntakeNode name contract topic accept binds dedupeKey dedupePolicy persist decode disposition loc)
  NEmit (EmitNode name contract topic source key discriminant mapping skip messageId idempotencyKey _) ->
    NEmit (EmitNode name contract topic source key discriminant mapping skip messageId idempotencyKey loc)
  NPublisher (PublisherNode name emit ordering maxAttempts backoff outboxField _) ->
    NPublisher (PublisherNode name emit ordering maxAttempts backoff outboxField loc)
  NWorkqueue (WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn disposition _) ->
    NWorkqueue (WorkqueueNode name logical physical dlq table ordering groupKey provision payloadName payload maxRetries delay dlqOn disposition loc)
  NPgmqDispatch PgmqDispatchNode {name, sourceReadModel, sourceKey, fanoutBody, dedupKey, dedupReadModel, dedupReadModelField, dedupQueue, dedupQueueField, enqueueTo} ->
    NPgmqDispatch PgmqDispatchNode {name, sourceReadModel, sourceKey, fanoutBody, dedupKey, dedupReadModel, dedupReadModelField, dedupQueue, dedupQueueField, enqueueTo, loc}
  NReadModel (ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes _) ->
    NReadModel (ReadModelNode name table schema columns version shape freshness supply group observedTargets backingTarget queryTypes loc)
  NProjectionTarget ProjectionTargetNode {name, schema, table, reset, dependsOn} ->
    NProjectionTarget ProjectionTargetNode {name, schema, table, reset, dependsOn, loc}
  NRebuildGroup RebuildGroupNode {name, targets, order} ->
    NRebuildGroup RebuildGroupNode {name, targets, order, loc}
  NProjectionRevision (ProjectionRevisionNode name group targets _) ->
    NProjectionRevision (ProjectionRevisionNode name group targets loc)
  NExternalRead ExternalReadNode {name, version, queryModel, resultSchema, resultType, compatibleRevisions, surfaceGeneration} ->
    NExternalRead ExternalReadNode {name, version, queryModel, resultSchema, resultType, compatibleRevisions, surfaceGeneration, loc}
  NProjectionOwner ProjectionOwnerNode {name, sources, delivery, group, targets, order, subscription, dedup, checkpointOnMissing, replay} ->
    NProjectionOwner ProjectionOwnerNode {name, sources, delivery, group, targets, order, subscription, dedup, checkpointOnMissing, replay, loc}
  NWorkflow (WorkflowNode nodeId stable input inputFields output idField idVia body _) ->
    NWorkflow (WorkflowNode nodeId stable input inputFields output idField idVia body loc)
  NOperation (OperationNode name shape _) -> NOperation (OperationNode name shape loc)

validateSurfaceSource :: SurfaceSource -> Either LoweringFailure ()
validateSurfaceSource
  SurfaceSource
    { source = sourceName,
      preamble,
      spec = Located {span = specSpan, value = spec}
    } = do
    traverse_ (validateOwnedSpan sourceName) allSpans
    traverse_ (validateContained specSpan) bodySpans
    validateOrder (surfaceItemSpans spec)
    where
      bodySpans = surfaceSpecSpans spec
      allSpans = specSpan : maybe [] (\Located {span} -> [span]) preamble <> bodySpans
      validateOwnedSpan expected sourceSpan@SourceSpan {source}
        | not (validSourceSpan sourceSpan) =
            Left LoweringFailure {code = InvalidSourceSpan, span = sourceSpan, message = "source span end precedes its start"}
        | source /= expected =
            Left LoweringFailure {code = SourceNameMismatch, span = sourceSpan, message = "surface span belongs to a different source"}
        | otherwise = Right ()
      validateContained outer inner
        | contains outer inner = Right ()
        | otherwise = Left LoweringFailure {code = InvalidSourceSpan, span = inner, message = "surface element lies outside the document body span"}

surfaceSpecSpans :: SurfaceSpec -> [SourceSpan]
surfaceSpecSpans SurfaceSpec {context = Located {span = contextSpan}, moduleRoot, layout, items, elements} =
  contextSpan
    : maybe [] (\Located {span} -> [span]) moduleRoot
      <> maybe [] (\Located {span} -> [span]) layout
      <> map (\Located {span} -> span) items
      <> map (\Located {span} -> span) elements

surfaceItemSpans :: SurfaceSpec -> [SourceSpan]
surfaceItemSpans SurfaceSpec {items} = map (\Located {span} -> span) items

contains :: SourceSpan -> SourceSpan -> Bool
contains
  SourceSpan {start = outerStart, end = outerEnd}
  SourceSpan {start = innerStart, end = innerEnd} =
    outerStart <= innerStart && innerEnd <= outerEnd

validateOrder :: [SourceSpan] -> Either LoweringFailure ()
validateOrder spans =
  case find outOfOrder (zip spans (drop 1 spans)) of
    Nothing -> Right ()
    Just (_, offendingSpan) ->
      Left LoweringFailure {code = SurfaceOrderInvalid, span = offendingSpan, message = "top-level surface items are not in source order"}
  where
    outOfOrder (SourceSpan {start = previousStart}, SourceSpan {start = nextStart}) = previousStart > nextStart
