module Keiro.Dsl.ConformanceBaseline (conformanceBaselineSpec) where

import Control.Monad (filterM, forM, forM_, unless)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.List (sort, (\\))
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.FrontendCompatibility (SourceExpectation (..), observeSource, readRepoText)
import Keiro.Dsl.LanguageVersion (currentStableLanguageVersion, languageVersionNumber)
import Numeric.Natural (Natural)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeExtension, (</>))
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
      <*> fields .: "role"
      <*> fields .: "reason"

data ConformanceBaseline = ConformanceBaseline
  { baselineSchema :: !Text,
    baselineStableLanguageVersion :: !Natural,
    baselineFixtureExceptions :: ![FixtureException],
    baselineCompiledSuites :: ![CompiledSuite]
  }
  deriving stock (Eq, Show)

instance FromJSON ConformanceBaseline where
  parseJSON = withObject "ConformanceBaseline" $ \fields ->
    ConformanceBaseline
      <$> fields .: "schema"
      <*> fields .: "stableLanguageVersion"
      <*> fields .: "fixtureExceptions"
      <*> fields .: "compiledSuites"

conformanceBaselineSpec :: SpecWith ()
conformanceBaselineSpec = describe "conformance baseline" $ do
  it "uses the registered stable language and explicit non-stable fixture rows" $ do
    baseline <- readBaseline
    baselineSchema baseline `shouldBe` "keiro-dsl/conformance-baseline/1"
    baselineStableLanguageVersion baseline
      `shouldBe` languageVersionNumber currentStableLanguageVersion
    paths <- fixturePaths
    observations <- forM paths $ \path -> (path,) <$> observeSource path
    let stableVersion = languageVersionNumber currentStableLanguageVersion
        nonStablePaths =
          sort
            [ path
            | (path, observation) <- observations,
              sourceForm observation /= "declared"
                || sourceEffectiveVersion observation /= Just stableVersion
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
        `shouldSatisfy` (`elem` ["compatibility-proof", "migration-pending"])
      exceptionReason exception `shouldSatisfy` (not . T.null . T.strip)

  it "accounts for every compiled conformance component and stable generated banner" $ do
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
        `shouldSatisfy` (`elem` ["stable-primary", "compatibility-proof", "version-independent", "migration-pending"])
      suiteReason suite `shouldSatisfy` (not . T.null . T.strip)
      directory <- resolveRepoDirectory ("keiro-dsl" </> suiteDirectory suite)
      doesDirectoryExist directory `shouldReturn` True
      case suiteRole suite of
        "stable-primary" -> do
          source <- maybe (expectationFailure (T.unpack (suiteComponent suite <> " has no source")) >> fail "unreachable") pure (suiteSource suite)
          observation <- observeSource source
          sourceForm observation `shouldBe` "declared"
          sourceResult observation `shouldBe` "accept"
          sourceEffectiveVersion observation
            `shouldBe` Just (languageVersionNumber currentStableLanguageVersion)
          banners <- generatedBannerLines directory
          banners `shouldSatisfy` (not . null)
          forM_ banners $ \(path, banner) -> do
            let expected =
                  "language keiro-dsl "
                    <> T.pack (show (languageVersionNumber currentStableLanguageVersion))
            unless (expected `T.isInfixOf` banner) $
              expectationFailure (T.unpack (decorate path banner <> " (expected " <> expected <> ")"))
        _ -> pure ()

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
    contents <- readRepoText (root </> path)
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
      candidates = [path, packageRelative] <> maybe [] (\root -> [root </> path, root </> packageRelative]) override
  existing <- filterM doesFileExist candidates
  case existing of
    candidate : _ -> pure candidate
    [] -> fail ("unable to locate conformance baseline file " <> show path)

resolveRepoDirectory :: FilePath -> IO FilePath
resolveRepoDirectory path = do
  override <- lookupEnv "KEIRO_DSL_TEST_ROOT"
  let packageRelative = maybe path T.unpack (T.stripPrefix "keiro-dsl/" (T.pack path))
      candidates = [path, packageRelative] <> maybe [] (\root -> [root </> path, root </> packageRelative]) override
  existing <- filterM doesDirectoryExist candidates
  case existing of
    candidate : _ -> pure candidate
    [] -> fail ("unable to locate conformance directory " <> show path)

decorate :: FilePath -> Text -> Text
decorate path banner = T.pack path <> ": " <> banner
