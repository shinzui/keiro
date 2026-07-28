{-# LANGUAGE DeriveGeneric #-}

module Domain (Item (..)) where

import Data.Text (Text)
import GHC.Generics (Generic)

data Item = Exact {contentHash :: Text}
    deriving stock (Generic)
