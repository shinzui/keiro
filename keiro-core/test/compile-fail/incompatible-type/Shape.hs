{-# LANGUAGE DeriveGeneric #-}

module Shape (Item (..)) where

import GHC.Generics (Generic)

data Item = Exact {content :: Int}
  deriving stock (Generic)
