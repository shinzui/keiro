{-# LANGUAGE DeriveGeneric #-}

module Shape (Item (..)) where

import Data.Text (Text)
import GHC.Generics (Generic)

data Item = Exact {contentDigest :: Text}
  deriving stock (Generic)
