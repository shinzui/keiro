module CorpusPlan
  ( CorpusEntry (..),
    checkCabalInventory,
    checkRecordDiskConsistency,
    entryOutDir,
    loadCorpusPlan,
    renderInvocation,
  )
where

import Control.Monad (filterM, forM)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum, isUpper)
import Data.Either (partitionEithers)
import Data.List (isPrefixOf, isSuffixOf, nub, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Distribution.ModuleName qualified as CabalModule
import Distribution.PackageDescription.Parsec (parseGenericPackageDescriptionMaybe)
import Distribution.Types.Benchmark qualified as CabalBenchmark
import Distribution.Types.BenchmarkInterface qualified as CabalBenchmarkInterface
import Distribution.Types.BuildInfo qualified as CabalBuildInfo
import Distribution.Types.CondTree (condTreeData)
import Distribution.Types.Executable qualified as CabalExecutable
import Distribution.Types.GenericPackageDescription qualified as CabalGpd
import Distribution.Types.TestSuite qualified as CabalTestSuite
import Distribution.Types.TestSuiteInterface qualified as CabalTestSuiteInterface
import Distribution.Types.UnqualComponentName (unUnqualComponentName)
import Distribution.Utils.Path (getSymbolicPath)
import Keiro.Dsl.ConformancePackage (ConformancePackageRecord (..), conformanceRecordFileName, parseConformancePackageRecord)
import Keiro.Dsl.Scaffold (ModuleKind (..), codecComparisonBanner, isGeneratedBannerLine)
import Keiro.Dsl.ScaffoldRecord (ScaffoldRecord (..), parseRecord)
import Keiro.Dsl.WorkspaceRecord (WorkspaceModuleRow (..), WorkspaceRecord (..), parseWorkspaceRecord)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (addTrailingPathSeparator, isAbsolute, makeRelative, normalise, splitDirectories, takeDirectory, takeExtension, takeFileName, (<.>), (</>))
import System.Process (readProcessWithExitCode)

data CorpusEntry
  = SingleSpec
      { ceSpecPath :: FilePath,
        ceOutDir :: FilePath,
        ceModuleRoot :: Maybe Text,
        ceCollocate :: Bool,
        ceExtraArgs :: [Text]
      }
  | WorkspaceSpec
      { ceManifestPath :: FilePath,
        ceOutDir :: FilePath
      }
  | SkeletonRun
      { ceKind :: Text,
        ceRoot :: Text,
        ceOutDir :: FilePath
      }
  deriving stock (Eq, Show)

entryOutDir :: CorpusEntry -> FilePath
entryOutDir = ceOutDir

renderInvocation :: CorpusEntry -> [String]
renderInvocation SingleSpec {ceSpecPath, ceOutDir, ceModuleRoot, ceCollocate, ceExtraArgs} =
  ["scaffold", ceSpecPath, "--out", ceOutDir]
    <> maybe [] (\root -> ["--module-root", T.unpack root]) ceModuleRoot
    <> ["--collocate" | ceCollocate]
    <> map T.unpack ceExtraArgs
renderInvocation WorkspaceSpec {ceManifestPath, ceOutDir} =
  ["scaffold", ceManifestPath, "--out", ceOutDir]
renderInvocation SkeletonRun {ceRoot, ceOutDir} =
  ["scaffold", "/dev/stdin", "--out", ceOutDir, "--module-root", T.unpack ceRoot]

data Supplement = Supplement
  { supWorkspaces :: [(FilePath, FilePath)],
    supSkeletons :: [(Text, Text, FilePath)],
    supExtraArgs :: [(FilePath, [Text])],
    supExemptions :: [FilePath],
    supLegacyGenerated :: [FilePath]
  }
  deriving stock (Eq, Show)

data RecordHistory
  = SingleHistory FilePath ScaffoldRecord
  | WorkspaceHistory FilePath WorkspaceRecord

loadCorpusPlan :: FilePath -> IO (Either [Text] ([CorpusEntry], [FilePath]))
loadCorpusPlan repoRoot = do
  supplementResult <- loadSupplement (repoRoot </> manifestPath)
  historiesResult <- loadTrackedHistories repoRoot
  pure $ do
    supplement <- supplementResult
    histories <- historiesResult
    buildPlan repoRoot supplement histories

manifestPath :: FilePath
manifestPath = "keiro-dsl/test/conformance-corpus-manifest.txt"

loadSupplement :: FilePath -> IO (Either [Text] Supplement)
loadSupplement path = do
  contents <- TIO.readFile path
  pure (parseSupplement path contents)

parseSupplement :: FilePath -> Text -> Either [Text] Supplement
parseSupplement path contents =
  case meaningfulLines of
    [] -> Left [label <> " is empty"]
    (_, header) : rows
      | header /= "keiro-dsl conformance corpus manifest v1" ->
          Left [label <> " has an unsupported header: " <> header]
      | otherwise ->
          let (rowErrors, parsedRows) = partitionEithers (map parseRow rows)
              supplement = foldr addRow emptySupplement parsedRows
              duplicateErrors = validateSupplement supplement
           in if null rowErrors && null duplicateErrors
                then Right supplement
                else Left (rowErrors <> duplicateErrors)
  where
    label = T.pack path
    meaningfulLines =
      [ (lineNumber, T.strip line)
      | (lineNumber, line) <- zip [1 :: Int ..] (T.lines contents),
        let stripped = T.strip line,
        not (T.null stripped),
        not ("#" `T.isPrefixOf` stripped)
      ]
    parseRow (lineNumber, row) =
      let failure message = Left (label <> ":" <> T.pack (show lineNumber) <> ": " <> message)
          checked paths value =
            case filter (not . safeRelativePath) paths of
              [] -> Right value
              unsafe : _ -> failure ("unsafe repository-relative path: " <> T.pack unsafe)
       in case T.words row of
            ["workspace", manifest, outDir] ->
              checked [T.unpack manifest, T.unpack outDir] (WorkspaceRow (T.unpack manifest) (T.unpack outDir))
            ["skeleton", kind, root, outDir] ->
              checked [T.unpack outDir] (SkeletonRow kind root (T.unpack outDir))
            "extra-args" : outDir : args
              | not (null args) ->
                  checked [T.unpack outDir] (ExtraArgsRow (T.unpack outDir) args)
            ["uncompiled-generated", modulePath] ->
              checked [T.unpack modulePath] (ExemptionRow (T.unpack modulePath))
            ["legacy-generated", modulePath] ->
              checked [T.unpack modulePath] (LegacyGeneratedRow (T.unpack modulePath))
            _ -> failure ("invalid manifest row: " <> row)

data SupplementRow
  = WorkspaceRow FilePath FilePath
  | SkeletonRow Text Text FilePath
  | ExtraArgsRow FilePath [Text]
  | ExemptionRow FilePath
  | LegacyGeneratedRow FilePath

emptySupplement :: Supplement
emptySupplement = Supplement [] [] [] [] []

addRow :: SupplementRow -> Supplement -> Supplement
addRow row supplement = case row of
  WorkspaceRow manifest outDir -> supplement {supWorkspaces = (manifest, outDir) : supWorkspaces supplement}
  SkeletonRow kind root outDir -> supplement {supSkeletons = (kind, root, outDir) : supSkeletons supplement}
  ExtraArgsRow outDir args -> supplement {supExtraArgs = (outDir, args) : supExtraArgs supplement}
  ExemptionRow path -> supplement {supExemptions = path : supExemptions supplement}
  LegacyGeneratedRow path -> supplement {supLegacyGenerated = path : supLegacyGenerated supplement}

validateSupplement :: Supplement -> [Text]
validateSupplement supplement =
  duplicateMessages "workspace out-dir" (map snd (supWorkspaces supplement))
    <> duplicateMessages "extra-args out-dir" (map fst (supExtraArgs supplement))
    <> duplicateMessages "uncompiled-generated path" (supExemptions supplement)
    <> duplicateMessages "legacy-generated path" (supLegacyGenerated supplement)
  where
    duplicateMessages label values =
      [ "duplicate " <> label <> " in corpus manifest: " <> T.pack value
      | value <- duplicates values
      ]

loadTrackedHistories :: FilePath -> IO (Either [Text] [RecordHistory])
loadTrackedHistories repoRoot = do
  trackedResult <- trackedTestPaths repoRoot
  case trackedResult of
    Left errors -> pure (Left errors)
    Right trackedPaths -> do
      let recordPaths = filter isRecordPath trackedPaths
      loaded <- traverse (loadHistory repoRoot) recordPaths
      let (errors, histories) = partitionEithers loaded
      pure $ if null errors then Right histories else Left (concat errors)

trackedTestPaths :: FilePath -> IO (Either [Text] [FilePath])
trackedTestPaths repoRoot = do
  (exitCode, stdoutText, stderrText) <-
    readProcessWithExitCode "git" ["-C", repoRoot, "ls-files", "keiro-dsl/test"] ""
  case exitCode of
    ExitFailure _ -> pure (Left ["git ls-files failed: " <> T.pack (trim stderrText)])
    ExitSuccess -> pure (Right (lines stdoutText))

isRecordPath :: FilePath -> Bool
isRecordPath path =
  let name = takeFileName path
   in ("keiro-dsl-ledger." `isPrefixOf` name || "keiro-dsl-scaffold-record." `isPrefixOf` name)
        && ".txt" `isSuffixOf` name

loadHistory :: FilePath -> FilePath -> IO (Either [Text] RecordHistory)
loadHistory repoRoot recordPath = do
  contents <- TIO.readFile (repoRoot </> recordPath)
  pure $ case (parseRecord contents, parseWorkspaceRecord contents) of
    (Just record, Nothing) -> Right (SingleHistory recordPath record)
    (Nothing, Just record) -> Right (WorkspaceHistory recordPath record)
    (Nothing, Nothing) -> Left [T.pack recordPath <> ": record does not parse"]
    (Just _, Just _) -> Left [T.pack recordPath <> ": record ambiguously matches both formats"]

buildPlan :: FilePath -> Supplement -> [RecordHistory] -> Either [Text] ([CorpusEntry], [FilePath])
buildPlan repoRoot supplement histories =
  if null errors
    then Right (orderedEntries, supExemptions supplement)
    else Left errors
  where
    extraArgs = Map.fromList (supExtraArgs supplement)
    workspaceRows = Map.fromList [(outDir, manifest) | (manifest, outDir) <- supWorkspaces supplement]
    singleRecords = [(recordOutDir repoRoot path, record) | SingleHistory path record <- histories]
    workspaceRecords = [recordOutDir repoRoot path | WorkspaceHistory path _ <- histories]
    stdinDirs = Set.fromList [outDir | (outDir, record) <- singleRecords, recSpecPath record == "/dev/stdin"]
    ordinaryRecords = [(outDir, record) | (outDir, record) <- singleRecords, recSpecPath record /= "/dev/stdin"]
    ordinaryDirs = Set.fromList (map fst ordinaryRecords)
    workspaceDirs = Set.fromList workspaceRecords
    skeletonDirs = Set.fromList [outDir | (_, _, outDir) <- supSkeletons supplement]
    singleEntries = map makeSingle ordinaryRecords
    workspaceEntries =
      [ WorkspaceSpec manifest outDir
      | outDir <- workspaceRecords,
        Just manifest <- [Map.lookup outDir workspaceRows]
      ]
    skeletonEntries = [SkeletonRun kind root outDir | (kind, root, outDir) <- supSkeletons supplement]
    orderedEntries = sortOn entryOutDir (singleEntries <> workspaceEntries) <> skeletonEntries
    errors =
      ["no tracked scaffold records were found under keiro-dsl/test" | null histories]
        <> duplicateHistoryErrors
        <> unclaimedStdinErrors
        <> unclaimedSkeletonErrors
        <> unclaimedWorkspaceRecordErrors
        <> unclaimedWorkspaceRowErrors
        <> unclaimedExtraArgsErrors
        <> unsafeInputErrors
    duplicateHistoryErrors =
      [ "multiple tracked scaffold records claim output directory " <> T.pack outDir
      | outDir <- duplicates (map (historyOutDir repoRoot) histories)
      ]
    unclaimedStdinErrors =
      [ "stdin scaffold record has no skeleton rows: " <> T.pack outDir
      | outDir <- Set.toList (stdinDirs `Set.difference` skeletonDirs)
      ]
    unclaimedSkeletonErrors =
      [ "skeleton rows have no stdin scaffold record: " <> T.pack outDir
      | outDir <- Set.toList (skeletonDirs `Set.difference` stdinDirs)
      ]
    unclaimedWorkspaceRecordErrors =
      [ "workspace scaffold record has no workspace manifest row: " <> T.pack outDir
      | outDir <- Set.toList (workspaceDirs `Set.difference` Map.keysSet workspaceRows)
      ]
    unclaimedWorkspaceRowErrors =
      [ "workspace manifest row has no tracked workspace record: " <> T.pack outDir
      | outDir <- Set.toList (Map.keysSet workspaceRows `Set.difference` workspaceDirs)
      ]
    unclaimedExtraArgsErrors =
      [ "extra-args row has no ordinary single-spec record: " <> T.pack outDir
      | outDir <- Set.toList (Map.keysSet extraArgs `Set.difference` ordinaryDirs)
      ]
    unsafeInputErrors =
      [ "corpus input is not a safe repository-relative path: " <> T.pack input
      | input <- map ceSpecPath singleEntries <> map ceManifestPath workspaceEntries,
        not (safeRelativePath input)
      ]
    makeSingle (outDir, record) =
      SingleSpec
        { ceSpecPath = T.unpack (recSpecPath record),
          ceOutDir = outDir,
          ceModuleRoot = nonEmpty (recModuleRoot record),
          ceCollocate = recLayout record == "collocated",
          ceExtraArgs = Map.findWithDefault [] outDir extraArgs
        }

recordOutDir :: FilePath -> FilePath -> FilePath
recordOutDir repoRoot recordPath = makeRelative repoRoot (takeDirectory (repoRoot </> recordPath))

historyOutDir :: FilePath -> RecordHistory -> FilePath
historyOutDir repoRoot history = case history of
  SingleHistory path _ -> recordOutDir repoRoot path
  WorkspaceHistory path _ -> recordOutDir repoRoot path

data RecordView = RecordView
  { rvRecordPath :: FilePath,
    rvFiles :: [(ModuleKind, FilePath)]
  }

checkRecordDiskConsistency :: FilePath -> [CorpusEntry] -> IO [Text]
checkRecordDiskConsistency repoRoot entries = do
  historiesResult <- loadTrackedHistories repoRoot
  conformanceResult <- loadConformanceRecordViews repoRoot
  supplementResult <- loadSupplement (repoRoot </> manifestPath)
  case (historiesResult, conformanceResult, supplementResult) of
    (Left errors, _, _) -> pure errors
    (_, Left errors, _) -> pure errors
    (_, _, Left errors) -> pure errors
    (Right histories, Right conformanceViews, Right supplement) -> do
      let views = map historyRecordView histories <> conformanceViews
          recordedFiles =
            [ (kind, normalise (takeDirectory (rvRecordPath view) </> path), rvRecordPath view)
            | view <- views,
              (kind, path) <- rvFiles view
            ]
      missing <-
        filterM
          (\(_, path, _) -> not <$> doesFileExist (repoRoot </> path))
          recordedFiles
      generatedOnDisk <- discoverGeneratedHaskell repoRoot entries
      let recordedGenerated = Set.fromList [path | (Generated, path, _) <- recordedFiles]
          comparisonOutputs = Set.fromList (comparisonOutputPaths entries)
          skeletonClaims =
            [ normalise (ceOutDir </> moduleRootPath ceRoot)
            | SkeletonRun {ceRoot, ceOutDir} <- entries
            ]
          manifestClaimed =
            Set.fromList
              [ path
              | path <- generatedOnDisk,
                any (`pathWithin` path) skeletonClaims
              ]
          legacyGenerated = Set.fromList (supLegacyGenerated supplement)
          generatedSet = Set.fromList generatedOnDisk
          unrecorded =
            Set.toList
              ( generatedSet
                  `Set.difference` recordedGenerated
                  `Set.difference` comparisonOutputs
                  `Set.difference` manifestClaimed
                  `Set.difference` legacyGenerated
              )
          unknownLegacy = Set.toList (legacyGenerated `Set.difference` generatedSet)
          staleLegacy = Set.toList (legacyGenerated `Set.intersection` recordedGenerated)
      pure $
        [ T.pack recordPath <> ": recorded file is missing: " <> T.pack path
        | (_, path, recordPath) <- missing
        ]
          <> ["generated Haskell file is absent from scaffold history: " <> T.pack path | path <- sort unrecorded]
          <> ["legacy-generated path is not a generated Haskell file in the corpus: " <> T.pack path | path <- sort unknownLegacy]
          <> ["legacy-generated path is stale because scaffold history now records it: " <> T.pack path | path <- sort staleLegacy]

historyRecordView :: RecordHistory -> RecordView
historyRecordView history = case history of
  SingleHistory path record ->
    RecordView path (recFiles record)
  WorkspaceHistory path record ->
    RecordView path [(wrmKind row, wrmPath row) | row <- wrModules record]

loadConformanceRecordViews :: FilePath -> IO (Either [Text] [RecordView])
loadConformanceRecordViews repoRoot = do
  trackedResult <- trackedTestPaths repoRoot
  case trackedResult of
    Left errors -> pure (Left errors)
    Right paths -> do
      let recordPaths = [path | path <- paths, takeFileName path == conformanceRecordFileName]
      loaded <- traverse loadOne recordPaths
      let (errors, views) = partitionEithers loaded
      pure $ if null errors then Right views else Left errors
  where
    loadOne path = do
      contents <- TIO.readFile (repoRoot </> path)
      pure $ case parseConformancePackageRecord contents of
        Nothing -> Left (T.pack path <> ": conformance package record does not parse")
        Just record -> Right (RecordView path (cprFiles record))

comparisonOutputPaths :: [CorpusEntry] -> [FilePath]
comparisonOutputPaths entries =
  [ path
  | SingleSpec {ceExtraArgs} <- entries,
    path <- comparisonPaths (map T.unpack ceExtraArgs)
  ]
  where
    comparisonPaths ("--comparison-out" : path : rest) = path : comparisonPaths rest
    comparisonPaths (_ : rest) = comparisonPaths rest
    comparisonPaths [] = []

discoverGeneratedHaskell :: FilePath -> [CorpusEntry] -> IO [FilePath]
discoverGeneratedHaskell repoRoot entries = do
  files <- concat <$> traverse (listFilesRecursively . (repoRoot </>)) corpusRoots
  filterM carriesGeneratedBanner (map (makeRelative repoRoot) files)
  where
    corpusRoots = sort (nub (map entryOutDir entries))
    carriesGeneratedBanner path
      | takeExtension path /= ".hs" = pure False
      | otherwise = do
          contents <- TIO.readFile (repoRoot </> path)
          pure (any isRecognizedGeneratedBanner (T.lines contents))
    isRecognizedGeneratedBanner line = isGeneratedBannerLine line || line == codecComparisonBanner

listFilesRecursively :: FilePath -> IO [FilePath]
listFilesRecursively root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      children <- sort <$> listDirectory root
      concat <$> traverse visit children
  where
    visit name = do
      let path = root </> name
      directory <- doesDirectoryExist path
      if directory then listFilesRecursively path else pure [path]

data CabalComponent = CabalComponent
  { ccName :: Text,
    ccSourceDirs :: [FilePath],
    ccOtherModules :: [CabalModule.ModuleName],
    ccAutogenModules :: Set.Set CabalModule.ModuleName,
    ccMainFiles :: [FilePath]
  }

checkCabalInventory :: FilePath -> [CorpusEntry] -> [FilePath] -> IO [Text]
checkCabalInventory repoRoot entries exemptions = do
  packageBytes <- BS.readFile cabalPath
  case parseGenericPackageDescriptionMaybe packageBytes of
    Nothing -> pure [T.pack cabalPath <> ": Cabal-syntax could not parse the package"]
    Just description -> do
      let allComponents = cabalComponents description
          corpusRoots = sort (nub (map entryOutDir entries))
          relevantComponents = filter (componentIntersects corpusRoots) allComponents
          relevantSourceDirs = sort (nub (concatMap ccSourceDirs relevantComponents))
      resolved <- traverse (resolveComponentModules repoRoot) relevantComponents
      generatedOnDisk <- discoverGeneratedHaskell repoRoot entries
      let danglingErrors = concatMap fst resolved
          compiledPaths = Set.fromList (concatMap snd resolved)
          generatedInScope =
            Set.fromList
              [ path
              | path <- generatedOnDisk,
                any (`pathWithin` path) relevantSourceDirs,
                not (servicePackageRoot `pathWithin` path)
              ]
          exemptionSet = Set.fromList exemptions
          uncovered = Set.toList (generatedInScope `Set.difference` compiledPaths `Set.difference` exemptionSet)
          unknownExemptions = Set.toList (exemptionSet `Set.difference` generatedInScope)
          staleExemptions = Set.toList (exemptionSet `Set.intersection` compiledPaths)
      pure $
        danglingErrors
          <> ["generated module is compiled by no corpus component and is not exempted: " <> T.pack path | path <- sort uncovered]
          <> ["uncompiled-generated exemption is outside the checked generated corpus: " <> T.pack path | path <- sort unknownExemptions]
          <> ["uncompiled-generated exemption is stale because the module is now compiled: " <> T.pack path | path <- sort staleExemptions]
  where
    cabalPath = repoRoot </> "keiro-dsl/keiro-dsl.cabal"
    servicePackageRoot = "keiro-dsl/test/conformance-service-package"

cabalComponents :: CabalGpd.GenericPackageDescription -> [CabalComponent]
cabalComponents description =
  [ let test = condTreeData tree
     in fromBuildInfo ("test:" <> componentName name) (CabalTestSuite.testBuildInfo test) (testMainFiles test)
  | (name, tree) <- CabalGpd.condTestSuites description
  ]
    <> [ let benchmark = condTreeData tree
          in fromBuildInfo ("benchmark:" <> componentName name) (CabalBenchmark.benchmarkBuildInfo benchmark) (benchmarkMainFiles benchmark)
       | (name, tree) <- CabalGpd.condBenchmarks description
       ]
    <> [ let executable = condTreeData tree
          in fromBuildInfo ("executable:" <> componentName name) (CabalExecutable.buildInfo executable) [getSymbolicPath (CabalExecutable.modulePath executable)]
       | (name, tree) <- CabalGpd.condExecutables description
       ]
  where
    componentName = T.pack . unUnqualComponentName
    fromBuildInfo name buildInfo mainFiles =
      CabalComponent
        { ccName = name,
          ccSourceDirs = [normalise ("keiro-dsl" </> getSymbolicPath path) | path <- CabalBuildInfo.hsSourceDirs buildInfo],
          ccOtherModules = CabalBuildInfo.otherModules buildInfo,
          ccAutogenModules = Set.fromList (CabalBuildInfo.autogenModules buildInfo),
          ccMainFiles = mainFiles
        }
    testMainFiles test = case CabalTestSuite.testInterface test of
      CabalTestSuiteInterface.TestSuiteExeV10 _ path -> [getSymbolicPath path]
      _ -> []
    benchmarkMainFiles benchmark = case CabalBenchmark.benchmarkInterface benchmark of
      CabalBenchmarkInterface.BenchmarkExeV10 _ path -> [getSymbolicPath path]
      _ -> []

componentIntersects :: [FilePath] -> CabalComponent -> Bool
componentIntersects corpusRoots component =
  or
    [ corpusRoot `pathWithin` sourceDir || sourceDir `pathWithin` corpusRoot
    | corpusRoot <- corpusRoots,
      sourceDir <- ccSourceDirs component
    ]

resolveComponentModules :: FilePath -> CabalComponent -> IO ([Text], [FilePath])
resolveComponentModules repoRoot component = do
  resolved <- forM (ccOtherModules component) $ \moduleName ->
    if moduleName `Set.member` ccAutogenModules component
      then pure (Right [])
      else do
        existing <- resolveModulePath repoRoot component (CabalModule.toFilePath moduleName)
        pure $ case existing of
          [] -> Left (ccName component <> ": other-modules entry has no file: " <> T.pack (CabalModule.toFilePath moduleName))
          paths -> Right paths
  resolvedMains <- forM (ccMainFiles component) $ \mainFile -> do
    existing <- resolveSourcePath repoRoot component mainFile
    pure $ case existing of
      [] -> Left (ccName component <> ": main-is entry has no file: " <> T.pack mainFile)
      paths -> Right paths
  let (errors, declaredPaths) = partitionEithers resolved
      (mainErrors, mainPaths) = partitionEithers resolvedMains
  compiledPaths <- discoverCompiledSources repoRoot component (concat declaredPaths <> concat mainPaths)
  pure (errors <> mainErrors, compiledPaths)

discoverCompiledSources :: FilePath -> CabalComponent -> [FilePath] -> IO [FilePath]
discoverCompiledSources repoRoot component = go Set.empty
  where
    go visited [] = pure (Set.toList visited)
    go visited (path : rest)
      | path `Set.member` visited = go visited rest
      | otherwise = do
          contents <- TIO.readFile (repoRoot </> path)
          imported <- concat <$> traverse (resolveModulePath repoRoot component . moduleNamePath) (importsFrom contents)
          go (Set.insert path visited) (imported <> rest)

resolveModulePath :: FilePath -> CabalComponent -> FilePath -> IO [FilePath]
resolveModulePath repoRoot component relative =
  filterM
    (doesFileExist . (repoRoot </>))
    [ normalise (sourceDir </> relative <.> extension)
    | sourceDir <- ccSourceDirs component,
      extension <- ["hs", "lhs"]
    ]

resolveSourcePath :: FilePath -> CabalComponent -> FilePath -> IO [FilePath]
resolveSourcePath repoRoot component relative =
  filterM
    (doesFileExist . (repoRoot </>))
    [normalise (sourceDir </> relative) | sourceDir <- ccSourceDirs component]

importsFrom :: Text -> [Text]
importsFrom = mapMaybe importedModule . T.lines
  where
    importedModule line = case T.words (T.strip line) of
      "import" : tokens ->
        listToMaybe
          [ token
          | raw <- tokens,
            let token = T.takeWhile validModuleCharacter raw,
            not (T.null token),
            isUpper (T.head token),
            token /= "SOURCE"
          ]
      _ -> Nothing
    validModuleCharacter character = isAlphaNum character || character `elem` ['_', '.', '\'']

moduleNamePath :: Text -> FilePath
moduleNamePath = T.unpack . T.replace "." "/"

pathWithin :: FilePath -> FilePath -> Bool
pathWithin parent child =
  let parent' = normalise parent
      child' = normalise child
   in parent' == child' || addTrailingPathSeparator parent' `isPrefixOf` child'

safeRelativePath :: FilePath -> Bool
safeRelativePath path =
  not (null path)
    && not (isAbsolute path)
    && ".." `notElem` splitDirectories path

moduleRootPath :: Text -> FilePath
moduleRootPath = foldr (</>) "" . map T.unpack . T.splitOn "."

nonEmpty :: Text -> Maybe Text
nonEmpty value
  | T.null value = Nothing
  | otherwise = Just value

duplicates :: (Ord a) => [a] -> [a]
duplicates values =
  Map.keys (Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(value, 1 :: Int) | value <- values]))

trim :: String -> String
trim = reverse . dropWhile (`elem` ['\n', '\r', ' ', '\t']) . reverse
