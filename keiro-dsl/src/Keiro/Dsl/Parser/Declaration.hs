-- | Shared ID, enum, and rule declarations.
module Keiro.Dsl.Parser.Declaration
  ( pIdDecl,
    pEnumDecl,
    pRuleDecl,
  )
where

import Data.Maybe (fromMaybe)
import Keiro.Dsl.Frontend.Internal (FrontendContext)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser.Core
import Keiro.Dsl.Parser.Expression (pExpr)
import Keiro.Dsl.Parser.Mapped (pUsingNominalBinding)
import Keiro.Dsl.Source (Located, mapLocated)
import Keiro.Dsl.Syntax (SurfaceElement (..))
import Text.Megaparsec (choice, many, sepBy1)

pIdDecl :: FrontendContext -> P IdDecl
pIdDecl context = do
  loc <- getLoc
  keyword "id"
  name <- ident
  _ <- symbol "prefix"
  _ <- symbol "="
  pfx <- wireWord
  admission <-
    fromMaybe TypeIdV7
      <$> optionalLanguageFeature context ExplicitIdAdmissionDomainSyntax "domain" pIdAdmission
  binding <- optionalLanguageFeature context NominalBindingSyntax "using" pUsingNominalBinding
  pure IdDecl {name = name, prefix = pfx, admission = admission, binding = binding, loc = loc}

pIdAdmission :: P IdAdmission
pIdAdmission = do
  keyword "domain"
  _ <- symbol "="
  choice
    [ TypeIdV5OrV7 <$ symbol "typeid-v5-or-v7",
      TypeIdV7 <$ symbol "typeid-v7"
    ]

pEnumDecl :: FrontendContext -> P EnumDecl
pEnumDecl context = do
  loc <- getLoc
  keyword "enum"
  name <- ident
  ctors <- braces (many pEnumCtor)
  binding <- optionalLanguageFeature context NominalBindingSyntax "using" pUsingNominalBinding
  pure EnumDecl {name = name, ctors = ctors, binding = binding, loc = loc}
  where
    pEnumCtor = do
      c <- ident
      _ <- symbol "="
      w <- wireWord
      pure (c, w)

pRuleDecl :: FrontendContext -> P (RuleDecl, [Located SurfaceElement])
pRuleDecl context = do
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
        { name = name,
          domain = dom,
          codomain = cod,
          cases = cases,
          loc = loc
        },
      elements
    )
  where
    pCase = do
      c <- ident
      _ <- symbol "=>"
      expression <- withOwnedSpan (pExpr context)
      pure ((c, locatedValue expression), mapLocated SurfaceExpression expression)
