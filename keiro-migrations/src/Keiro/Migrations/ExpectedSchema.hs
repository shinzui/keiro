{-# LANGUAGE TemplateHaskell #-}

module Keiro.Migrations.ExpectedSchema (
    expectedSchemaFiles,
    withMaterializedExpectedSchema,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.FileEmbed (embedDir)
import Data.Foldable (traverse_)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)

-- Embedded expected schema (touch this comment after regenerating expected-schema
-- so Template Haskell refreshes the executable snapshot).
expectedSchemaFiles :: [(FilePath, ByteString)]
expectedSchemaFiles = $(embedDir "expected-schema")

withMaterializedExpectedSchema :: (FilePath -> IO a) -> IO a
withMaterializedExpectedSchema action =
    withSystemTempDirectory "keiro-expected-schema" $ \dir -> do
        traverse_ (writeEmbeddedFile dir) expectedSchemaFiles
        action dir

writeEmbeddedFile :: FilePath -> (FilePath, ByteString) -> IO ()
writeEmbeddedFile dir (path, bytes) = do
    let target = dir </> path
    createDirectoryIfMissing True (takeDirectory target)
    BS.writeFile target bytes
