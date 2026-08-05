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
import Control.Monad (when)
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
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
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
  conformanceResults <- case conformancePlan of
    Nothing -> pure []
    Just packagePlan ->
      (: [])
        <$> planConformance
          out
          (cppDirectory packagePlan </> legacyConformanceRecordFileName)
          (cppDirectory packagePlan </> conformanceLedgerFileName)
  let results = ordinaryResults <> conformanceResults
      errors = [message | Left message <- results]
      moves = [move | Right (Just move) <- results]
  pure $ if null errors then Right moves else Left errors

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
sidecarBackupRelative oldRelative = ".keiro-dsl-name-migrations/sidecar-v1" </> oldRelative

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
