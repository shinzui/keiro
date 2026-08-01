{-# LANGUAGE ImportQualifiedPost #-}

-- | Legacy and typed scalar expression syntax.
module Keiro.Dsl.Parser.Expression
  ( pExpr,
  )
where

import Control.Monad.Combinators.Expr (Operator (..), makeExprParser)
import Data.Char (isUpper)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser.Core
import Text.Megaparsec

-- Expr sublanguage
--------------------------------------------------------------------------------

pExpr :: LanguageVersion -> P Expr
pExpr version
  | languageSupportsFeature version TypedAggregateExpressionSyntax = makeExprParser (pScalarTerm version) scalarOperatorTable
  | otherwise = makeExprParser (pLegacyTerm version) legacyOperatorTable

pLegacyTerm :: LanguageVersion -> P Expr
pLegacyTerm version =
  choice
    [ parens (pExpr version),
      pUnsupportedScalarTerm version,
      EAtom . ABool <$> (True <$ keyword "true" <|> False <$ keyword "false"),
      EAtom . AName <$> ident
    ]

pUnsupportedScalarTerm :: LanguageVersion -> P Expr
pUnsupportedScalarTerm version = do
  loc <- getLoc
  _ <-
    try ((keyword "reg" <|> keyword "cmd") *> symbol ".")
  requireLanguageFeatureAt version TypedAggregateExpressionSyntax loc
  fail "unreachable supported scalar term in predecessor grammar"

-- | Highest precedence first: relational comparisons bind tighter than @&&@,
-- which binds tighter than @||@.
legacyOperatorTable :: [[Operator P Expr]]
legacyOperatorTable =
  [ [InfixL arithmeticUnsupported],
    [ InfixN (ECmp OpLe <$ op "<="),
      InfixN (ECmp OpGe <$ op ">="),
      InfixN (ECmp OpEq <$ op "=="),
      InfixN (ECmp OpNeq <$ op "!="),
      InfixN (ECmp OpLt <$ op "<"),
      InfixN (ECmp OpGt <$ op ">")
    ],
    [InfixL (EAnd <$ op "&&")],
    [InfixL (EOr <$ op "||")]
  ]
  where
    op s = symbol s
    arithmeticUnsupported = do
      offset <- getOffset
      operator <- lexeme (oneOf ['+', '-', '*', '/'])
      failAt offset ("aggregate arithmetic operator '" <> [operator] <> "' is unsupported; compare or copy whole values instead")

pScalarTerm :: LanguageVersion -> P Expr
pScalarTerm version =
  choice
    [ parens (pExpr version),
      collectionTermUnsupported,
      try pIdLiteral,
      do
        loc <- getLoc
        ELiteral loc . LiteralBool <$> (True <$ keyword "true" <|> False <$ keyword "false"),
      do
        loc <- getLoc
        ELiteral loc . LiteralText <$> stringLit,
      try $ do
        loc <- getLoc
        ELiteral loc . LiteralIntegral <$> integerLiteral,
      pScalarPath
    ]

pIdLiteral :: P Expr
pIdLiteral = do
  loc <- getLoc
  constructor <- ident
  value <- parens stringLit
  pure (ELiteral loc (LiteralId constructor value))

pScalarPath :: P Expr
pScalarPath = do
  loc <- getLoc
  firstName <- ident
  rest <- many (symbol "." *> ident)
  pure $ case (firstName, rest) of
    ("reg", name : path) -> EPath loc RegisterRoot (name : path)
    ("cmd", name : path) -> EPath loc CommandRoot (name : path)
    (_, [constructor]) | startsUpper firstName -> ELiteral loc (LiteralQualified firstName constructor)
    _ -> EPath loc UnqualifiedRoot (firstName : rest)
  where
    startsUpper value = maybe False (isUpper . fst) (T.uncons value)

collectionTermUnsupported :: P Expr
collectionTermUnsupported = do
  offset <- getOffset
  choice
    [ () <$ symbol "[",
      () <$ symbol "{",
      () <$ keyword "keys",
      () <$ keyword "values",
      () <$ keyword "any",
      () <$ keyword "all"
    ]
  failAt offset collectionExpressionMessage

collectionExpressionMessage :: String
collectionExpressionMessage = "CollectionExpressionUnsupported: collection expressions are reserved for plan 166"

scalarOperatorTable :: [[Operator P Expr]]
scalarOperatorTable =
  [ [InfixL (op "*" *> located EMultiply)],
    [ InfixL (op "+" *> located EAdd),
      InfixL (op "-" *> located ESubtract),
      InfixL scalarArithmeticUnsupported
    ],
    [ InfixN (ECmp OpLe <$ op "<="),
      InfixN (ECmp OpGe <$ op ">="),
      InfixN (ECmp OpEq <$ op "=="),
      InfixN (ECmp OpNeq <$ op "!="),
      InfixN (ECmp OpLt <$ op "<"),
      InfixN (ECmp OpGt <$ op ">"),
      InfixN collectionOperatorUnsupported
    ],
    [InfixL (EAnd <$ op "&&")],
    [InfixL (EOr <$ op "||")]
  ]
  where
    op value = symbol value
    located constructor = do
      loc <- getLoc
      pure (constructor loc)
    scalarArithmeticUnsupported = do
      offset <- getOffset
      operator <- lexeme (oneOf ['/', '%'])
      failAt offset ("aggregate arithmetic operator '" <> [operator] <> "' is unsupported")
    collectionOperatorUnsupported = do
      offset <- getOffset
      _ <- try (keyword "not" *> keyword "in") <|> keyword "in"
      failAt offset collectionExpressionMessage

--------------------------------------------------------------------------------
