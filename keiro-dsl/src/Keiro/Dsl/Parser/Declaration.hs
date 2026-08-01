-- | Shared ID, enum, and rule declarations.
module Keiro.Dsl.Parser.Declaration
  ( pIdDecl,
    pEnumDecl,
    pRuleDecl,
  )
where

import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser.Core
import Keiro.Dsl.Parser.Expression (pExpr)
import Keiro.Dsl.Parser.Mapped (pUsingNominalBinding)
import Keiro.Dsl.Source (Located, mapLocated)
import Keiro.Dsl.Syntax (SurfaceElement (..))
import Text.Megaparsec (many, sepBy1)

pIdDecl :: LanguageVersion -> P IdDecl
pIdDecl version = do
  loc <- getLoc
  keyword "id"
  name <- ident
  _ <- symbol "prefix"
  _ <- symbol "="
  pfx <- wireWord
  binding <- optionalLanguageFeature version NominalBindingSyntax "using" pUsingNominalBinding
  pure IdDecl {idName = name, idPrefix = pfx, idBinding = binding, idLoc = loc}

pEnumDecl :: LanguageVersion -> P EnumDecl
pEnumDecl version = do
  loc <- getLoc
  keyword "enum"
  name <- ident
  ctors <- braces (many pEnumCtor)
  binding <- optionalLanguageFeature version NominalBindingSyntax "using" pUsingNominalBinding
  pure EnumDecl {enumName = name, enumCtors = ctors, enumBinding = binding, enumLoc = loc}
  where
    pEnumCtor = do
      c <- ident
      _ <- symbol "="
      w <- wireWord
      pure (c, w)

pRuleDecl :: LanguageVersion -> P (RuleDecl, [Located SurfaceElement])
pRuleDecl version = do
  loc <- getLoc
  keyword "rule"
  name <- ident
  _ <- symbol ":"
  dom <- ident
  _ <- symbol "->"
  cod <- ident
  keyword "ex"
  parsedCases <- sepBy1 pCase (symbol ";")
  let cases = map fst parsedCases
      elements = map snd parsedCases
  pure
    ( RuleDecl
        { ruleName = name,
          ruleDomain = dom,
          ruleCodomain = cod,
          ruleCases = cases,
          ruleLoc = loc
        },
      elements
    )
  where
    pCase = do
      c <- ident
      _ <- symbol "=>"
      expression <- withOwnedSpan (pExpr version)
      pure ((c, locatedValue expression), mapLocated SurfaceExpression expression)
