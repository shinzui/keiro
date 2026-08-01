-- | Read-model syntax.
module Keiro.Dsl.Parser.ReadModel
  ( pReadModel,
  )
where

import Keiro.Dsl.Grammar
import Keiro.Dsl.Parser.Core
import Text.Megaparsec

pReadModel :: P ReadModelNode
pReadModel = do
  loc <- getLoc
  keyword "readmodel"
  name <- ident
  _ <- symbol "{"
  _ <- symbol "table" *> symbol "="
  table <- stringLit
  _ <- symbol "schema" *> symbol "="
  schema <- stringLit
  _ <- symbol "columns"
  columns <- braces (many pColumn)
  _ <- symbol "version" *> symbol "="
  version <- boundedDecimal
  _ <- symbol "shape" *> symbol "="
  shape <- stringLit
  _ <- symbol "consistency" *> symbol "="
  consistency <- pConsistency
  scope <- optional (symbol "scope" *> symbol "=" *> pScope)
  _ <- symbol "feed" *> symbol "="
  feed <- pFeed
  subscription <- optional (symbol "subscription" *> symbol "=" *> stringLit)
  _ <- symbol "}"
  pure
    ReadModelNode
      { rmName = name,
        rmTable = table,
        rmSchema = schema,
        rmColumns = columns,
        rmVersion = version,
        rmShape = shape,
        rmConsistency = consistency,
        rmScope = scope,
        rmFeed = feed,
        rmSubscription = subscription,
        rmLoc = loc
      }
  where
    pColumn =
      RmColumn
        <$> wireWord
        <*> ident
        <*> option False (True <$ keyword "required")
    pConsistency = choice [Strong <$ keyword "Strong", Eventual <$ keyword "Eventual"]
    pScope =
      choice
        [ RmEntireLog <$ keyword "entire-log",
          RmCategory <$> (keyword "category" *> stringLit)
        ]
    pFeed = choice [RmInline <$ keyword "inline", RmSubscription <$ keyword "subscription"]
