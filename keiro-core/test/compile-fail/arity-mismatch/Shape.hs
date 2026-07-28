{-# LANGUAGE DeriveGeneric #-}

module Shape (Item (..)) where

import Data.Text (Text)
import GHC.Generics (Generic)

data Item = Exact {first :: Text, second :: Int}
    deriving stock (Generic)
