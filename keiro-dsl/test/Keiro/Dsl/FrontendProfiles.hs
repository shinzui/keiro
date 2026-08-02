{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NoFieldSelectors #-}

module Keiro.Dsl.FrontendProfiles (frontendProfilesSpec) where

import Control.Monad (forM_)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Frontend
import Keiro.Dsl.FrontendCompatibility (readRepoText)
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser (parseSource)
import Keiro.Dsl.SemanticContract
import Keiro.Dsl.Source
import Keiro.Dsl.Syntax
import Test.Hspec
import Prelude hiding (span)

frontendProfilesSpec :: SpecWith ()
frontendProfilesSpec = do
  describe "released language profiles" $ do
    it "pins each released syntax profile, predecessor, and runtime contract explicitly" $ do
      map definitionRow (NE.toList languageRegistry)
        `shouldBe` [ (1, Nothing, "keiro-dsl/syntax-profile/1", "keiro-dsl/runtime-semantics/1"),
                     (2, Just 1, "keiro-dsl/syntax-profile/2", "keiro-dsl/runtime-semantics/1"),
                     (3, Just 2, "keiro-dsl/syntax-profile/2", "keiro-dsl/runtime-semantics/2"),
                     (4, Just 3, "keiro-dsl/syntax-profile/2", "keiro-dsl/runtime-semantics/3")
                   ]
      forM_ allFeatures $ \feature -> do
        languageFeatureMinimumVersion feature `shouldBe` version 2
        languageSupportsFeature (version 1) feature `shouldBe` False
        languageSupportsFeature (version 2) feature `shouldBe` True
        languageSupportsFeature (version 3) feature `shouldBe` True
        languageSupportsFeature (version 4) feature `shouldBe` True

    it "does not infer a hypothetical successor profile or runtime contract" $ do
      lookupLanguageDefinition (version 5) `shouldBe` Nothing
      effectiveLanguageContractForVersion (version 5) `shouldBe` Nothing
      forM_ allFeatures $ \feature -> languageSupportsFeature (version 5) feature `shouldBe` False
      languageVersionPolicy <- readRepoText "keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs"
      semanticPolicy <- readRepoText "keiro-dsl/src/Keiro/Dsl/SemanticContract.hs"
      languageVersionPolicy `shouldNotSatisfy` T.isInfixOf "version >="
      semanticPolicy `shouldNotSatisfy` T.isInfixOf "version >="

    it "checks every real feature marker against the exact selected profile" $ do
      forM_ featureCases $ \FeatureCase {feature, marker, body} ->
        forM_ [1, 2, 3, 4] $ \versionNumber -> do
          let sourceName = "profile-" <> show versionNumber <> ".keiro"
              source = preamble versionNumber <> body
          case (versionNumber, parseSurfaceSource sourceName source) of
            (1, Left FrontendFailure {phase, code, span, supportedVersions}) -> do
              phase `shouldBe` BodyParsingPhase
              code `shouldBe` SourceLanguageError LanguageFeatureRequiresVersion
              spanText source span `shouldBe` marker
              supportedVersions `shouldBe` [version 2, version 3, version 4]
              languageSupportsFeature (version versionNumber) feature `shouldBe` False
            (1, result) -> expectationFailure ("expected v1 feature refusal, got " <> show result)
            (_, Right _) -> languageSupportsFeature (version versionNumber) feature `shouldBe` True
            (_, Left failure) -> expectationFailure (T.unpack (renderFrontendFailure failure))

    it "keeps feature spellings inert in comments, strings, wire keys, and identifiers" $ do
      inertBody <- readRepoText "keiro-dsl/test/fixtures/language-identifier-v1.keiro"
      forM_ [1, 2, 3, 4] $ \versionNumber ->
        parseSurfaceSource ("inert-" <> show versionNumber <> ".keiro") (preamble versionNumber <> inertBody)
          `shouldSatisfy` isRight

  describe "frontend diagnostics" $ do
    it "classifies malformed and unsupported preambles at source selection with exact spans" $ do
      assertSourceSelection InvalidLanguageVersion "language keiro-dsl nope\ncontext malformed\n" "language keiro-dsl nope"
      assertSourceSelection UnsupportedLanguageVersion "language keiro-dsl 5\ncontext future\n" "language keiro-dsl 5"

    it "reports ordinary body syntax with expected items and a point span" $ do
      let source = "language keiro-dsl 1\ncontext body\nlayout\n"
      case parseSurfaceSource "body.keiro" source of
        Left FrontendFailure {phase, code, span = SourceSpan {start, end}, message, expected} -> do
          phase `shouldBe` BodyParsingPhase
          code `shouldBe` BodySyntaxError
          start `shouldBe` end
          message `shouldSatisfy` T.isInfixOf "unexpected end of input"
          expected `shouldSatisfy` (not . null)
        other -> expectationFailure ("expected structured body failure, got " <> show other)

    it "converts lowering refusals into the common phase/code/span model" $ do
      surface <- parseRight "owned.keiro" "context owned\n"
      let corrupted = case surface of
            SurfaceSource {source, language, preamble = sourcePreamble, spec = Located {span = SourceSpan {start, end}, value}} ->
              SurfaceSource
                { source,
                  language,
                  preamble = sourcePreamble,
                  spec = Located {span = SourceSpan {source = "other.keiro", start, end}, value}
                }
      case lowerSurfaceSource corrupted of
        Left lowering@LoweringFailure {span = loweringSpan} ->
          case frontendFailureFromLowering lowering of
            FrontendFailure {phase, code, span} -> do
              phase `shouldBe` LoweringPhase
              code `shouldBe` LoweringError SourceNameMismatch
              span `shouldBe` loweringSpan
        Right _ -> expectationFailure "expected lowering refusal"

    it "keeps the released compatibility renderer byte-identical" $ do
      forM_
        [ "language keiro-dsl nope\ncontext malformed\n",
          "language keiro-dsl 5\ncontext future\n",
          preamble 1 <> featureBody TypedAggregateExpressionSyntax,
          "language keiro-dsl 1\ncontext\n"
        ]
        $ \source -> case (parseSurfaceSource "compat.keiro" source, parseSource "compat.keiro" source) of
          (Left frontendFailure, Left compatibilityFailure) ->
            renderFrontendFailure frontendFailure `shouldBe` renderParseFailure compatibilityFailure
          other -> expectationFailure ("expected matching failures, got " <> show other)

data FeatureCase = FeatureCase
  { feature :: !LanguageFeature,
    marker :: !Text,
    body :: !Text
  }

featureCases :: [FeatureCase]
featureCases =
  [ FeatureCase NominalBindingSyntax "using" (featureBody NominalBindingSyntax),
    FeatureCase IntegerScalarSyntax "Integer" (featureBody IntegerScalarSyntax),
    FeatureCase TypedAggregateExpressionSyntax "cmd." (featureBody TypedAggregateExpressionSyntax),
    FeatureCase ExplicitTransitionImplementationSyntax "implementation hole" (featureBody ExplicitTransitionImplementationSyntax)
  ]

featureBody :: LanguageFeature -> Text
featureBody = \case
  NominalBindingSyntax -> T.unlines ["context profile", "id ProfileId prefix=profile using {}"]
  IntegerScalarSyntax -> T.unlines ["context profile", "aggregate Counter", "  regs", "    count Integer = 0", "  states Open"]
  TypedAggregateExpressionSyntax ->
    T.unlines
      [ "context profile",
        "aggregate Counter",
        "  regs",
        "    count Int = 0",
        "  states Open",
        "  command Add { amount:Int }",
        "  event Added = fields(Add)",
        "  Open -- Add --> guard cmd.amount == reg.count ; emit Added ; goto Open"
      ]
  ExplicitTransitionImplementationSyntax ->
    T.unlines
      [ "context profile",
        "aggregate Counter",
        "  regs",
        "  states Open",
        "  command Tick {}",
        "  event Ticked = fields(Tick)",
        "  Open -- Tick --> implementation hole ; emit Ticked ; goto Open"
      ]

allFeatures :: [LanguageFeature]
allFeatures = [NominalBindingSyntax, IntegerScalarSyntax, TypedAggregateExpressionSyntax, ExplicitTransitionImplementationSyntax]

preamble :: Int -> Text
preamble versionNumber = "language keiro-dsl " <> T.pack (show versionNumber) <> "\n"

version :: Int -> LanguageVersion
version number = maybe (error "invalid test language version") id (languageVersion (fromIntegral number))

definitionRow :: LanguageDefinition -> (Integer, Maybe Integer, Text, Text)
definitionRow definition =
  ( fromIntegral (languageVersionNumber (definitionVersion definition)),
    fromIntegral . languageVersionNumber <$> definitionPredecessor definition,
    syntaxProfileIdentifier (definitionSyntaxProfile definition),
    definitionRuntimeSemantics definition
  )

assertSourceSelection :: SourceLanguageErrorCode -> Text -> Text -> Expectation
assertSourceSelection expectedCode source expectedSpan =
  case parseSurfaceSource "selection.keiro" source of
    Left FrontendFailure {phase, code, span} -> do
      phase `shouldBe` SourceSelectionPhase
      code `shouldBe` SourceLanguageError expectedCode
      spanText source span `shouldBe` expectedSpan
    other -> expectationFailure ("expected structured source-selection failure, got " <> show other)

parseRight :: FilePath -> Text -> IO SurfaceSource
parseRight sourceName source =
  case parseSurfaceSource sourceName source of
    Left failure -> expectationFailure (T.unpack (renderFrontendFailure failure)) >> fail "unreachable"
    Right value -> pure value

spanText :: Text -> SourceSpan -> Text
spanText source SourceSpan {start = SourcePoint {offset = startOffset}, end = SourcePoint {offset = endOffset}} =
  T.take (endOffset - startOffset) (T.drop startOffset source)

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _) = False
