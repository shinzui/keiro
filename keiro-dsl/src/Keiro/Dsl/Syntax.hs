{-# LANGUAGE NoFieldSelectors #-}

-- | Located, non-lossless surface syntax for a Keiro source document.
--
-- The surface layer preserves document order and source ownership while
-- deliberately omitting comments and whitespace. Semantic consumers should
-- use 'Keiro.Dsl.Frontend.lowerSurfaceSource' rather than depending on these
-- types directly.
module Keiro.Dsl.Syntax
  ( SurfaceSource (..),
    SurfaceSpec (..),
    SurfaceTopItem (..),
    SurfaceElement (..),
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
  ( EnumDecl,
    Expr,
    IdDecl,
    MappedDecl,
    Name,
    Node,
    NominalScalarDecl,
    Placement,
    RuleDecl,
  )
import Keiro.Dsl.LanguageVersion (SourceLanguage)
import Keiro.Dsl.Source (Located)

-- | One parsed source with its selected released language contract.
data SurfaceSource = SurfaceSource
  { source :: !FilePath,
    language :: !SourceLanguage,
    preamble :: !(Maybe (Located SourceLanguage)),
    spec :: !(Located SurfaceSpec)
  }
  deriving stock (Eq, Show, Generic)

-- | Document-level syntax before declarations are normalized into grouped
-- semantic lists.
data SurfaceSpec = SurfaceSpec
  { context :: !(Located Text),
    moduleRoot :: !(Maybe (Located Text)),
    layout :: !(Maybe (Located Placement)),
    items :: ![Located SurfaceTopItem],
    elements :: ![Located SurfaceElement]
  }
  deriving stock (Eq, Show, Generic)

-- | A source-ordered top-level declaration or runtime node. Existing grammar
-- values are reused where parsing does not erase a syntax distinction.
data SurfaceTopItem
  = SurfaceId !IdDecl
  | SurfaceEnum !EnumDecl
  | SurfaceRule !RuleDecl
  | SurfaceNominalScalar !NominalScalarDecl
  | SurfaceMapped !MappedDecl
  | SurfaceNode !Node
  deriving stock (Eq, Show, Generic)

-- | Nested syntax whose exact ownership is required before semantic lowering.
-- The set grows with grammar-module extraction; semantic leaf values are
-- reused when parsing does not erase a distinction.
data SurfaceElement
  = SurfaceField !Text
  | SurfaceExpression !Expr
  | SurfaceAggregateState !Name !Name
  | SurfaceAggregateTransition !Name !Int
  deriving stock (Eq, Show, Generic)
