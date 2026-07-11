{-# LANGUAGE TemplateHaskell #-}

module Keiro.Migrations.Internal.EmbedFile (embedTextFile) where

import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Language.Haskell.TH (Exp (..), Lit (..), Q)
import Language.Haskell.TH.Syntax qualified as TH

embedTextFile :: FilePath -> Q Exp
embedTextFile inputPath = do
    path <- TH.makeRelativeToProject inputPath
    TH.addDependentFile path
    bytes <- TH.runIO (ByteString.readFile path)
    case Text.Encoding.decodeUtf8' bytes of
        Left decodeError -> fail ("invalid UTF-8 in " <> path <> ": " <> show decodeError)
        Right contents ->
            pure (AppE (VarE 'Text.pack) (LitE (StringL (Text.unpack contents))))
