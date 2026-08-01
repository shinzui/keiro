{-# LANGUAGE ImportQualifiedPost #-}

-- | Released-language dispatch and complete document composition.
module Keiro.Dsl.Parser.Document
  ( parseSurfaceSource,
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Frontend.Internal (FrontendFailure (..))
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser.Aggregate (pAggregate)
import Keiro.Dsl.Parser.Coordination (pProcess, pRouter)
import Keiro.Dsl.Parser.Core
import Keiro.Dsl.Parser.Declaration (pEnumDecl, pIdDecl, pRuleDecl)
import Keiro.Dsl.Parser.Integration (pContract, pEmit, pIntake, pPublisher)
import Keiro.Dsl.Parser.Mapped (pMappedTopItem)
import Keiro.Dsl.Parser.Preamble
import Keiro.Dsl.Parser.Queue (pPgmqDispatch, pWorkqueue)
import Keiro.Dsl.Parser.ReadModel (pReadModel)
import Keiro.Dsl.Parser.Workflow (pOperation, pWorkflow)
import Keiro.Dsl.Source
import Keiro.Dsl.Syntax
import Text.Megaparsec
import Prelude hiding (span)

parseSurfaceSource :: FilePath -> Text -> Either FrontendFailure SurfaceSource
parseSurfaceSource src input = first FrontendParseFailure $ do
  sourceLanguage <- selectSourceLanguage src input
  definition <- case lookupLanguageDefinition (effectiveLanguageVersion sourceLanguage) of
    Just value -> Right value
    Nothing -> Left (unsupportedDiagnostic src sourceLanguage)
  parseSelectedBody definition sourceLanguage
  where
    parseSelectedBody definition sourceLanguage =
      let version = definitionVersion definition
          laterPreambleCode = case sourceLanguage of
            LegacyUnversioned -> MisplacedLanguagePreamble
            DeclaredLanguage {} -> DuplicateLanguagePreamble
          parser = case definitionBodyParser definition of
            LanguageBodyParserV1 ->
              sc
                *> case sourceLanguage of
                  LegacyUnversioned -> pSurfaceDocument src sourceLanguage Nothing version laterPreambleCode <* eof
                  DeclaredLanguage {} -> do
                    locatedPreamble <- withOwnedSpan (sourceLanguage <$ pDeclaredPreamble)
                    pSurfaceDocument src sourceLanguage (Just locatedPreamble) version laterPreambleCode <* eof
            LanguageBodyParserV2 ->
              sc *> do
                locatedPreamble <- withOwnedSpan (sourceLanguage <$ pDeclaredPreamble)
                pSurfaceDocument src sourceLanguage (Just locatedPreamble) version laterPreambleCode <* eof
       in case runParser parser src input of
            Left bundle -> case firstContextualFailure bundle of
              Just contextual -> Left (SourceLanguageFailure (contextualDiagnostic src sourceLanguage contextual))
              Nothing -> Left (BodyGrammarFailure (T.pack (errorBundlePretty bundle)))
            Right surface -> Right surface

-- Top level
--------------------------------------------------------------------------------

pContextualPreamble :: SourceLanguageErrorCode -> P a
pContextualPreamble code = do
  loc <- getLoc
  _ <- try pDeclaredPreamble
  contextualFailureAt loc code

pSurfaceDocument :: FilePath -> SourceLanguage -> Maybe (Located SourceLanguage) -> LanguageVersion -> SourceLanguageErrorCode -> P SurfaceSource
pSurfaceDocument sourceName sourceLanguage preamble version laterPreambleCode = do
  spec <- pSurfaceSpec version laterPreambleCode
  pure SurfaceSource {source = sourceName, language = sourceLanguage, preamble, spec}

pSurfaceSpec :: LanguageVersion -> SourceLanguageErrorCode -> P (Located SurfaceSpec)
pSurfaceSpec version laterPreambleCode = do
  pContextualPreamble laterPreambleCode <|> pure ()
  context <- withOwnedSpan (keyword "context" *> wireWord)
  moduleRoot <- optional (withOwnedSpan pModuleClause)
  layout <- optional (withOwnedSpan pLayoutClause)
  parsedItems <- many (withOwnedSpan (pTopItem version laterPreambleCode))
  let items = map surfaceItem parsedItems
      elements = concatMap surfaceElements parsedItems
  let contextSpan@SourceSpan {source, start} = spanOf context
      finalSpan = case reverse items of
        item : _ -> spanOf item
        [] -> case layout of
          Just value -> spanOf value
          Nothing -> maybe contextSpan spanOf moduleRoot
      SourceSpan {end} = finalSpan
  pure
    Located
      { span = SourceSpan {source, start, end},
        value = SurfaceSpec {context, moduleRoot, layout, items, elements}
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

pTopItem :: LanguageVersion -> SourceLanguageErrorCode -> P ParsedTopItem
pTopItem version laterPreambleCode =
  choice
    ( [ pContextualPreamble laterPreambleCode,
        plain (SurfaceId <$> pIdDecl version),
        plain (SurfaceEnum <$> pEnumDecl version),
        do
          (rule, elements) <- pRuleDecl version
          pure (ParsedTopItem (SurfaceRule rule) elements),
        plain (pMappedTopItem version)
      ]
        ++ [ plain (SurfaceNode . NRouter <$> pRouter),
             plain (SurfaceNode . NProcess <$> pProcess),
             plain (SurfaceNode . NContract <$> pContract),
             plain (SurfaceNode . NIntake <$> pIntake),
             plain (SurfaceNode . NEmit <$> pEmit),
             plain (SurfaceNode . NPublisher <$> pPublisher),
             plain (SurfaceNode . NWorkqueue <$> pWorkqueue),
             plain (SurfaceNode . NPgmqDispatch <$> pPgmqDispatch),
             plain (SurfaceNode . NReadModel <$> pReadModel),
             plain (SurfaceNode . NWorkflow <$> pWorkflow),
             plain (SurfaceNode . NOperation <$> pOperation),
             do
               (aggregate, elements) <- pAggregate version
               pure (ParsedTopItem (SurfaceNode (NAggregate aggregate)) elements)
           ]
    )
  where
    plain parser = (`ParsedTopItem` []) <$> parser
