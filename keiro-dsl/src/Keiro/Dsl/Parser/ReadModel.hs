-- | Read-model syntax.
module Keiro.Dsl.Parser.ReadModel
  ( pReadModel,
  )
where

import Keiro.Dsl.Frontend.Internal (FrontendContext, frontendSupportsFeature)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (LanguageFeature (MappedConsumerSurfaceSyntax, ProjectionCatalogSyntax))
import Keiro.Dsl.Parser.Core
import Keiro.Dsl.Parser.Mapped (pMappedTypeExpr)
import Text.Megaparsec

pReadModel :: FrontendContext -> P ReadModelNode
pReadModel context = do
  loc <- getLoc
  keyword "readmodel"
  name <- ident
  _ <- symbol "{"
  (table, schema) <-
    if frontendSupportsFeature context ProjectionCatalogSyntax
      then option ("", "") $ try $ do
        _ <- symbol "table" *> symbol "="
        table <- stringLit
        _ <- symbol "schema" *> symbol "="
        schema <- stringLit
        pure (table, schema)
      else do
        _ <- symbol "table" *> symbol "="
        table <- stringLit
        _ <- symbol "schema" *> symbol "="
        schema <- stringLit
        pure (table, schema)
  _ <- symbol "columns"
  columns <- braces (many pColumn)
  queryTypes <- optionalLanguageFeature context MappedConsumerSurfaceSyntax "query" pQueryTypes
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
  group <- optionalLanguageFeature context ProjectionCatalogSyntax "group" (try (symbol "group" *> symbol "=" *> ident))
  observedTargets <- case group of
    Nothing -> pure []
    Just _ -> symbol "targets" *> symbol "=" *> brackets (many ident)
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
        rmGroup = group,
        rmObservedTargets = observedTargets,
        queryTypes,
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
    pQueryTypes = do
      inputLoc <- getLoc
      keyword "query"
      _ <- symbol "input" *> symbol "="
      input <- pMappedTypeExpr context
      resultLoc <- getLoc
      keyword "query"
      _ <- symbol "result" *> symbol "="
      result <- pMappedTypeExpr context
      pure ReadModelQueryTypes {input, result, inputLoc, resultLoc}
