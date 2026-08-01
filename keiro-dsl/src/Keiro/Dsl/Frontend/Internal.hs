{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | Shared implementation behind the public frontend and parser compatibility
-- facade. This module is intentionally not exposed by the package.
module Keiro.Dsl.Frontend.Internal
  ( FrontendFailure (..),
    renderFrontendFailure,
    LoweringFailureCode (..),
    LoweringFailure (..),
    renderLoweringFailure,
    lowerSurfaceSource,
  )
where

import Data.Foldable (traverse_)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
  ( ParseFailure,
    ParsedSource (..),
    renderParseFailure,
  )
import Keiro.Dsl.Source
import Keiro.Dsl.Syntax
import Prelude hiding (span)

-- | Transitional structured frontend error. EP-175 will add phase and code
-- metadata while this wrapper keeps the released parser failure intact.
data FrontendFailure
  = FrontendParseFailure !ParseFailure
  deriving stock (Eq, Show, Generic)

renderFrontendFailure :: FrontendFailure -> Text
renderFrontendFailure (FrontendParseFailure failure) = renderParseFailure failure

data LoweringFailureCode
  = InvalidSourceSpan
  | SourceNameMismatch
  | SurfaceOrderInvalid
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

-- | Remove document order and exact locations while projecting each top-level
-- span's starting line into the compatibility 'Loc'.
lowerSurfaceSource :: SurfaceSource -> Either LoweringFailure ParsedSource
lowerSurfaceSource surfaceSource@SurfaceSource {language, spec = locatedSpec} = do
  validateSurfaceSource surfaceSource
  pure
    ParsedSource
      { parsedSourceLanguage = language,
        parsedSpec = lowerSpec locatedSpec
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
