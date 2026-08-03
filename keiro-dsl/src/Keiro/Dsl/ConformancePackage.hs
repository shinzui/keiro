-- | Planning and safe filesystem execution for the one runnable conformance
-- package generated per checked service.
module Keiro.Dsl.ConformancePackage
  ( ConformanceServiceKey (..),
    ConformanceFile (..),
    ConformancePackagePlan (..),
    ConformancePackageFailure (..),
    ConformancePackageRecord (..),
    ConformanceFactSide (..),
    DuplicateFactKey (..),
    ConformanceFactResult (..),
    ConformanceWriteDisposition (..),
    ConformanceStaleFile (..),
    PreparedConformancePackage,
    ConformancePackageReport (..),
    cabaliseConformanceService,
    conformancePackageDirectory,
    conformanceRecordFileName,
    planConformancePackage,
    parseConformancePackageRecord,
    renderConformancePackageRecord,
    preflightConformancePackage,
    executePreparedConformancePackage,
    compareConformanceFacts,
    renderConformancePackageFailure,
    renderConformancePackageReport,
  )
where

import Control.Monad (forM)
import Data.Char (isAlphaNum, isAscii, ord)
import Data.List (groupBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.RuntimePackage (RuntimePackageName (..), isCabalPackageName, mkRuntimePackageName)
import Keiro.Dsl.Scaffold (ModuleKind (..), generatedBannerFor, isGeneratedBannerLine)
import Keiro.Dsl.SemanticContract (CheckedService (..))
import Keiro.Dsl.ServiceHarness (serviceConformanceFactValues)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (isAbsolute, splitDirectories, takeDirectory, (</>))

data ConformanceServiceKey
  = WorkspaceConformanceService !Text
  | StandaloneConformanceService !Text
  deriving stock (Eq, Ord, Show)

data ConformanceFile = ConformanceFile
  { conformanceFilePath :: !FilePath,
    conformanceFileText :: !Text,
    conformanceFileKind :: !ModuleKind
  }
  deriving stock (Eq, Show)

data ConformancePackagePlan = ConformancePackagePlan
  { cppServiceKey :: !ConformanceServiceKey,
    cppDirectory :: !FilePath,
    cppPackageName :: !Text,
    cppRuntimePackage :: !RuntimePackageName,
    cppFacadeModule :: !Text,
    cppFiles :: ![ConformanceFile]
  }
  deriving stock (Eq, Show)

data ConformanceFactSide = ExpectedFact | ActualFact
  deriving stock (Eq, Ord, Show)

data DuplicateFactKey = DuplicateFactKey
  { duplicateFactSide :: !ConformanceFactSide,
    duplicateFactKey :: !String
  }
  deriving stock (Eq, Ord, Show)

data ConformanceFactResult
  = ConformanceFactMatch !String !String
  | ConformanceFactMismatch !String !String !String
  | ConformanceFactMissing !String !String
  | ConformanceFactUnexpected !String !String
  deriving stock (Eq, Ord, Show)

data ConformancePackageFailure
  = UnsafeConformanceServiceKey !Text
  | UnsafeConformancePath !FilePath
  | ConformancePathCollision ![FilePath]
  | PackageDuplicateFactKeys ![DuplicateFactKey]
  | ConformanceGeneratedBannerMissing ![FilePath]
  | InvalidConformancePackageRecord !FilePath
  | ConformancePackageRecordMismatch !FilePath
  deriving stock (Eq, Show)

data ConformancePackageRecord = ConformancePackageRecord
  { cprSchema :: !Int,
    cprServiceKey :: !ConformanceServiceKey,
    cprRuntimePackage :: !RuntimePackageName,
    cprFacadeModule :: !Text,
    cprFiles :: ![(ModuleKind, FilePath)]
  }
  deriving stock (Eq, Show)

data ConformanceWriteDisposition = ConformanceCreated | ConformanceOverwritten | ConformanceSkipped | ConformanceUnchanged
  deriving stock (Eq, Show)

data ConformanceStaleFile = ConformanceStaleFile
  { conformanceStaleKind :: !ModuleKind,
    conformanceStalePath :: !FilePath,
    conformanceStaleBannerPresent :: !(Maybe Bool)
  }
  deriving stock (Eq, Show)

data PreparedConformancePackage = PreparedConformancePackage
  { preparedRoot :: !FilePath,
    preparedPlan :: !ConformancePackagePlan,
    preparedStale :: ![ConformanceStaleFile]
  }
  deriving stock (Eq, Show)

data ConformancePackageReport = ConformancePackageReport
  { conformanceReportRoot :: !FilePath,
    conformanceReportPlan :: !ConformancePackagePlan,
    conformanceReportDispositions :: ![(ConformanceFile, ConformanceWriteDisposition)],
    conformanceReportStale :: ![ConformanceStaleFile]
  }
  deriving stock (Eq, Show)

conformanceRecordFileName :: FilePath
conformanceRecordFileName = "keiro-dsl-conformance-record.txt"

conformancePackageDirectory :: ConformanceServiceKey -> FilePath
conformancePackageDirectory = \case
  WorkspaceConformanceService service -> "keiro-dsl-conformance.workspace." <> T.unpack service
  StandaloneConformanceService context -> "keiro-dsl-conformance." <> T.unpack context

-- | Produce a collision-safe Cabal fragment. Ordinary lowercase Cabal names,
-- including hyphenated names, stay readable; every other spelling is encoded
-- character by character so @_@ and @-@ (and case) can never alias.
cabaliseConformanceService :: Text -> Text
cabaliseConformanceService service
  | isCabalPackageName service,
    T.toLower service == service =
      service
  | otherwise = "x-" <> T.intercalate "-" (map encodeCharacter (T.unpack service))
  where
    encodeCharacter character = "c" <> T.pack (showHex (ord character) "")

planConformancePackage :: ConformanceServiceKey -> RuntimePackageName -> Text -> CheckedService -> Either [ConformancePackageFailure] ConformancePackagePlan
planConformancePackage serviceKey runtimePackage facadeModule service
  | not (safeServiceKey serviceKey) = Left [UnsafeConformanceServiceKey (serviceKeyText serviceKey)]
  | not (null unsafePaths) = Left (map UnsafeConformancePath unsafePaths)
  | not (null collisions) = Left (map ConformancePathCollision collisions)
  | not (null duplicateFacts) = Left [PackageDuplicateFactKeys duplicateFacts]
  | otherwise = Right plan
  where
    serviceName = serviceKeyText serviceKey
    packageName = "keiro-" <> cabaliseConformanceService serviceName <> "-conformance"
    packageDirectory = conformancePackageDirectory serviceKey
    banner = generatedBannerFor (checkedLanguageContract service) ("conformance package " <> renderServiceKey serviceKey)
    factValues = sortOn fst (serviceConformanceFactValues service)
    duplicateFacts = duplicateKeys ActualFact [(T.unpack key, T.unpack value) | (key, value) <- factValues]
    cabalPath = T.unpack packageName <> ".cabal"
    baseFiles =
      [ ConformanceFile cabalPath (renderCabal banner packageName runtimePackage serviceName) Generated,
        ConformanceFile "src/Main.hs" (renderMain banner facadeModule) Generated,
        ConformanceFile "src/KeiroConformance/Expectations.hs" (renderExpectations factValues) HoleStub
      ]
    recordRows = [(conformanceFileKind file, conformanceFilePath file) | file <- baseFiles] <> [(Generated, conformanceRecordFileName)]
    record =
      ConformancePackageRecord
        { cprSchema = 1,
          cprServiceKey = serviceKey,
          cprRuntimePackage = runtimePackage,
          cprFacadeModule = facadeModule,
          cprFiles = recordRows
        }
    recordFile = ConformanceFile conformanceRecordFileName (banner <> "\n" <> renderConformancePackageRecord record) Generated
    files = baseFiles <> [recordFile]
    paths = packageDirectory : map conformanceFilePath files
    unsafePaths = filter (not . safeRelativePath) paths
    collisions =
      [ entries
      | entries <- Map.elems (Map.fromListWith (<>) [(T.toCaseFold (T.pack path), [path]) | path <- map conformanceFilePath files]),
        length entries > 1
      ]
    plan =
      ConformancePackagePlan
        { cppServiceKey = serviceKey,
          cppDirectory = packageDirectory,
          cppPackageName = packageName,
          cppRuntimePackage = runtimePackage,
          cppFacadeModule = facadeModule,
          cppFiles = files
        }

renderCabal :: Text -> Text -> RuntimePackageName -> Text -> Text
renderCabal banner packageName runtimePackage serviceName =
  T.unlines
    [ "cabal-version: 3.0",
      banner,
      "name: " <> packageName,
      "version: 0.0.0.0",
      "synopsis: Generated conformance runner for Keiro service " <> serviceName,
      "license: BSD-3-Clause",
      "build-type: Simple",
      "",
      "test-suite conformance",
      "  type: exitcode-stdio-1.0",
      "  hs-source-dirs: src",
      "  main-is: Main.hs",
      "  other-modules: KeiroConformance.Expectations",
      "  build-depends:",
      "      base >=4.18 && <5",
      "    , " <> unRuntimePackageName runtimePackage,
      "  default-language: GHC2024",
      "  default-extensions: OverloadedStrings"
    ]

renderMain :: Text -> Text -> Text
renderMain banner facadeModule =
  T.unlines
    [ banner,
      "module Main (main) where",
      "",
      "import Control.Monad (when)",
      "import Data.List (group, groupBy, sort, sortOn)",
      "import " <> facadeModule <> " (runServiceConformanceChecks, serviceConformanceFacts)",
      "import KeiroConformance.Expectations (expectedServiceConformanceFacts)",
      "import System.Exit (exitFailure)",
      "",
      "data FactResult",
      "  = FactMatch String String",
      "  | FactMismatch String String String",
      "  | FactMissing String String",
      "  | FactUnexpected String String",
      "",
      "newtype UniqueFactMap = UniqueFactMap [(String, String)]",
      "",
      "main :: IO ()",
      "main = do",
      "  checks <- runServiceConformanceChecks",
      "  mapM_ renderCheck checks",
      "  case compareFacts expectedServiceConformanceFacts serviceConformanceFacts of",
      "    Left duplicates -> do",
      "      mapM_ (putStrLn . (\"FAIL  duplicate conformance fact key: \" <>)) duplicates",
      "      exitFailure",
      "    Right facts -> do",
      "      mapM_ renderFact facts",
      "      when (any (not . snd) checks || any factFailed facts) exitFailure",
      "",
      "renderCheck :: (String, Bool) -> IO ()",
      "renderCheck (key, passed) = putStrLn ((if passed then \"PASS  \" else \"FAIL  \") <> key)",
      "",
      "renderFact :: FactResult -> IO ()",
      "renderFact result = putStrLn (case result of",
      "  FactMatch key _ -> \"PASS  \" <> key",
      "  FactMismatch key expected actual -> \"FAIL  \" <> key <> \" expected=\" <> show expected <> \" actual=\" <> show actual",
      "  FactMissing key expected -> \"FAIL  \" <> key <> \" expected=\" <> show expected <> \" actual=<missing>\"",
      "  FactUnexpected key actual -> \"FAIL  \" <> key <> \" expected=<missing> actual=\" <> show actual)",
      "",
      "factFailed :: FactResult -> Bool",
      "factFailed FactMatch {} = False",
      "factFailed _ = True",
      "",
      "compareFacts :: [(String, String)] -> [(String, String)] -> Either [String] [FactResult]",
      "compareFacts expected actual = do",
      "  expectedMap <- uniqueFactMap \"expected\" expected",
      "  actualMap <- uniqueFactMap \"actual\" actual",
      "  pure [compareKey key expectedMap actualMap | key <- factKeys expectedMap actualMap]",
      "",
      "uniqueFactMap :: String -> [(String, String)] -> Either [String] UniqueFactMap",
      "uniqueFactMap side facts =",
      "  case [side <> \"/\" <> fst first | entries@(first : _) <- groupBy sameKey (sortOn fst facts), length entries > 1] of",
      "    [] -> Right (UniqueFactMap (sortOn fst facts))",
      "    duplicates -> Left duplicates",
      "  where",
      "    sameKey left right = fst left == fst right",
      "",
      "factKeys :: UniqueFactMap -> UniqueFactMap -> [String]",
      "factKeys (UniqueFactMap expected) (UniqueFactMap actual) = [key | key : _ <- group (sort (map fst expected <> map fst actual))]",
      "",
      "compareKey :: String -> UniqueFactMap -> UniqueFactMap -> FactResult",
      "compareKey key (UniqueFactMap expected) (UniqueFactMap actual) =",
      "  case (lookup key expected, lookup key actual) of",
      "    (Just expectedValue, Just actualValue)",
      "      | expectedValue == actualValue -> FactMatch key actualValue",
      "      | otherwise -> FactMismatch key expectedValue actualValue",
      "    (Just expectedValue, Nothing) -> FactMissing key expectedValue",
      "    (Nothing, Just actualValue) -> FactUnexpected key actualValue",
      "    (Nothing, Nothing) -> error \"factKeys returned a key absent from both validated maps\""
    ]

renderExpectations :: [(Text, Text)] -> Text
renderExpectations facts =
  T.unlines $
    [ "-- Created once by keiro-dsl. This module is application-owned; review and edit it to accept conformance changes.",
      "module KeiroConformance.Expectations (expectedServiceConformanceFacts) where",
      "",
      "expectedServiceConformanceFacts :: [(String, String)]"
    ]
      <> case facts of
        [] -> ["expectedServiceConformanceFacts = []"]
        _ ->
          ["expectedServiceConformanceFacts ="]
            <> [ (if index == (0 :: Int) then "  [ " else "  , ") <> "(" <> haskellString key <> ", " <> haskellString value <> ")"
               | (index, (key, value)) <- zip [0 ..] facts
               ]
            <> ["  ]"]
  where
    haskellString = T.pack . show . T.unpack

renderConformancePackageRecord :: ConformancePackageRecord -> Text
renderConformancePackageRecord record =
  T.unlines $
    [ "schema " <> tshow (cprSchema record),
      "service-key " <> renderServiceKey (cprServiceKey record),
      "runtime-package " <> unRuntimePackageName (cprRuntimePackage record),
      "facade-module " <> cprFacadeModule record
    ]
      <> ["file " <> kindLabel fileKind <> " " <> T.pack path | (fileKind, path) <- cprFiles record]
  where
    kindLabel Generated = "generated"
    kindLabel HoleStub = "create-once"

parseConformancePackageRecord :: Text -> Maybe ConformancePackageRecord
parseConformancePackageRecord input = do
  schema <- exactlyOne [value | ["schema", raw] <- rows, Just value <- [readInt raw]]
  serviceKey <- exactlyOne [value | "service-key" : rest <- rows, Just value <- [parseServiceKey rest]]
  runtimePackage <- exactlyOne [value | ["runtime-package", raw] <- rows, Right value <- [mkRuntimePackageName raw]]
  facadeModule <- exactlyOne [value | ["facade-module", value] <- rows]
  files <- traverse parseFile [row | row@(keyword : _) <- rows, keyword == "file"]
  let knownRows = 4 + length files
  if schema == 1 && knownRows == length rows && safeServiceKey serviceKey && safeFiles files
    then
      Just
        ConformancePackageRecord
          { cprSchema = schema,
            cprServiceKey = serviceKey,
            cprRuntimePackage = runtimePackage,
            cprFacadeModule = facadeModule,
            cprFiles = files
          }
    else Nothing
  where
    rows = [T.words line | line <- T.lines input, let stripped = T.strip line, not (T.null stripped), not (isGeneratedBannerLine stripped)]
    parseServiceKey ["workspace", value] = Just (WorkspaceConformanceService value)
    parseServiceKey ["standalone", value] = Just (StandaloneConformanceService value)
    parseServiceKey _ = Nothing
    parseFile ["file", "generated", path] = Just (Generated, T.unpack path)
    parseFile ["file", "create-once", path] = Just (HoleStub, T.unpack path)
    parseFile _ = Nothing
    safeFiles files =
      all (safeRelativePath . snd) files
        && length files == Set.size (Set.fromList (map (T.toCaseFold . T.pack . snd) files))
    readInt raw = case reads (T.unpack raw) of
      [(value, "")] -> Just value
      _ -> Nothing

preflightConformancePackage :: FilePath -> Bool -> ConformancePackagePlan -> IO (Either [ConformancePackageFailure] PreparedConformancePackage)
preflightConformancePackage out forceGeneratedOverwrite plan = do
  bannerless <- if forceGeneratedOverwrite then pure [] else missingPackageBanners root (cppFiles plan)
  previousResult <- readPreviousRecord root forceGeneratedOverwrite bannerless plan
  case [ConformanceGeneratedBannerMissing (map (cppDirectory plan </>) bannerless) | not (null bannerless)] <> either id (const []) previousResult of
    failures@(_ : _) -> pure (Left failures)
    [] -> do
      let previous = either (const Nothing) id previousResult
      stale <- maybe (pure []) (stalePackageFiles root (map conformanceFilePath (cppFiles plan))) previous
      pure (Right PreparedConformancePackage {preparedRoot = root, preparedPlan = plan, preparedStale = stale})
  where
    root = out </> cppDirectory plan

readPreviousRecord :: FilePath -> Bool -> [FilePath] -> ConformancePackagePlan -> IO (Either [ConformancePackageFailure] (Maybe ConformancePackageRecord))
readPreviousRecord root forceGeneratedOverwrite bannerless plan = do
  let path = root </> conformanceRecordFileName
  exists <- doesFileExist path
  if not exists || conformanceRecordFileName `elem` bannerless || forceGeneratedOverwrite
    then pure (Right Nothing)
    else do
      parsed <- parseConformancePackageRecord <$> TIO.readFile path
      pure $ case parsed of
        Nothing -> Left [InvalidConformancePackageRecord (cppDirectory plan </> conformanceRecordFileName)]
        Just record
          | cprServiceKey record == cppServiceKey plan -> Right (Just record)
          | otherwise -> Left [ConformancePackageRecordMismatch (cppDirectory plan </> conformanceRecordFileName)]

missingPackageBanners :: FilePath -> [ConformanceFile] -> IO [FilePath]
missingPackageBanners root files = fmap concat . forM generated $ \file -> do
  let path = root </> conformanceFilePath file
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      contents <- TIO.readFile path
      pure [conformanceFilePath file | not (any isGeneratedBannerLine (T.lines contents))]
  where
    generated = [file | file <- files, conformanceFileKind file == Generated]

stalePackageFiles :: FilePath -> [FilePath] -> ConformancePackageRecord -> IO [ConformanceStaleFile]
stalePackageFiles root current record = fmap concat . forM removed $ \(fileKind, path) -> do
  exists <- doesFileExist (root </> path)
  if not exists
    then pure []
    else do
      evidence <- case fileKind of
        HoleStub -> pure Nothing
        Generated -> do
          contents <- TIO.readFile (root </> path)
          pure (Just (any isGeneratedBannerLine (T.lines contents)))
      pure [ConformanceStaleFile fileKind path evidence]
  where
    currentSet = Set.fromList current
    removed = [(fileKind, path) | (fileKind, path) <- cprFiles record, path `Set.notMember` currentSet]

executePreparedConformancePackage :: PreparedConformancePackage -> IO ConformancePackageReport
executePreparedConformancePackage prepared = do
  dispositions <- traverse (writeConformanceFile (preparedRoot prepared)) (cppFiles plan)
  pure
    ConformancePackageReport
      { conformanceReportRoot = preparedRoot prepared,
        conformanceReportPlan = plan,
        conformanceReportDispositions = dispositions,
        conformanceReportStale = preparedStale prepared
      }
  where
    plan = preparedPlan prepared

writeConformanceFile :: FilePath -> ConformanceFile -> IO (ConformanceFile, ConformanceWriteDisposition)
writeConformanceFile root file = do
  let path = root </> conformanceFilePath file
  exists <- doesFileExist path
  case conformanceFileKind file of
    HoleStub
      | exists -> pure (file, ConformanceSkipped)
      | otherwise -> write path ConformanceCreated
    Generated
      | exists -> do
          existing <- TIO.readFile path
          if existing == conformanceFileText file
            then pure (file, ConformanceUnchanged)
            else write path ConformanceOverwritten
      | otherwise -> write path ConformanceCreated
  where
    write path disposition = do
      createDirectoryIfMissing True (takeDirectory path)
      TIO.writeFile path (conformanceFileText file)
      pure (file, disposition)

compareConformanceFacts :: [(String, String)] -> [(String, String)] -> Either [DuplicateFactKey] [ConformanceFactResult]
compareConformanceFacts expected actual =
  case duplicateKeys ExpectedFact expected <> duplicateKeys ActualFact actual of
    duplicates@(_ : _) -> Left duplicates
    [] -> Right (map compareKey allKeys)
  where
    expectedMap = Map.fromList expected
    actualMap = Map.fromList actual
    allKeys = Set.toAscList (Map.keysSet expectedMap <> Map.keysSet actualMap)
    compareKey key = case (Map.lookup key expectedMap, Map.lookup key actualMap) of
      (Just expectedValue, Just actualValue)
        | expectedValue == actualValue -> ConformanceFactMatch key actualValue
        | otherwise -> ConformanceFactMismatch key expectedValue actualValue
      (Just expectedValue, Nothing) -> ConformanceFactMissing key expectedValue
      (Nothing, Just actualValue) -> ConformanceFactUnexpected key actualValue
      (Nothing, Nothing) -> error "compareConformanceFacts union key missing from both maps"

duplicateKeys :: ConformanceFactSide -> [(String, String)] -> [DuplicateFactKey]
duplicateKeys side facts =
  [ DuplicateFactKey side key
  | entries@((key, _) : _) <- groupBy (\left right -> fst left == fst right) (sortOn fst facts),
    length entries > 1
  ]

renderConformancePackageFailure :: ConformancePackageFailure -> [Text]
renderConformancePackageFailure = \case
  UnsafeConformanceServiceKey key -> ["error: unsafe conformance service key '" <> key <> "' -- refusing to scaffold; nothing was written"]
  UnsafeConformancePath path -> ["error: unsafe conformance package path -- refusing to scaffold; nothing was written", "  " <> T.pack path]
  ConformancePathCollision paths -> ["error: conformance package path collision -- refusing to scaffold; nothing was written"] <> map ("  " <>) (map T.pack paths)
  PackageDuplicateFactKeys duplicates ->
    ["error: duplicate conformance fact keys -- refusing to scaffold; nothing was written"]
      <> ["  " <> sideLabel (duplicateFactSide duplicate) <> "/" <> T.pack (duplicateFactKey duplicate) | duplicate <- duplicates]
  ConformanceGeneratedBannerMissing paths ->
    ["error: refusing to overwrite generated conformance package files without a recognized '-- @generated' banner"]
      <> map ("  " <>) (map T.pack paths)
      <> ["nothing was written"]
  InvalidConformancePackageRecord path -> ["error: invalid generated conformance package record -- refusing to scaffold; nothing was written", "  " <> T.pack path]
  ConformancePackageRecordMismatch path -> ["error: conformance package record belongs to a different service -- refusing to scaffold; nothing was written", "  " <> T.pack path]
  where
    sideLabel ExpectedFact = "expected"
    sideLabel ActualFact = "actual"

renderConformancePackageReport :: ConformancePackageReport -> [Text]
renderConformancePackageReport report =
  [ "conformance-package: " <> T.pack cabalPath,
    "conformance-target: cabal test " <> cppPackageName plan
  ]
    <> [ "conformance-file: " <> T.pack (root </> conformanceFilePath file) <> " " <> dispositionTag disposition
       | (file, disposition) <- dispositions,
         conformanceFileKind file == Generated,
         conformanceFilePath file /= conformanceRecordFileName
       ]
    <> ["expectations: " <> T.pack (root </> conformanceFilePath file) <> " " <> dispositionTag disposition | (file, disposition) <- dispositions, conformanceFileKind file == HoleStub]
    <> ["conformance-record: " <> T.pack (root </> conformanceRecordFileName) <> " " <> dispositionTag disposition | (file, disposition) <- dispositions, conformanceFilePath file == conformanceRecordFileName]
    <> staleLines
  where
    plan = conformanceReportPlan report
    root = conformanceReportRoot report
    dispositions = conformanceReportDispositions report
    cabalPath = root </> T.unpack (cppPackageName plan) <> ".cabal"
    dispositionTag ConformanceCreated = "(created)"
    dispositionTag ConformanceOverwritten = "(overwritten)"
    dispositionTag ConformanceSkipped = "(skipped: already present)"
    dispositionTag ConformanceUnchanged = "(unchanged)"
    staleLines = case conformanceReportStale report of
      [] -> []
      stale ->
        ["conformance-stale: " <> tshow (length stale) <> " file(s) are no longer produced; keiro-dsl never deletes files."]
          <> ["  " <> staleKindLabel (conformanceStaleKind file) <> " " <> T.pack (root </> conformanceStalePath file) <> staleEvidence file | file <- stale]
    staleKindLabel Generated = "generated"
    staleKindLabel HoleStub = "create-once"
    staleEvidence file = case conformanceStaleBannerPresent file of
      Nothing -> " (hand-owned; preserve and review)"
      Just True -> " (recognized generated banner present; review before deleting)"
      Just False -> " (generated banner missing; preserve and review)"

safeServiceKey :: ConformanceServiceKey -> Bool
safeServiceKey key = case T.uncons (serviceKeyText key) of
  Nothing -> False
  Just (first, rest) -> asciiAlphaNum first && T.all wireCharacter rest
  where
    asciiAlphaNum character = isAscii character && isAlphaNum character
    wireCharacter character = asciiAlphaNum character || character == '_' || character == '-'

safeRelativePath :: FilePath -> Bool
safeRelativePath path =
  not (null path)
    && not (isAbsolute path)
    && all (\component -> component /= ".." && component /= "." && not (null component)) (splitDirectories path)

serviceKeyText :: ConformanceServiceKey -> Text
serviceKeyText (WorkspaceConformanceService service) = service
serviceKeyText (StandaloneConformanceService context) = context

renderServiceKey :: ConformanceServiceKey -> Text
renderServiceKey (WorkspaceConformanceService service) = "workspace " <> service
renderServiceKey (StandaloneConformanceService context) = "standalone " <> context

exactlyOne :: [a] -> Maybe a
exactlyOne [value] = Just value
exactlyOne _ = Nothing

tshow :: (Show a) => a -> Text
tshow = T.pack . show
