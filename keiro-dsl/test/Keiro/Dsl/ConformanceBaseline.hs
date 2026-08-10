module Keiro.Dsl.ConformanceBaseline (conformanceBaselineSpec) where

import Control.Monad (filterM, forM, forM_, unless)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.List (isSuffixOf, nub, sort, (\\))
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.FrontendCompatibility (SourceExpectation (..), observeSource, readRepoText)
import Keiro.Dsl.Grammar (Spec (..))
import Keiro.Dsl.LanguageVersion (currentAuthoringLanguageVersion, currentStableLanguageVersion, languageVersionNumber)
import Keiro.Dsl.Parser (parseSource, parseSourceDocument)
import Keiro.Dsl.RuntimePackage (RuntimePackageName (..))
import Keiro.Dsl.Scaffold (Context (..), ModuleKind (..), Placement (..), ScaffoldModule (..), defaultContext)
import Keiro.Dsl.ScaffoldRun (planIndexedServiceScaffold, planIndexedServiceScaffoldWithRuntimePackage, scaffoldServiceModules)
import Keiro.Dsl.SemanticContract (CheckedService (..), checkedSource)
import Keiro.Dsl.Skeleton (skeletonFor)
import Keiro.Dsl.SourceIndex (ParsedSourceDocument (..), SemanticSourceIndex)
import Keiro.Dsl.Workspace (WorkspaceSpec (..), fileContentSource, loadWorkspace)
import Keiro.Dsl.WorkspaceScaffold (WorkspacePlan (..), planWorkspaceScaffold)
import Numeric.Natural (Natural)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, takeExtension, (</>))
import Test.Hspec

data FixtureException = FixtureException
  { exceptionPath :: !FilePath,
    exceptionSourceForm :: !Text,
    exceptionEffectiveVersion :: !(Maybe Natural),
    exceptionRole :: !Text,
    exceptionReason :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON FixtureException where
  parseJSON = withObject "FixtureException" $ \fields ->
    FixtureException
      <$> fields .: "path"
      <*> fields .: "sourceForm"
      <*> fields .:? "effectiveVersion"
      <*> fields .: "role"
      <*> fields .: "reason"

data CompiledSuite = CompiledSuite
  { suiteComponent :: !Text,
    suiteDirectory :: !FilePath,
    suiteSource :: !(Maybe FilePath),
    suiteGeneration :: !Text,
    suiteRole :: !Text,
    suiteReason :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON CompiledSuite where
  parseJSON = withObject "CompiledSuite" $ \fields ->
    CompiledSuite
      <$> fields .: "component"
      <*> fields .: "directory"
      <*> fields .:? "source"
      <*> fields .: "generation"
      <*> fields .: "role"
      <*> fields .: "reason"

data ConformanceBaseline = ConformanceBaseline
  { baselineSchema :: !Text,
    baselineStableLanguageVersion :: !Natural,
    baselineAuthoringLanguageVersion :: !Natural,
    baselinePrimaryLanguageVersions :: ![Natural],
    baselineFixtureExceptions :: ![FixtureException],
    baselineCompiledSuites :: ![CompiledSuite]
  }
  deriving stock (Eq, Show)

instance FromJSON ConformanceBaseline where
  parseJSON = withObject "ConformanceBaseline" $ \fields ->
    ConformanceBaseline
      <$> fields .: "schema"
      <*> fields .: "stableLanguageVersion"
      <*> fields .: "authoringLanguageVersion"
      <*> fields .: "primaryLanguageVersions"
      <*> fields .: "fixtureExceptions"
      <*> fields .: "compiledSuites"

conformanceBaselineSpec :: SpecWith ()
conformanceBaselineSpec = describe "conformance baseline" $ do
  it "uses the registered stable and authoring languages plus explicit compatibility rows" $ do
    baseline <- readBaseline
    baselineSchema baseline `shouldBe` "keiro-dsl/conformance-baseline/1"
    baselineStableLanguageVersion baseline
      `shouldBe` languageVersionNumber currentStableLanguageVersion
    baselineAuthoringLanguageVersion baseline
      `shouldBe` languageVersionNumber currentAuthoringLanguageVersion
    paths <- fixturePaths
    observations <- forM paths $ \path -> (path,) <$> observeSource path
    baselinePrimaryLanguageVersions baseline `shouldContain` [languageVersionNumber currentStableLanguageVersion]
    baselinePrimaryLanguageVersions baseline `shouldContain` [languageVersionNumber currentAuthoringLanguageVersion]
    let primaryVersions = baselinePrimaryLanguageVersions baseline
        nonStablePaths =
          sort
            [ path
            | (path, observation) <- observations,
              sourceForm observation /= "declared"
                || maybe True (`notElem` primaryVersions) (sourceEffectiveVersion observation)
            ]
        exceptionPaths = sort (map exceptionPath (baselineFixtureExceptions baseline))
    (nonStablePaths \\ exceptionPaths)
      `shouldBe` ([] :: [FilePath])
    (exceptionPaths \\ nonStablePaths)
      `shouldBe` ([] :: [FilePath])
    forM_ (baselineFixtureExceptions baseline) $ \exception -> do
      observation <- observeSource (exceptionPath exception)
      sourceForm observation `shouldBe` exceptionSourceForm exception
      sourceEffectiveVersion observation `shouldBe` exceptionEffectiveVersion exception
      exceptionRole exception
        `shouldBe` "compatibility-proof"
      exceptionReason exception `shouldSatisfy` (not . T.null . T.strip)

  it "accounts for every compiled conformance component and primary generated banner" $ do
    baseline <- readBaseline
    cabal <- readRepoText "keiro-dsl/keiro-dsl.cabal"
    let cabalComponents = conformanceComponents cabal
        manifestComponents = sort (map suiteComponent (baselineCompiledSuites baseline))
    (cabalComponents \\ manifestComponents)
      `shouldBe` ([] :: [Text])
    (manifestComponents \\ cabalComponents)
      `shouldBe` ([] :: [Text])
    forM_ (baselineCompiledSuites baseline) $ \suite -> do
      suiteRole suite
        `shouldSatisfy` (`elem` ["stable-primary", "candidate-primary", "compatibility-proof", "version-independent"])
      suiteReason suite `shouldSatisfy` (not . T.null . T.strip)
      directory <- resolveRepoDirectory ("keiro-dsl" </> suiteDirectory suite)
      doesDirectoryExist directory `shouldReturn` True
      case primaryVersionForRole baseline (suiteRole suite) of
        Just primaryVersion -> do
          unless (suiteGeneration suite `elem` ["workspace", "skeletons"]) $ do
            source <- requiredSuiteSource suite
            observation <- observeSource source
            sourceForm observation `shouldBe` "declared"
            sourceResult observation `shouldBe` "accept"
            sourceEffectiveVersion observation `shouldBe` Just primaryVersion
          banners <- generatedBannerLines directory
          unless (not (null banners)) $
            expectationFailure (T.unpack (suiteComponent suite <> " has no generated banners"))
          let expectedVersion = "language keiro-dsl " <> T.pack (show primaryVersion)
              primaryBanners = [(path, banner) | (path, banner) <- banners, expectedVersion `T.isInfixOf` banner]
              isVersionIndependentAuxiliary banner = "@generated by keiro-dsl codec comparison" `T.isInfixOf` banner
          unless (not (null primaryBanners)) $
            expectationFailure (T.unpack (suiteComponent suite <> " has no " <> T.pack (show primaryVersion) <> " generated banners"))
          forM_ banners $ \(path, banner) ->
            unless (expectedVersion `T.isInfixOf` banner || isVersionIndependentAuxiliary banner) $
              expectationFailure (T.unpack (decorate path banner <> " (expected " <> expectedVersion <> ")"))
          expectedPaths <- expectedStableGeneratedPaths suite
          let actualPaths = sort (nub (map fst primaryBanners))
              -- Plan 218 refreshes focused compiled fixtures only. The final
              -- corpus-wide regeneration in plan 222 will remove this narrow
              -- inventory normalization after every mapped suite has adopted
              -- its new context module.
              deferredContextModule path =
                "/StructuralConformance.hs" `isSuffixOf` path
                  || "/BehaviorSourceMap.hs" `isSuffixOf` path
              comparedExpectedPaths = filter (not . deferredContextModule) expectedPaths
              comparedActualPaths = filter (not . deferredContextModule) actualPaths
          unless (comparedActualPaths == comparedExpectedPaths) $
            expectationFailure
              ( T.unpack
                  ( suiteComponent suite
                      <> " generated module inventory differs\nexpected: "
                      <> T.pack (show comparedExpectedPaths)
                      <> "\n but got: "
                      <> T.pack (show comparedActualPaths)
                  )
              )
        Nothing -> pure ()

primaryVersionForRole :: ConformanceBaseline -> Text -> Maybe Natural
primaryVersionForRole baseline role = case role of
  "stable-primary" -> Just (baselineStableLanguageVersion baseline)
  "candidate-primary" -> Just (baselineAuthoringLanguageVersion baseline)
  _ -> Nothing

expectedStableGeneratedPaths :: CompiledSuite -> IO [FilePath]
expectedStableGeneratedPaths suite = case suiteGeneration suite of
  "source" -> do
    source <- requiredSuiteSource suite
    generatedPathsForSource source
  "source-with-conformance-facade" -> do
    source <- requiredSuiteSource suite
    sourceText <- readRepoText source
    (service, sourceIndex) <- parseCheckedDocument source sourceText
    modules <- case planIndexedServiceScaffoldWithRuntimePackage (Just (RuntimePackageName "conformance-runtime")) sourceIndex (defaultContext (specContext (checkedSpec service))) service of
      Left refusals -> expectationFailure (show refusals) >> fail "stable configured source scaffold refusal"
      Right value -> pure value
    pure (generatedPaths modules)
  "workspace" -> do
    source <- requiredSuiteSource suite
    resolved <- resolveRepoFile ("keiro-dsl" </> source)
    loaded <- loadWorkspace (fileContentSource (takeDirectory resolved)) resolved
    workspace <- case loaded of
      Left problem -> expectationFailure (show problem) >> fail "invalid stable workspace"
      Right value -> pure value
    plan <- case planWorkspaceScaffold "goldens" (workspaceContext workspace) workspace of
      Left refusals -> expectationFailure (show refusals) >> fail "stable workspace scaffold refusal"
      Right value -> pure value
    pure (generatedPaths (map fst (wpModules plan)))
  "skeletons" -> fmap (sort . nub . concat) . forM skeletonModuleRoots $ \(skeletonKind, root) -> do
    source <- case skeletonFor skeletonKind of
      Left problem -> expectationFailure (T.unpack problem) >> fail "invalid stable skeleton"
      Right value -> pure value
    service <- parseCheckedSource ("new:" <> T.unpack skeletonKind) source
    let scaffoldContext = (defaultContext (specContext (checkedSpec service))) {moduleRoot = root}
    pure (generatedPaths (scaffoldServiceModules scaffoldContext service))
  other -> expectationFailure (T.unpack (suiteComponent suite <> " has invalid stable generation mode " <> other)) >> fail "invalid stable generation mode"

generatedPathsForSource :: FilePath -> IO [FilePath]
generatedPathsForSource path = do
  source <- readRepoText path
  (service, sourceIndex) <- parseCheckedDocument path source
  modules <- case planIndexedServiceScaffold sourceIndex (defaultContext (specContext (checkedSpec service))) service of
    Left refusals -> expectationFailure (show refusals) >> fail "stable source scaffold refusal"
    Right value -> pure value
  pure (generatedPaths modules)

parseCheckedSource :: FilePath -> Text -> IO CheckedService
parseCheckedSource path source = case parseSource path source of
  Left problem -> expectationFailure (show problem) >> fail "invalid stable source"
  Right parsed -> pure (checkedSource parsed)

parseCheckedDocument :: FilePath -> Text -> IO (CheckedService, SemanticSourceIndex)
parseCheckedDocument path source = case parseSourceDocument path source of
  Left problem -> expectationFailure (show problem) >> fail "invalid stable source document"
  Right ParsedSourceDocument {documentParsedSource = parsed, documentSourceIndex = sourceIndex} ->
    pure (checkedSource parsed, sourceIndex)

generatedPaths :: [ScaffoldModule] -> [FilePath]
generatedPaths = sort . map modulePath . filter ((== Generated) . kind)

requiredSuiteSource :: CompiledSuite -> IO FilePath
requiredSuiteSource suite = case suiteSource suite of
  Nothing -> expectationFailure (T.unpack (suiteComponent suite <> " has no source")) >> fail "missing stable source"
  Just source -> pure source

workspaceContext :: WorkspaceSpec -> Context
workspaceContext workspace =
  Context
    { contextName = wsContext workspace,
      moduleRoot = maybe "" id (wsModuleRoot workspace),
      placement = maybe GeneratedPrefix id (wsLayout workspace)
    }

skeletonModuleRoots :: [(Text, Text)]
skeletonModuleRoots =
  [ ("aggregate", "SkelAggregate"),
    ("process", "SkelProcess"),
    ("router", "SkelRouter"),
    ("contract", "SkelContract"),
    ("intake", "SkelIntake"),
    ("emit", "SkelEmit"),
    ("workqueue", "SkelQueue"),
    ("workflow", "SkelWorkflow")
  ]

readBaseline :: IO ConformanceBaseline
readBaseline = do
  path <- resolveRepoFile "keiro-dsl/test/conformance-baseline.json"
  decoded <- Aeson.eitherDecodeFileStrict' path
  case decoded of
    Left problem -> expectationFailure problem >> fail "invalid conformance baseline"
    Right baseline -> pure baseline

fixturePaths :: IO [FilePath]
fixturePaths = do
  root <- resolveRepoDirectory "keiro-dsl/test/fixtures"
  relative <- walk root ""
  pure . sort $ ["test/fixtures" </> path | path <- relative, takeExtension path == ".keiro"]

conformanceComponents :: Text -> [Text]
conformanceComponents =
  sort
    . mapMaybe (listToMaybe . T.words)
    . filter ("keiro-dsl-conformance" `T.isPrefixOf`)
    . mapMaybeTestSuite
    . T.lines
  where
    mapMaybeTestSuite = foldr collect []
    collect line rest = case T.stripPrefix "test-suite " (T.strip line) of
      Just component -> component : rest
      Nothing -> rest

generatedBannerLines :: FilePath -> IO [(FilePath, Text)]
generatedBannerLines root = do
  relative <- walk root ""
  fmap concat . forM [path | path <- relative, takeExtension path == ".hs"] $ \path -> do
    contents <- TIO.readFile (root </> path)
    pure
      [ (path, line)
      | line <- T.lines contents,
        "@generated" `T.isInfixOf` line
      ]

walk :: FilePath -> FilePath -> IO [FilePath]
walk root relative = do
  entries <- sort <$> listDirectory (root </> relative)
  fmap concat . forM entries $ \entry -> do
    let child = if null relative then entry else relative </> entry
    isDirectory <- doesDirectoryExist (root </> child)
    if isDirectory then walk root child else pure [child]

resolveRepoFile :: FilePath -> IO FilePath
resolveRepoFile path = do
  override <- lookupEnv "KEIRO_DSL_TEST_ROOT"
  let packageRelative = maybe path T.unpack (T.stripPrefix "keiro-dsl/" (T.pack path))
      candidates = nub ([packageRelative, path] <> maybe [] (\root -> [root </> packageRelative, root </> path]) override)
  existing <- filterM doesFileExist candidates
  case existing of
    candidate : _ -> pure candidate
    [] -> fail ("unable to locate conformance baseline file " <> show path)

resolveRepoDirectory :: FilePath -> IO FilePath
resolveRepoDirectory path = do
  override <- lookupEnv "KEIRO_DSL_TEST_ROOT"
  let packageRelative = maybe path T.unpack (T.stripPrefix "keiro-dsl/" (T.pack path))
      candidates = nub ([packageRelative, path] <> maybe [] (\root -> [root </> packageRelative, root </> path]) override)
  existing <- filterM doesDirectoryExist candidates
  case existing of
    candidate : _ -> pure candidate
    [] -> fail ("unable to locate conformance directory " <> show path)

decorate :: FilePath -> Text -> Text
decorate path banner = T.pack path <> ": " <> banner
