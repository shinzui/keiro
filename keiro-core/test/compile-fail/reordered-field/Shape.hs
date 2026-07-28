{-# LANGUAGE DeriveGeneric #-}

module Shape (Item (..)) where

import Data.Text (Text)
import GHC.Generics (Generic)

data Item = Exact {second :: Int, first :: Text}
    deriving stock (Generic)
