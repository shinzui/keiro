-- | Compile-time evidence for the public parser and renderer surface released
-- by keiro-dsl-0.7.0.0. Later frontend refactors may change implementations,
-- but these assignments must keep compiling.
module Keiro.Dsl.FrontendPublicApiProbe
  ( apiProbe,
  )
where

import Data.Text (Text)
import Keiro.Dsl.Frontend (FrontendFailure, LoweringFailure, lowerSurfaceDocument, lowerSurfaceSource, parseSurfaceSource)
import Keiro.Dsl.Grammar (Name, Node, Placement, Spec, specContext, specLayout, specModuleRoot, specNodes)
import Keiro.Dsl.LanguageVersion (ParseFailure, ParsedSource, SourceLanguage, SourceLanguageDiagnostic, SourceLanguageErrorCode, parsedSourceLanguage, parsedSpec, sourceLanguageErrorCode)
import Keiro.Dsl.Parser (ParseError, parseSource, parseSourceDocument, parseSpec, parseSpecText)
import Keiro.Dsl.PrettyPrint (renderSource, renderSpec)
import Keiro.Dsl.Source (SourceSpan)
import Keiro.Dsl.SourceIndex (ParsedSourceDocument, SemanticSourceIndex, SourcePositionQuality, SourceSubject, lookupSourceSpan)
import Keiro.Dsl.Syntax (SurfaceSource)

parseSurfaceSourceProbe :: FilePath -> Text -> Either FrontendFailure SurfaceSource
parseSurfaceSourceProbe = parseSurfaceSource

lowerSurfaceSourceProbe :: SurfaceSource -> Either LoweringFailure ParsedSource
lowerSurfaceSourceProbe = lowerSurfaceSource

lowerSurfaceDocumentProbe :: SurfaceSource -> Either LoweringFailure ParsedSourceDocument
lowerSurfaceDocumentProbe = lowerSurfaceDocument

parseSourceProbe :: FilePath -> Text -> Either ParseFailure ParsedSource
parseSourceProbe = parseSource

parseSourceDocumentProbe :: FilePath -> Text -> Either ParseFailure ParsedSourceDocument
parseSourceDocumentProbe = parseSourceDocument

lookupSourceSpanProbe :: SourceSubject -> SemanticSourceIndex -> Maybe (SourcePositionQuality, SourceSpan)
lookupSourceSpanProbe = lookupSourceSpan

parseSpecProbe :: FilePath -> Text -> Either ParseError Spec
parseSpecProbe = parseSpec

parseSpecTextProbe :: Text -> Either ParseError Spec
parseSpecTextProbe = parseSpecText

renderSourceProbe :: ParsedSource -> Text
renderSourceProbe = renderSource

renderSpecProbe :: Spec -> Text
renderSpecProbe = renderSpec

parsedSourceLanguageProbe :: ParsedSource -> SourceLanguage
parsedSourceLanguageProbe = parsedSourceLanguage

parsedSpecProbe :: ParsedSource -> Spec
parsedSpecProbe = parsedSpec

sourceLanguageErrorCodeProbe :: SourceLanguageDiagnostic -> SourceLanguageErrorCode
sourceLanguageErrorCodeProbe = sourceLanguageErrorCode

specContextProbe :: Spec -> Name
specContextProbe = specContext

specModuleRootProbe :: Spec -> Maybe Text
specModuleRootProbe = specModuleRoot

specLayoutProbe :: Spec -> Maybe Placement
specLayoutProbe = specLayout

specNodesProbe :: Spec -> [Node]
specNodesProbe = specNodes

-- | Referencing every assignment keeps @-Wall@ useful and makes the module a
-- real compile probe instead of passive documentation.
apiProbe :: ()
apiProbe =
  parseSurfaceSourceProbe `seq`
    lowerSurfaceSourceProbe `seq`
      lowerSurfaceDocumentProbe `seq`
        parseSourceProbe `seq`
          parseSourceDocumentProbe `seq`
            lookupSourceSpanProbe `seq`
              parseSpecProbe `seq`
                parseSpecTextProbe `seq`
                  renderSourceProbe `seq`
                    renderSpecProbe `seq`
                      parsedSourceLanguageProbe `seq`
                        parsedSpecProbe `seq`
                          sourceLanguageErrorCodeProbe `seq`
                            specContextProbe `seq`
                              specModuleRootProbe `seq`
                                specLayoutProbe `seq`
                                  specNodesProbe `seq`
                                    ()
