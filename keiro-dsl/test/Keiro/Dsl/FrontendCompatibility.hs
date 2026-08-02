-- | The executable compatibility oracle for the released keiro-dsl-0.7.0.0
-- language frontend. The checked JSON is deliberately data, not an update mode:
-- a behavior change must produce a reviewed manifest diff.
module Keiro.Dsl.FrontendCompatibility
  ( SourceExpectation (..),
    WorkspaceExpectation (..),
    CompatibilityManifest (..),
    diagnosticGoldens,
    frontendCompatibilitySpec,
    observeSource,
    observeWorkspace,
    readCompatibilityManifest,
    readRepoText,
    releasedFrontendEntryPoints,
    sourceFixturePaths,
    workspaceFixturePaths,
  )
where

import Control.Monad (filterM, forM, forM_)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.List (sort)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.FrontendPublicApiProbe (apiProbe)
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser (parseSource)
import Keiro.Dsl.PrettyPrint (renderSource)
import Keiro.Dsl.SemanticContract (checkedSource)
import Keiro.Dsl.Validate (Diagnostic (..), Severity (..), renderDiagnostic, validateService)
import Keiro.Dsl.Workspace
import Numeric.Natural (Natural)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, takeExtension, (</>))
import Test.Hspec
import Text.Read (readMaybe)

data SourceExpectation = SourceExpectation
  { sourcePath :: !FilePath,
    sourceForm :: !Text,
    sourceDeclaredVersion :: !(Maybe Natural),
    sourceEffectiveVersion :: !(Maybe Natural),
    sourceResult :: !Text,
    sourceFailureClass :: !(Maybe Text),
    sourceDiagnosticCode :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance FromJSON SourceExpectation where
  parseJSON = withObject "SourceExpectation" $ \fields ->
    SourceExpectation
      <$> fields .: "path"
      <*> fields .: "sourceForm"
      <*> fields .:? "declaredVersion"
      <*> fields .:? "effectiveVersion"
      <*> fields .: "result"
      <*> fields .:? "failureClass"
      <*> fields .:? "diagnosticCode"

instance ToJSON SourceExpectation where
  toJSON row =
    object
      [ "path" .= sourcePath row,
        "sourceForm" .= sourceForm row,
        "declaredVersion" .= sourceDeclaredVersion row,
        "effectiveVersion" .= sourceEffectiveVersion row,
        "result" .= sourceResult row,
        "failureClass" .= sourceFailureClass row,
        "diagnosticCode" .= sourceDiagnosticCode row
      ]

data WorkspaceExpectation = WorkspaceExpectation
  { workspacePath :: !FilePath,
    workspaceResult :: !Text,
    workspaceFailureClass :: !(Maybe Text),
    workspaceDiagnosticCode :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance FromJSON WorkspaceExpectation where
  parseJSON = withObject "WorkspaceExpectation" $ \fields ->
    WorkspaceExpectation
      <$> fields .: "path"
      <*> fields .: "result"
      <*> fields .:? "failureClass"
      <*> fields .:? "diagnosticCode"

instance ToJSON WorkspaceExpectation where
  toJSON row =
    object
      [ "path" .= workspacePath row,
        "result" .= workspaceResult row,
        "failureClass" .= workspaceFailureClass row,
        "diagnosticCode" .= workspaceDiagnosticCode row
      ]

data CompatibilityManifest = CompatibilityManifest
  { manifestSchema :: !Text,
    manifestRelease :: !Text,
    manifestEntryPoints :: ![Text],
    manifestSources :: ![SourceExpectation],
    manifestWorkspaces :: ![WorkspaceExpectation]
  }
  deriving stock (Eq, Show)

instance FromJSON CompatibilityManifest where
  parseJSON = withObject "CompatibilityManifest" $ \fields ->
    CompatibilityManifest
      <$> fields .: "schema"
      <*> fields .: "release"
      <*> fields .: "entryPoints"
      <*> fields .: "sources"
      <*> fields .: "workspaces"

instance ToJSON CompatibilityManifest where
  toJSON manifest =
    object
      [ "schema" .= manifestSchema manifest,
        "release" .= manifestRelease manifest,
        "entryPoints" .= manifestEntryPoints manifest,
        "sources" .= manifestSources manifest,
        "workspaces" .= manifestWorkspaces manifest
      ]

frontendCompatibilitySpec :: SpecWith ()
frontendCompatibilitySpec = describe "frontend 0.7 compatibility" $ do
  it "decodes the released manifest and classifies every checked-in frontend fixture" $ do
    manifest <- readManifest
    manifestSchema manifest `shouldBe` "keiro-dsl/frontend-compatibility/1"
    manifestRelease manifest `shouldBe` "0.7.0.0"
    manifestEntryPoints manifest `shouldBe` releasedFrontendEntryPoints
    sources <- sourceFixturePaths
    workspaces <- workspaceFixturePaths
    map sourcePath (manifestSources manifest) `shouldBe` sources
    map workspacePath (manifestWorkspaces manifest) `shouldBe` workspaces

  it "preserves every source outcome, released contract, and accepted canonical round trip" $ do
    manifest <- readManifest
    forM_ (manifestSources manifest) $ \expected -> do
      actual <- observeSource (sourcePath expected)
      actual `shouldBe` expected
      whenAccepted expected $ do
        source <- readRepoText (sourcePath expected)
        case parseSource (sourcePath expected) source of
          Left failure -> expectationFailure (show failure)
          Right parsed -> case parseSource (sourcePath expected) (renderSource parsed) of
            Left failure -> expectationFailure (show failure)
            Right reparsed -> do
              parsedSpec reparsed `shouldBe` parsedSpec parsed
              effectiveLanguageVersion (parsedSourceLanguage reparsed)
                `shouldBe` effectiveLanguageVersion (parsedSourceLanguage parsed)
              sourceFormText (parsedSourceLanguage reparsed)
                `shouldBe` sourceFormText (parsedSourceLanguage parsed)

  it "preserves every workspace composition outcome and member-attribution code" $ do
    manifest <- readManifest
    forM_ (manifestWorkspaces manifest) $ \expected ->
      observeWorkspace (workspacePath expected) `shouldReturn` expected

  it "keeps direct parsing and representative one-member workspaces semantically identical" $ do
    let examples =
          [ ("legacy.keiro", "context parity\n"),
            ("v1.keiro", "language keiro-dsl 1\ncontext parity\n"),
            ("v2.keiro", "language keiro-dsl 2\ncontext parity\n"),
            ("v3.keiro", "language keiro-dsl 3\ncontext parity\n")
          ]
    forM_ examples $ \(path, source) -> case parseSource path source of
      Left failure -> expectationFailure (show failure)
      Right parsed -> do
        let workspace = oneMemberParsedWorkspace path parsed
        wsMergedSpec workspace `shouldBe` parsedSpec parsed
        checkWorkspace workspace `shouldBe` []

  it "renders curated source, grammar, semantic, and workspace failures byte-for-byte" $
    forM_ diagnosticGoldens $ \(name, renderActual) -> do
      expected <- readRepoText (diagnosticRoot </> name)
      actual <- renderActual
      actual `shouldBe` expected

  it "keeps the released parser, renderer, and representative selector signatures compiling" $
    apiProbe `shouldBe` ()

whenAccepted :: SourceExpectation -> IO () -> IO ()
whenAccepted row action
  | sourceResult row == "accept" = action
  | otherwise = pure ()

observeSource :: FilePath -> IO SourceExpectation
observeSource path = do
  source <- readRepoText path
  let (headerForm, headerVersion) = sourceHeader source
      base result failureClass diagnostic effective =
        SourceExpectation
          { sourcePath = path,
            sourceForm = headerForm,
            sourceDeclaredVersion = headerVersion,
            sourceEffectiveVersion = effective,
            sourceResult = result,
            sourceFailureClass = failureClass,
            sourceDiagnosticCode = diagnostic
          }
  pure $ case parseSource path source of
    Left (SourceLanguageFailure diagnostic) ->
      base
        "reject"
        (Just "source-language")
        (Just (sourceLanguageErrorCodeText (sourceLanguageErrorCode diagnostic)))
        (languageVersionNumber <$> sourceLanguageDeclaredVersion diagnostic)
    Left (BodyGrammarFailure _) ->
      base "reject" (Just "body-grammar") Nothing (supportedHeaderVersion headerVersion)
    Right parsed ->
      let sourceLanguage = parsedSourceLanguage parsed
          effective = Just (languageVersionNumber (effectiveLanguageVersion sourceLanguage))
          errors = filter ((== Error) . severity) (validateService (checkedSource parsed))
       in case errors of
            diagnostic : _ -> base "reject" (Just "semantic") (Just (T.pack (show (code diagnostic)))) effective
            [] -> base "accept" Nothing Nothing effective

observeWorkspace :: FilePath -> IO WorkspaceExpectation
observeWorkspace path = do
  resolved <- resolveRepoPath path
  loaded <- loadWorkspace (fileContentSource (takeDirectory resolved)) path
  pure $ case loaded of
    Left (WorkspaceManifestUnreadable _) -> rejected "manifest-unreadable" Nothing
    Left (WorkspaceManifestUnparseable _) -> rejected "manifest-grammar" Nothing
    Left (WorkspaceRefused diagnostics) ->
      rejected "composition" (Just (T.pack (show (wdCode (NE.head diagnostics)))))
    Right workspace -> case filter ((== Error) . wdSeverity) (checkWorkspace workspace) of
      diagnostic : _ -> rejected "semantic" (Just (T.pack (show (wdCode diagnostic))))
      [] -> WorkspaceExpectation path "accept" Nothing Nothing
  where
    rejected failureClass diagnostic = WorkspaceExpectation path "reject" (Just failureClass) diagnostic

sourceHeader :: Text -> (Text, Maybe Natural)
sourceHeader source = case firstSignificantLine source of
  Just lineText
    | Just token <- T.stripPrefix "language keiro-dsl " lineText ->
        ("declared", readMaybe (T.unpack (T.strip token)))
  _ -> ("legacy-unversioned", Nothing)

firstSignificantLine :: Text -> Maybe Text
firstSignificantLine =
  listToMaybe
    . filter (\lineText -> not (T.null lineText) && not ("#" `T.isPrefixOf` lineText))
    . map T.strip
    . T.lines

supportedHeaderVersion :: Maybe Natural -> Maybe Natural
supportedHeaderVersion raw = do
  number <- raw
  version <- languageVersion number
  _ <- lookupLanguageDefinition version
  pure number

readManifest :: IO CompatibilityManifest
readManifest = do
  path <- resolveRepoPath manifestPath
  decoded <- Aeson.eitherDecodeFileStrict' path
  case decoded of
    Left problem -> expectationFailure problem >> fail "invalid frontend compatibility manifest"
    Right manifest -> pure manifest

readCompatibilityManifest :: IO CompatibilityManifest
readCompatibilityManifest = readManifest

sourceFixturePaths :: IO [FilePath]
sourceFixturePaths = fixturePaths ".keiro"

workspaceFixturePaths :: IO [FilePath]
workspaceFixturePaths = fixturePaths ".keiro-workspace"

fixturePaths :: String -> IO [FilePath]
fixturePaths extension = do
  fixtureRoot <- resolveRepoDirectory "keiro-dsl/test/fixtures"
  relative <- walk fixtureRoot ""
  pure . sort $ ["keiro-dsl/test/fixtures" </> path | path <- relative, takeExtension path == extension]
  where
    walk root relative = do
      entries <- sort <$> listDirectory (root </> relative)
      fmap concat . forM entries $ \entry -> do
        let child = if null relative then entry else relative </> entry
        isDirectory <- doesDirectoryExist (root </> child)
        if isDirectory then walk root child else pure [child]

readRepoText :: FilePath -> IO Text
readRepoText path = resolveRepoPath path >>= TIO.readFile

resolveRepoPath :: FilePath -> IO FilePath
resolveRepoPath path = do
  override <- lookupEnv "KEIRO_DSL_TEST_ROOT"
  let packageRelative = maybe path id (T.unpack <$> T.stripPrefix "keiro-dsl/" (T.pack path))
      candidates = [path, packageRelative] <> maybe [] (\root -> [root </> path, root </> packageRelative]) override
  existing <- filterM doesFileExist candidates
  case existing of
    candidate : _ -> pure candidate
    [] -> fail ("unable to locate repository file " <> show path <> "; tried " <> show candidates)

resolveRepoDirectory :: FilePath -> IO FilePath
resolveRepoDirectory path = do
  override <- lookupEnv "KEIRO_DSL_TEST_ROOT"
  let packageRelative = maybe path id (T.unpack <$> T.stripPrefix "keiro-dsl/" (T.pack path))
      candidates = [path, packageRelative] <> maybe [] (\root -> [root </> path, root </> packageRelative]) override
  existing <- filterM doesDirectoryExist candidates
  case existing of
    candidate : _ -> pure candidate
    [] -> fail ("unable to locate repository directory " <> show path <> "; tried " <> show candidates)

manifestPath :: FilePath
manifestPath = "keiro-dsl/test/frontend-0.7/manifest.json"

diagnosticRoot :: FilePath
diagnosticRoot = "keiro-dsl/test/frontend-0.7/diagnostics"

releasedFrontendEntryPoints :: [Text]
releasedFrontendEntryPoints =
  [ "library.parseSource",
    "library.parseSpec",
    "library.parseSpecText",
    "workspace.parseWorkspaceManifest",
    "workspace.loadWorkspace.members",
    "cli.parse.single",
    "cli.parse.workspace-manifest",
    "cli.check.single",
    "cli.check.workspace",
    "cli.inspect.single",
    "cli.inspect.workspace",
    "cli.behavior-obligations.single",
    "cli.behavior-obligations.workspace",
    "cli.scaffold.single",
    "cli.scaffold.workspace",
    "cli.diff.single-working-tree-and-git-baseline",
    "cli.diff.workspace-working-tree-and-git-baseline"
  ]

diagnosticGoldens :: [(FilePath, IO Text)]
diagnosticGoldens =
  [ ("invalid-preamble.txt", renderParse "invalid-preamble.keiro" "language keiro-dsl nope\ncontext source-fixture\n"),
    ("misplaced-preamble.txt", renderParse "misplaced-preamble.keiro" "context source-fixture\nlanguage keiro-dsl 1\n"),
    ("duplicate-preamble.txt", renderParse "duplicate-preamble.keiro" "language keiro-dsl 1\nlanguage keiro-dsl 1\ncontext source-fixture\n"),
    ("feature-nominal-binding-v1.txt", renderParse "feature-nominal-binding-v1.keiro" "context feature\nid OrderId prefix=ord using {}\n"),
    ("feature-integer-v1.txt", renderParse "feature-integer-v1.keiro" integerFeatureSource),
    ("feature-typed-expression-v1.txt", renderParse "feature-typed-expression-v1.keiro" typedExpressionFeatureSource),
    ("feature-explicit-implementation-v1.txt", renderParse "feature-explicit-implementation-v1.keiro" explicitImplementationFeatureSource),
    ("escaped-string.txt", renderParse "escaped-string.keiro" escapedStringSource),
    ("numeric-overflow.txt", renderParse "numeric-overflow.keiro" numericOverflowSource),
    ("duplicate-clause.txt", renderParse "duplicate-clause.keiro" duplicateClauseSource),
    ("expression-error.txt", renderParse "expression-error.keiro" expressionErrorSource),
    ("semantic-error.txt", renderSemantic "semantic-error.keiro" semanticErrorSource),
    ("workspace-member-parse-failure.txt", renderWorkspaceMemberFailure)
  ]

renderParse :: FilePath -> Text -> IO Text
renderParse path source = pure $ case parseSource path source of
  Left failure -> T.stripEnd (renderParseFailure failure) <> "\n"
  Right _ -> error ("diagnostic source unexpectedly parsed: " <> path)

renderSemantic :: FilePath -> Text -> IO Text
renderSemantic path source = pure $ case parseSource path source of
  Left failure -> error ("semantic diagnostic source failed to parse: " <> show failure)
  Right parsed -> case filter ((== Error) . severity) (validateService (checkedSource parsed)) of
    diagnostic : _ -> renderDiagnostic path diagnostic <> "\n"
    [] -> error ("semantic diagnostic source unexpectedly validated: " <> path)

renderWorkspaceMemberFailure :: IO Text
renderWorkspaceMemberFailure = do
  let path = "keiro-dsl/test/fixtures/workspace-member-parse-failed/service.keiro-workspace"
  resolved <- resolveRepoPath path
  loaded <- loadWorkspace (fileContentSource (takeDirectory resolved)) path
  pure $ case loaded of
    Left failure -> T.stripEnd (T.unlines (renderWorkspaceFailure path failure)) <> "\n"
    Right _ -> error "workspace-member-parse-failed unexpectedly composed"

integerFeatureSource :: Text
integerFeatureSource =
  T.unlines
    [ "context feature",
      "aggregate Counter",
      "  regs",
      "    value Integer = 0",
      "  states Open"
    ]

typedExpressionFeatureSource :: Text
typedExpressionFeatureSource =
  T.unlines
    [ "context feature",
      "aggregate Counter",
      "  regs",
      "    value Int = 0",
      "  states Open",
      "  command Tick { amount:Int }",
      "  Open -- Tick -->",
      "    guard reg.value == cmd.amount",
      "    goto Open"
    ]

explicitImplementationFeatureSource :: Text
explicitImplementationFeatureSource =
  T.unlines
    [ "context feature",
      "aggregate Counter",
      "  regs",
      "  states Open",
      "  command Tick { }",
      "  Open -- Tick -->",
      "    implementation hole",
      "    goto Open"
    ]

escapedStringSource :: Text
escapedStringSource =
  "context svc\n\ncontract c {\n  schemaVersion 1\n  discriminator kind\n  topic events \"bad\\q\"\n}\n"

numericOverflowSource :: Text
numericOverflowSource =
  T.unlines
    [ "context svc",
      "aggregate Thing",
      "  regs",
      "  states Open",
      "  event Changed v18446744073709551617 { }"
    ]

duplicateClauseSource :: Text
duplicateClauseSource =
  T.unlines
    [ "context svc",
      "aggregate Thing",
      "  regs",
      "  states Open Closed",
      "  command Move { }",
      "  Open -- Move -->",
      "    goto Closed",
      "    goto Open"
    ]

expressionErrorSource :: Text
expressionErrorSource =
  T.unlines
    [ "language keiro-dsl 2",
      "context svc",
      "aggregate Thing",
      "  regs",
      "    value Int = 0",
      "  states Open",
      "  command Move { amount:Int }",
      "  Open -- Move -->",
      "    guard cmd.amount +",
      "    goto Open"
    ]

semanticErrorSource :: Text
semanticErrorSource =
  T.unlines
    [ "context svc",
      "aggregate Thing",
      "  regs",
      "  states Open",
      "  Open -- MissingCommand -->",
      "    goto Open"
    ]
