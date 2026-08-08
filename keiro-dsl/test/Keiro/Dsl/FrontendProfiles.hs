{-# LANGUAGE NoFieldSelectors #-}

module Keiro.Dsl.FrontendProfiles (frontendProfilesSpec) where

import Control.Monad (forM_)
import Data.List (tails)
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
                     (4, Just 3, "keiro-dsl/syntax-profile/3", "keiro-dsl/runtime-semantics/3"),
                     (5, Just 4, "keiro-dsl/syntax-profile/4", "keiro-dsl/runtime-semantics/4")
                   ]
      map definitionCapabilities (NE.toList languageRegistry)
        `shouldBe` [ [],
                     [],
                     [GeneratedIdDomainTypeIdV7, NominalEqualityV2],
                     [GeneratedIdDomainTypeIdV7, NominalEqualityV2, ContractIdDomainTypeIdV7, StrictSpecSurfaceValidation],
                     [GeneratedIdDomainTypeIdV7, NominalEqualityV2, ContractIdDomainTypeIdV7, StrictSpecSurfaceValidation, ProjectionCatalogRuntime]
                   ]
      map (runtimeProfileFoldSegments . definitionRuntimeSemanticsProfile) (NE.toList languageRegistry)
        `shouldBe` [ [],
                     [],
                     ["semantic-contract:keiro-dsl/runtime-semantics/2"],
                     ["semantic-contract:keiro-dsl/runtime-semantics/2"],
                     ["semantic-contract:keiro-dsl/projection-catalog/1", "semantic-contract:keiro-dsl/runtime-semantics/2"]
                   ]
      map definitionSupport (NE.toList languageRegistry)
        `shouldBe` [CompatibilityOnly, CompatibilityOnly, CompatibilityOnly, Stable, Candidate]
      map definitionMaturity (NE.toList languageRegistry)
        `shouldBe` [PublishedLanguage, PublishedLanguage, PublishedLanguage, PublishedLanguage, CandidateLanguage]
      currentStableLanguageVersion `shouldBe` version 4
      currentAuthoringLanguageVersion `shouldBe` version 5
      languageSupportForVersion (version 1) `shouldBe` Just CompatibilityOnly
      languageSupportForVersion (version 2) `shouldBe` Just CompatibilityOnly
      languageSupportForVersion (version 3) `shouldBe` Just CompatibilityOnly
      languageSupportForVersion (version 4) `shouldBe` Just Stable
      languageSupportForVersion (version 5) `shouldBe` Just Candidate
      languageSupportForVersion (version 999999) `shouldBe` Nothing
      [definitionVersion definition | definition <- NE.toList languageRegistry, definitionSupport definition == Stable]
        `shouldBe` [currentStableLanguageVersion]
      definitionVersion (NE.last languageRegistry) `shouldBe` currentAuthoringLanguageVersion
      definitionPredecessor (NE.last languageRegistry) `shouldBe` Just (version 4)
      forM_ (adjacent (NE.toList languageRegistry)) $ \(predecessor, successor) ->
        forM_ allRuntimeCapabilities $ \capability ->
          runtimeProfileHasCapability (definitionRuntimeSemanticsProfile predecessor) capability
            `shouldSatisfy` \wasSupported ->
              not wasSupported
                || runtimeProfileHasCapability (definitionRuntimeSemanticsProfile successor) capability
      forM_ allFeatures $ \feature -> do
        let minimumVersion = case feature of ProjectionCatalogSyntax -> version 5; FieldAliasSyntax -> version 4; _ -> version 2
        languageFeatureMinimumVersion feature `shouldBe` minimumVersion
        forM_ [1, 2, 3, 4, 5] $ \versionNumber ->
          languageSupportsFeature (version versionNumber) feature
            `shouldBe` (version versionNumber >= minimumVersion)

    it "does not infer a profile or runtime contract for an unregistered sentinel" $ do
      lookupLanguageDefinition (version 999999) `shouldBe` Nothing
      effectiveLanguageContractForVersion (version 999999) `shouldBe` Nothing
      forM_ allFeatures $ \feature -> languageSupportsFeature (version 999999) feature `shouldBe` False
      languageVersionPolicy <- readRepoText "keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs"
      semanticPolicy <- readRepoText "keiro-dsl/src/Keiro/Dsl/SemanticContract.hs"
      languageVersionPolicy `shouldNotSatisfy` T.isInfixOf "version >="
      semanticPolicy `shouldNotSatisfy` T.isInfixOf "version >="

    it "keeps runtime identifier strings out of semantic gates" $ do
      forM_
        [ "keiro-dsl/src/Keiro/Dsl/IdDomain.hs",
          "keiro-dsl/src/Keiro/Dsl/NominalType.hs",
          "keiro-dsl/src/Keiro/Dsl/Validate.hs"
        ]
        $ \path -> do
          policy <- readRepoText path
          policy `shouldNotSatisfy` T.isInfixOf "keiro-dsl/runtime-semantics/"

    it "checks every real feature marker against the exact selected profile" $ do
      forM_ featureCases $ \FeatureCase {feature, marker, body} ->
        forM_ [1, 2, 3, 4, 5] $ \versionNumber -> do
          let sourceName = "profile-" <> show versionNumber <> ".keiro"
              source = preamble versionNumber <> body
          case (languageSupportsFeature (version versionNumber) feature, parseSurfaceSource sourceName source) of
            (False, Left FrontendFailure {phase, code, span, supportedVersions}) -> do
              phase `shouldBe` BodyParsingPhase
              code `shouldBe` SourceLanguageError LanguageFeatureRequiresVersion
              spanText source span `shouldBe` marker
              supportedVersions `shouldBe` languageVersionsSupportingFeature feature
              languageSupportsFeature (version versionNumber) feature `shouldBe` False
            (False, result) -> expectationFailure ("expected feature refusal, got " <> show result)
            (True, Right _) -> languageSupportsFeature (version versionNumber) feature `shouldBe` True
            (True, Left failure) -> expectationFailure (T.unpack (renderFrontendFailure failure))

    it "keeps feature spellings inert in comments, strings, wire keys, and identifiers" $ do
      inertBody <- readRepoText "keiro-dsl/test/fixtures/language-identifier-v1.keiro"
      forM_ [1, 2, 3, 4, 5] $ \versionNumber ->
        parseSurfaceSource ("inert-" <> show versionNumber <> ".keiro") (preamble versionNumber <> inertBody)
          `shouldSatisfy` isRight

  describe "frontend diagnostics" $ do
    it "classifies malformed and unsupported preambles at source selection with exact spans" $ do
      assertSourceSelection InvalidLanguageVersion "language keiro-dsl nope\ncontext malformed\n" "language keiro-dsl nope"
      assertSourceSelection UnsupportedLanguageVersion "language keiro-dsl 999999\ncontext unregistered\n" "language keiro-dsl 999999"

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
          "language keiro-dsl 999999\ncontext unregistered\n",
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
    FeatureCase ExplicitTransitionImplementationSyntax "implementation hole" (featureBody ExplicitTransitionImplementationSyntax),
    FeatureCase FieldAliasSyntax "haskell" (featureBody FieldAliasSyntax),
    FeatureCase ProjectionCatalogSyntax "target" (featureBody ProjectionCatalogSyntax)
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
  FieldAliasSyntax ->
    T.unlines
      [ "context profile",
        "aggregate Profile",
        "  regs",
        "  states Open",
        "  command Rename { type haskell payloadType as \"type\":Text }"
      ]
  ProjectionCatalogSyntax ->
    T.unlines
      [ "context profile",
        "target profile_view {",
        "  schema = \"public\"",
        "  table = \"profile_view\"",
        "  reset = preserve",
        "}"
      ]

allFeatures :: [LanguageFeature]
allFeatures = [NominalBindingSyntax, IntegerScalarSyntax, TypedAggregateExpressionSyntax, ExplicitTransitionImplementationSyntax, FieldAliasSyntax, ProjectionCatalogSyntax]

allRuntimeCapabilities :: [RuntimeCapability]
allRuntimeCapabilities = [minBound .. maxBound]

definitionCapabilities :: LanguageDefinition -> [RuntimeCapability]
definitionCapabilities definition =
  [ capability
  | capability <- allRuntimeCapabilities,
    runtimeProfileHasCapability (definitionRuntimeSemanticsProfile definition) capability
  ]

adjacent :: [a] -> [(a, a)]
adjacent values = [(left, right) | left : right : _ <- tails values]

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
