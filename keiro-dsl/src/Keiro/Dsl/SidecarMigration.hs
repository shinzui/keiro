-- | Refuse-then-apply migration for renamed scaffold sidecars.
--
-- Planning inspects exact old and new paths before any ledger read. Applying a
-- rename preserves the bytes directly; applying a retirement moves the legacy
-- duplicate into the recoverable sidecar backup slot. Legacy conformance
-- records are converted to the forward-compatible ledger format before their
-- original bytes are retired.
module Keiro.Dsl.SidecarMigration
  ( SidecarScope (..),
    SidecarMoveDisposition (..),
    SidecarMove (..),
    PreparedSidecarMove,
    preparedSidecarMove,
    planSidecarMigrations,
    applyPreparedSidecarMoves,
    renderSidecarMove,
  )
where

import Control.Exception (IOException, bracketOnError, try)
import Control.Monad (filterM, when)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.ConformancePackage
  ( ConformancePackagePlan (cppDirectory),
    parseLegacyConformancePackageRecord,
    renderConformancePackageRecord,
  )
import Keiro.Dsl.Scaffold (isGeneratedBannerLine)
import Keiro.Dsl.SidecarNames
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removeFile, renameFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (Handle, hClose, openTempFile)

data SidecarScope
  = ContextSidecars !Text
  | WorkspaceSidecars !Text
  deriving stock (Eq, Show)

data SidecarMoveDisposition
  = RenameSidecar
  | RetireLegacySidecar
  | ConvertLegacyConformanceLedger
  deriving stock (Eq, Show)

data SidecarMove = SidecarMove
  { sidecarOldPath :: !FilePath,
    sidecarNewPath :: !FilePath,
    sidecarBackupPath :: !(Maybe FilePath),
    sidecarMoveDisposition :: !SidecarMoveDisposition
  }
  deriving stock (Eq, Show)

data PreparedSidecarMove = PreparedSidecarMove
  { preparedSidecarMove :: !SidecarMove,
    preparedConvertedContents :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | Inspect the two scope-specific sidecars and the optional generated
-- conformance package. An old-name file always produces a move: either a direct
-- rename when the new path is absent, or retirement when the new path is already
-- authoritative.
planSidecarMigrations :: FilePath -> SidecarScope -> Maybe ConformancePackagePlan -> IO (Either [Text] [PreparedSidecarMove])
planSidecarMigrations out scope conformancePlan = do
  ordinaryResults <- traverse (planOrdinary out) (scopePairs scope)
  -- Legacy conformance records are migrated wherever they are found in the out
  -- tree, not only when this run happens to plan a conformance package. Keying
  -- the migration on the plan left a record orphaned — and unreadable, since the
  -- legacy parser is no longer reachable from the current reader — as soon as a
  -- spec stopped generating a conformance package. See ExecPlan 199.
  legacyDirectories <- legacyConformanceDirectories out plannedDirectory
  conformanceResults <-
    traverse
      ( \directory ->
          planConformance
            out
            (directory </> legacyConformanceRecordFileName)
            (directory </> conformanceLedgerFileName)
      )
      (plannedDirectories <> legacyDirectories)
  let results = ordinaryResults <> conformanceResults
      errors = [message | Left message <- results]
      moves = [move | Right (Just move) <- results]
  pure $ if null errors then Right moves else Left errors
  where
    plannedDirectory = fmap cppDirectory conformancePlan
    plannedDirectories = maybe [] (: []) plannedDirectory

-- | Directories under @out@ holding a legacy conformance record, excluding the
-- one this run already plans. Bounded to the depth generated conformance
-- packages actually use, so it never walks a consumer's whole source tree.
legacyConformanceDirectories :: FilePath -> Maybe FilePath -> IO [FilePath]
legacyConformanceDirectories out planned = do
  candidates <- descend legacyConformanceSearchDepth ""
  filterM
    (\directory -> doesFileExist (out </> directory </> legacyConformanceRecordFileName))
    [directory | directory <- candidates, Just directory /= planned]
  where
    descend :: Int -> FilePath -> IO [FilePath]
    descend depth relative
      | depth < 0 = pure []
      | otherwise = do
          entries <- listDirectorySafe (out </> relative)
          children <-
            filterM
              (\name -> doesDirectoryExist (out </> relative </> name))
              -- Never descend into the migration backup root. A retired legacy
              -- record lives there permanently by design, so scanning it would
              -- make every later run want to "migrate" the backup, forever.
              [name | name <- entries, name /= sidecarBackupRootName]
          nested <-
            concat
              <$> traverse
                (\name -> descend (depth - 1) (if null relative then name else relative </> name))
                children
          pure ((if null relative then [] else [relative]) <> nested)

-- | Generated conformance packages sit at most this many directories below the
-- scaffold output root (@<out>/<package-dir>/@ plus room for a nested layout).
legacyConformanceSearchDepth :: Int
legacyConformanceSearchDepth = 3

listDirectorySafe :: FilePath -> IO [FilePath]
listDirectorySafe path = do
  exists <- doesDirectoryExist path
  if exists then listDirectory path else pure []

scopePairs :: SidecarScope -> [(FilePath, FilePath)]
scopePairs = \case
  ContextSidecars context ->
    [ (legacyContextRecordFileName context, contextLedgerFileName context),
      (legacyContextManifestFileName context, contextCabalFragmentFileName context)
    ]
  WorkspaceSidecars service ->
    [ (legacyWorkspaceRecordFileName service, workspaceLedgerFileName service),
      (legacyWorkspaceManifestFileName service, workspaceCabalFragmentFileName service)
    ]

planOrdinary :: FilePath -> (FilePath, FilePath) -> IO (Either Text (Maybe PreparedSidecarMove))
planOrdinary out (oldRelative, newRelative) = do
  oldExists <- doesFileExist (out </> oldRelative)
  newExists <- doesFileExist (out </> newRelative)
  if not oldExists
    then pure (Right Nothing)
    else
      if newExists
        then prepareRetirement out oldRelative newRelative
        else
          pure . Right . Just $
            PreparedSidecarMove
              { preparedSidecarMove =
                  SidecarMove
                    { sidecarOldPath = oldRelative,
                      sidecarNewPath = newRelative,
                      sidecarBackupPath = Nothing,
                      sidecarMoveDisposition = RenameSidecar
                    },
                preparedConvertedContents = Nothing
              }

planConformance :: FilePath -> FilePath -> FilePath -> IO (Either Text (Maybe PreparedSidecarMove))
planConformance out oldRelative newRelative = do
  oldExists <- doesFileExist (out </> oldRelative)
  newExists <- doesFileExist (out </> newRelative)
  if not oldExists
    then pure (Right Nothing)
    else
      if newExists
        then prepareRetirement out oldRelative newRelative
        else do
          legacyContents <- TIO.readFile (out </> oldRelative)
          case parseLegacyConformancePackageRecord legacyContents of
            Nothing -> pure (Left (T.pack oldRelative <> ": legacy conformance record is invalid and cannot be converted"))
            Just record -> do
              let backupRelative = sidecarBackupRelative oldRelative
              backupExists <- doesFileExist (out </> backupRelative)
              if backupExists
                then pure (Left (T.pack oldRelative <> ": sidecar migration backup already exists at " <> T.pack backupRelative))
                else
                  pure . Right . Just $
                    PreparedSidecarMove
                      { preparedSidecarMove =
                          SidecarMove
                            { sidecarOldPath = oldRelative,
                              sidecarNewPath = newRelative,
                              sidecarBackupPath = Just backupRelative,
                              sidecarMoveDisposition = ConvertLegacyConformanceLedger
                            },
                        preparedConvertedContents = Just (preserveBanner legacyContents <> renderConformancePackageRecord record)
                      }

prepareRetirement :: FilePath -> FilePath -> FilePath -> IO (Either Text (Maybe PreparedSidecarMove))
prepareRetirement out oldRelative newRelative = do
  let backupRelative = sidecarBackupRelative oldRelative
  backupExists <- doesFileExist (out </> backupRelative)
  if backupExists
    then pure (Left (T.pack oldRelative <> ": sidecar migration backup already exists at " <> T.pack backupRelative))
    else
      pure . Right . Just $
        PreparedSidecarMove
          { preparedSidecarMove =
              SidecarMove
                { sidecarOldPath = oldRelative,
                  sidecarNewPath = newRelative,
                  sidecarBackupPath = Just backupRelative,
                  sidecarMoveDisposition = RetireLegacySidecar
                },
            preparedConvertedContents = Nothing
          }

sidecarBackupRelative :: FilePath -> FilePath
sidecarBackupRelative oldRelative = sidecarBackupRootName </> "sidecar-v1" </> oldRelative

-- | The directory holding recoverable originals of retired legacy sidecars.
sidecarBackupRootName :: FilePath
sidecarBackupRootName = ".keiro-dsl-name-migrations"

preserveBanner :: Text -> Text
preserveBanner contents = T.unlines [line | line <- T.lines contents, isGeneratedBannerLine line]

applyPreparedSidecarMoves :: FilePath -> [PreparedSidecarMove] -> IO ()
applyPreparedSidecarMoves out = mapM_ applyOne
  where
    applyOne prepared = case sidecarMoveDisposition move of
      RenameSidecar -> do
        createDirectoryIfMissing True (takeDirectory newPath)
        renameFile oldPath newPath
      RetireLegacySidecar -> retire move oldPath
      ConvertLegacyConformanceLedger -> case preparedConvertedContents prepared of
        Nothing -> error "prepared conformance sidecar conversion lacks converted contents"
        Just converted -> do
          writeTextAtomic newPath converted
          retire move oldPath
      where
        move = preparedSidecarMove prepared
        oldPath = out </> sidecarOldPath move
        newPath = out </> sidecarNewPath move

    retire move oldPath = case sidecarBackupPath move of
      Nothing -> error "prepared sidecar retirement lacks a backup path"
      Just backupRelative -> do
        let backupPath = out </> backupRelative
        createDirectoryIfMissing True (takeDirectory backupPath)
        renameFile oldPath backupPath

writeTextAtomic :: FilePath -> Text -> IO ()
writeTextAtomic path contents = do
  let directory = takeDirectory path
  createDirectoryIfMissing True directory
  bracketOnError
    (openTempFile directory (takeFileName path <> ".tmp"))
    cleanupTemporary
    (\(temporary, handle) -> TIO.hPutStr handle contents >> hClose handle >> renameFile temporary path)

cleanupTemporary :: (FilePath, Handle) -> IO ()
cleanupTemporary (temporary, handle) = do
  _ <- try (hClose handle) :: IO (Either IOException ())
  exists <- doesFileExist temporary
  when exists (removeFile temporary)

renderSidecarMove :: SidecarMove -> Text
renderSidecarMove move = case sidecarMoveDisposition move of
  RenameSidecar -> path (sidecarOldPath move) <> " -> " <> path (sidecarNewPath move)
  RetireLegacySidecar -> path (sidecarOldPath move) <> " -> retired to " <> backup
  ConvertLegacyConformanceLedger -> path (sidecarOldPath move) <> " -> " <> path (sidecarNewPath move) <> "; original retired to " <> backup
  where
    path = T.pack
    backup = maybe "<missing-backup>" path (sidecarBackupPath move)
