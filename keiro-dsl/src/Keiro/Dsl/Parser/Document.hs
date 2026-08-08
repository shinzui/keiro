-- | Released-language dispatch and complete document composition.
module Keiro.Dsl.Parser.Document
  ( parseSurfaceSource,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Frontend.Internal
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser.Aggregate (pAggregate)
import Keiro.Dsl.Parser.Coordination (pProcess, pRouter)
import Keiro.Dsl.Parser.Core
import Keiro.Dsl.Parser.Declaration (pEnumDecl, pIdDecl, pRuleDecl)
import Keiro.Dsl.Parser.Integration (pContract, pEmit, pIntake, pPublisher)
import Keiro.Dsl.Parser.Mapped (pMappedTopItem)
import Keiro.Dsl.Parser.Preamble
import Keiro.Dsl.Parser.ProjectionCatalog (pProjectionOwner, pProjectionTarget, pRebuildGroup)
import Keiro.Dsl.Parser.Queue (pPgmqDispatch, pWorkqueue)
import Keiro.Dsl.Parser.ReadModel (pReadModel)
import Keiro.Dsl.Parser.Workflow (pOperation, pWorkflow)
import Keiro.Dsl.Source
import Keiro.Dsl.Syntax
import Text.Megaparsec
import Prelude hiding (span)

parseSurfaceSource :: FilePath -> Text -> Either FrontendFailure SurfaceSource
parseSurfaceSource src input = do
  sourceLanguage <- selectSourceLanguage src input
  definition <- case lookupLanguageDefinition (effectiveLanguageVersion sourceLanguage) of
    Just value -> Right value
    Nothing -> error "keiro-dsl internal invariant: source selection returned an unregistered language"
  parseSelectedBody FrontendContext {source = src, language = sourceLanguage, definition}
  where
    parseSelectedBody context@FrontendContext {language = sourceLanguage} =
      let laterPreambleCode = case sourceLanguage of
            LegacyUnversioned -> MisplacedLanguagePreamble
            DeclaredLanguage {} -> DuplicateLanguagePreamble
          parser =
            sc
              *> case sourceLanguage of
                LegacyUnversioned -> pSurfaceDocument context Nothing laterPreambleCode <* eof
                DeclaredLanguage {} -> do
                  locatedPreamble <- withOwnedSpan (sourceLanguage <$ pDeclaredPreamble)
                  pSurfaceDocument context (Just locatedPreamble) laterPreambleCode <* eof
       in case runParser parser src input of
            Left bundle -> case firstContextualFailure bundle of
              Just contextual ->
                let diagnostic = contextualDiagnostic src sourceLanguage contextual
                    supported = languageVersionsSupportingFeature <$> contextualFailureFeature contextual
                 in Left (frontendFailureFromSourceDiagnostic BodyParsingPhase (contextualFailureSpan contextual) supported diagnostic)
              Nothing ->
                Left
                  ( frontendFailureFromBody
                      BodyParsingPhase
                      (bundleFailureSpan bundle)
                      (bundleMessage bundle)
                      (bundleExpected bundle)
                      (BodyGrammarFailure (T.pack (errorBundlePretty bundle)))
                  )
            Right surface -> Right surface

-- Top level
--------------------------------------------------------------------------------

pContextualPreamble :: SourceLanguageErrorCode -> P a
pContextualPreamble code = do
  locatedPreamble <- withOwnedSpan (try pDeclaredPreamble)
  contextualFailureAt (spanOf locatedPreamble) code

pSurfaceDocument :: FrontendContext -> Maybe (Located SourceLanguage) -> SourceLanguageErrorCode -> P SurfaceSource
pSurfaceDocument context@FrontendContext {source = sourceName, language = sourceLanguage} preamble laterPreambleCode = do
  spec <- pSurfaceSpec context laterPreambleCode
  pure SurfaceSource {source = sourceName, language = sourceLanguage, preamble, spec}

pSurfaceSpec :: FrontendContext -> SourceLanguageErrorCode -> P (Located SurfaceSpec)
pSurfaceSpec context laterPreambleCode = do
  pContextualPreamble laterPreambleCode <|> pure ()
  locatedContext <- withOwnedSpan (keyword "context" *> wireWord)
  moduleRoot <- optional (withOwnedSpan pModuleClause)
  layout <- optional (withOwnedSpan pLayoutClause)
  parsedItems <- many (withOwnedSpan (pTopItem context laterPreambleCode))
  let items = map surfaceItem parsedItems
      elements = concatMap surfaceElements parsedItems
  let contextSpan@SourceSpan {source, start} = spanOf locatedContext
      finalSpan = case reverse items of
        item : _ -> spanOf item
        [] -> case layout of
          Just value -> spanOf value
          Nothing -> maybe contextSpan spanOf moduleRoot
      SourceSpan {end} = finalSpan
  pure
    Located
      { span = SourceSpan {source, start, end},
        value = SurfaceSpec {context = locatedContext, moduleRoot, layout, items, elements}
      }
  where
    surfaceItem Located {span, value = ParsedTopItem item _} = Located {span, value = item}
    surfaceElements Located {value = ParsedTopItem _ elements} = elements

-- | @module Acme.Services@ — the optional namespace-prefix clause.
pModuleClause :: P Text
pModuleClause = keyword "module" *> pModulePrefix

-- | @layout (prefixed|collocated)@ — the optional placement-style clause.
pLayoutClause :: P Placement
pLayoutClause =
  keyword "layout"
    *> choice
      [ GeneratedPrefix <$ keyword "prefixed",
        CollocatedLeaf <$ keyword "collocated"
      ]

-- | A parsed top-level value plus any nested syntax evidence it owns.
data ParsedTopItem = ParsedTopItem !SurfaceTopItem ![Located SurfaceElement]

pTopItem :: FrontendContext -> SourceLanguageErrorCode -> P ParsedTopItem
pTopItem context laterPreambleCode =
  choice
    ( [ pContextualPreamble laterPreambleCode,
        plain (SurfaceId <$> pIdDecl context),
        plain (SurfaceEnum <$> pEnumDecl context),
        do
          (rule, elements) <- pRuleDecl context
          pure (ParsedTopItem (SurfaceRule rule) elements),
        plain (pMappedTopItem context)
      ]
        ++ [ plain (SurfaceNode . NRouter <$> pRouter),
             plain (SurfaceNode . NProcess <$> pProcess),
             plain (SurfaceNode . NContract <$> pContract context),
             plain (SurfaceNode . NIntake <$> pIntake),
             plain (SurfaceNode . NEmit <$> pEmit),
             plain (SurfaceNode . NPublisher <$> pPublisher),
             plain (SurfaceNode . NWorkqueue <$> pWorkqueue),
             plain (SurfaceNode . NPgmqDispatch <$> pPgmqDispatch),
             plain (SurfaceNode . NReadModel <$> pReadModel context),
             plain (SurfaceNode . NProjectionTarget <$> pProjectionTarget context),
             plain (SurfaceNode . NRebuildGroup <$> pRebuildGroup context),
             plain (SurfaceNode . NProjectionOwner <$> pProjectionOwner context),
             plain (SurfaceNode . NWorkflow <$> pWorkflow),
             plain (SurfaceNode . NOperation <$> pOperation),
             do
               (aggregate, elements) <- pAggregate context
               pure (ParsedTopItem (SurfaceNode (NAggregate aggregate)) elements)
           ]
    )
  where
    plain parser = (`ParsedTopItem` []) <$> parser
