-- | Explicit Cabal package identity for the service runtime that compiles
-- generated Keiro modules.
module Keiro.Dsl.RuntimePackage
  ( RuntimePackageName (..),
    mkRuntimePackageName,
    isCabalPackageName,
  )
where

import Data.Char (isAscii, isDigit, isLetter)
import Data.Text (Text)
import Data.Text qualified as T

-- | A package name accepted by Cabal's component grammar. Keiro keeps this
-- distinct from a service name because the two identities need not agree.
newtype RuntimePackageName = RuntimePackageName
  { unRuntimePackageName :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | Validate and construct an explicit runtime package name.
mkRuntimePackageName :: Text -> Either Text RuntimePackageName
mkRuntimePackageName packageName
  | isCabalPackageName packageName = Right (RuntimePackageName packageName)
  | otherwise = Left ("runtime package '" <> packageName <> "' does not follow Cabal package-name grammar")

-- | The package-name rule shared by mapped Haskell sources and the runtime
-- package setting. Every hyphen-separated component is non-empty, contains
-- only ASCII letters and digits, and contains at least one letter.
isCabalPackageName :: Text -> Bool
isCabalPackageName packageName =
  not (null components) && all validComponent components
  where
    components = T.splitOn "-" packageName
    validComponent component =
      not (T.null component)
        && T.all asciiAlphaNum component
        && T.any asciiLetter component
    asciiAlphaNum c = isAscii c && (isLetter c || isDigit c)
    asciiLetter c = isAscii c && isLetter c
