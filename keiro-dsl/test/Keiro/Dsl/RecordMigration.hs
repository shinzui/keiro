module Keiro.Dsl.RecordMigration
  ( recordMigrationSpec,
  )
where

import Control.Monad (filterM)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Hspec

recordMigrationSpec :: Spec
recordMigrationSpec = do
  describe "record API migration" $
    it "accounts for every package-authored record field" $
      manifestCheck
  describe "JSON contracts" $
    it "keeps every serialized record boundary named in the migration inventory" $
      manifestCheck
  describe "generated Haskell edition" $
    it "accounts for generated declarations, consumers, and local record defaults" $
      manifestCheck

manifestCheck :: Expectation
manifestCheck = do
  candidates <-
    filterM
      doesFileExist
      [ "scripts/generate-record-migration-manifests.py",
        "../scripts/generate-record-migration-manifests.py"
      ]
  script <- case candidates of
    path : _ -> pure path
    [] -> expectationFailure "record migration inventory generator is not available" >> fail "unreachable"
  (status, _stdout, stderr) <-
    readProcessWithExitCode
      "python3"
      [script, "--check"]
      ""
  case status of
    ExitSuccess -> pure ()
    ExitFailure code -> expectationFailure ("record migration inventory check failed (" <> show code <> "): " <> stderr)
