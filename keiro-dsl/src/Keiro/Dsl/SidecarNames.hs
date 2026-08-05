-- | One naming authority for every sidecar emitted beside generated Haskell.
--
-- A ledger is machine-owned and read by later scaffold runs. A Cabal fragment
-- is human-facing text to paste into a component stanza. The explicit
-- @context@ and @workspace@ slots keep those namespaces disjoint by
-- construction, including for a context literally named @workspace@.
module Keiro.Dsl.SidecarNames
  ( contextLedgerFileName,
    workspaceLedgerFileName,
    conformanceLedgerFileName,
    contextCabalFragmentFileName,
    workspaceCabalFragmentFileName,
    workspaceMigrationReportFileName,
    legacyContextRecordFileName,
    legacyWorkspaceRecordFileName,
    legacyConformanceRecordFileName,
    legacyContextManifestFileName,
    legacyWorkspaceManifestFileName,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

contextLedgerFileName :: Text -> FilePath
contextLedgerFileName context = "keiro-dsl-ledger.context." <> T.unpack context <> ".txt"

workspaceLedgerFileName :: Text -> FilePath
workspaceLedgerFileName service = "keiro-dsl-ledger.workspace." <> T.unpack service <> ".txt"

conformanceLedgerFileName :: FilePath
conformanceLedgerFileName = "keiro-dsl-conformance-ledger.txt"

contextCabalFragmentFileName :: Text -> FilePath
contextCabalFragmentFileName context = "keiro-dsl-cabal-fragment.context." <> T.unpack context <> ".txt"

workspaceCabalFragmentFileName :: Text -> FilePath
workspaceCabalFragmentFileName service = "keiro-dsl-cabal-fragment.workspace." <> T.unpack service <> ".txt"

workspaceMigrationReportFileName :: Text -> FilePath
workspaceMigrationReportFileName service = "keiro-dsl-migration-report.workspace." <> T.unpack service <> ".txt"

legacyContextRecordFileName :: Text -> FilePath
legacyContextRecordFileName context = "keiro-dsl-scaffold-record." <> T.unpack context <> ".txt"

legacyWorkspaceRecordFileName :: Text -> FilePath
legacyWorkspaceRecordFileName service = "keiro-dsl-scaffold-record.workspace." <> T.unpack service <> ".txt"

legacyConformanceRecordFileName :: FilePath
legacyConformanceRecordFileName = "keiro-dsl-conformance-record.txt"

legacyContextManifestFileName :: Text -> FilePath
legacyContextManifestFileName context = "keiro-dsl-manifest." <> T.unpack context <> ".txt"

legacyWorkspaceManifestFileName :: Text -> FilePath
legacyWorkspaceManifestFileName service = "keiro-dsl-manifest.workspace." <> T.unpack service <> ".txt"
