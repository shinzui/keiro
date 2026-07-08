{-# LANGUAGE TemplateHaskell #-}

module Keiro.Migrations.ExpectedSchema (
    expectedSchemaFiles,
    withMaterializedExpectedSchema,
) where

import Codd.Extras.ExpectedSchema qualified as ExpectedSchema
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)

-- Embedded expected schema (touch this comment after regenerating expected-schema
-- so Template Haskell refreshes the executable snapshot).
expectedSchemaFiles :: [(FilePath, ByteString)]
expectedSchemaFiles = $(embedDir "expected-schema")

withMaterializedExpectedSchema :: (FilePath -> IO a) -> IO a
withMaterializedExpectedSchema action =
    ExpectedSchema.withMaterializedExpectedSchema "keiro-expected-schema" expectedSchemaFiles action
