{-# LANGUAGE DeriveGeneric #-}

module Domain (Item (..)) where

import Data.Text (Text)
import GHC.Generics (Generic)

data Item = Exact {content :: Text}
  deriving stock (Generic)
