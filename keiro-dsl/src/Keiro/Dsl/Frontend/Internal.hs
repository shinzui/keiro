{-# LANGUAGE NoFieldSelectors #-}

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
  ( LanguageDefinition,
    LanguageFeature,
    LanguageVersion,
    ParseFailure (..),
    ParsedSource (..),
    SourceLanguage,
    SourceLanguageDiagnostic (..),
    SourceLanguageErrorCode,
    definitionVersion,
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
frontendLanguageVersion FrontendContext {definition} = definitionVersion definition

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
      code = SourceLanguageError (sourceLanguageErrorCode diagnostic),
      span,
      message = sourceLanguageDiagnosticMessage diagnostic,
      expected = [],
      supportedVersions = fromMaybe (NE.toList (sourceLanguageSupportedVersions diagnostic)) supportedOverride,
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
          (semanticSourceSubjects (parsedSpec parsedSource))
          (surfaceSourceEntries surfaceSource)
      )
  pure
    ParsedSourceDocument
      { documentParsedSource = parsedSource,
        documentSourceIndex = sourceIndex
      }

-- | Compatibility lowering for syntax-valid semantic graphs, including graphs
-- whose duplicate names make an exact semantic index ambiguous. Production
-- source-aware paths use 'lowerSurfaceDocument'.
lowerSurfaceSource :: SurfaceSource -> Either LoweringFailure ParsedSource
lowerSurfaceSource surfaceSource@SurfaceSource {language, spec = locatedSpec} = do
  validateSurfaceSource surfaceSource
  pure
    ParsedSource
      { parsedSourceLanguage = language,
        parsedSpec = lowerSpec locatedSpec
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
sourceIndexLoweringFailure fallback SourceIndexFailure {failureCode = indexCode, failureSpan, failureMessage} =
  LoweringFailure
    { code = SemanticSourceIndexInvalid indexCode,
      span = maybe fallback id failureSpan,
      message = failureMessage
    }

lowerSpec :: Located SurfaceSpec -> Spec
lowerSpec
  Located
    { value =
        SurfaceSpec
          { context = Located {value = contextName},
            moduleRoot,
            layout,
            items
          }
    } =
    Spec
      { specContext = contextName,
        specModuleRoot = locatedValue <$> moduleRoot,
        specLayout = locatedValue <$> layout,
        specIds = [declaration | Located {span, value = SurfaceId value} <- items, let declaration = value {idLoc = spanLoc span}],
        specEnums = [declaration | Located {span, value = SurfaceEnum value} <- items, let declaration = value {enumLoc = spanLoc span}],
        specRules = [declaration | Located {span, value = SurfaceRule value} <- items, let declaration = value {ruleLoc = spanLoc span}],
        specNominalScalars = [declaration | Located {span, value = SurfaceNominalScalar value} <- items, let declaration = value {nominalScalarLoc = spanLoc span}],
        specMapped = [declaration | Located {span, value = SurfaceMapped value} <- items, let declaration = setMappedLoc (spanLoc span) value],
        specNodes = [node | Located {span, value = SurfaceNode value} <- items, let node = setNodeLoc (spanLoc span) value]
      }

locatedValue :: Located a -> a
locatedValue Located {value} = value

spanLoc :: SourceSpan -> Loc
spanLoc sourceSpan = Loc (startLine sourceSpan)

setMappedLoc :: Loc -> MappedDecl -> MappedDecl
setMappedLoc loc value@MappedStructural {} = value {msLoc = loc}
setMappedLoc loc value@MappedOpaque {} = value {moLoc = loc}

setNodeLoc :: Loc -> Node -> Node
setNodeLoc loc = \case
  NAggregate value -> NAggregate value {aggLoc = loc}
  NProcess value -> NProcess value {procLoc = loc}
  NRouter value -> NRouter value {rtLoc = loc}
  NContract value -> NContract value {ctrLoc = loc}
  NIntake value -> NIntake value {inkLoc = loc}
  NEmit value -> NEmit value {emLoc = loc}
  NPublisher value -> NPublisher value {pubLoc = loc}
  NWorkqueue value -> NWorkqueue value {wqLoc = loc}
  NPgmqDispatch value -> NPgmqDispatch value {pdLoc = loc}
  NReadModel value -> NReadModel value {rmLoc = loc}
  NProjectionTarget value -> NProjectionTarget value {ptLoc = loc}
  NRebuildGroup value -> NRebuildGroup value {rgLoc = loc}
  NProjectionRevision value -> NProjectionRevision value {prvLoc = loc}
  NExternalRead value -> NExternalRead value {erLoc = loc}
  NProjectionOwner value -> NProjectionOwner value {poLoc = loc}
  NWorkflow
    WorkflowNode
      { wfId,
        wfStable,
        wfInput,
        wfInputFields,
        wfOutput,
        wfIdField,
        wfIdVia,
        wfBody
      } ->
      NWorkflow
        WorkflowNode
          { wfId,
            wfStable,
            wfInput,
            wfInputFields,
            wfOutput,
            wfIdField,
            wfIdVia,
            wfBody,
            wfLoc = loc
          }
  NOperation value -> NOperation value {opLoc = loc}

validateSurfaceSource :: SurfaceSource -> Either LoweringFailure ()
validateSurfaceSource
  SurfaceSource
    { source = sourceName,
      preamble,
      spec = Located {span = specSpan, value = surfaceSpec}
    } = do
    traverse_ (validateOwnedSpan sourceName) allSpans
    traverse_ (validateContained specSpan) bodySpans
    validateOrder (surfaceItemSpans surfaceSpec)
    where
      bodySpans = surfaceSpecSpans surfaceSpec
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
