-- | Read-model syntax.
module Keiro.Dsl.Parser.ReadModel
  ( pReadModel,
  )
where

import Keiro.Dsl.Frontend.Internal (FrontendContext, frontendSupportsFeature)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (LanguageFeature (MappedConsumerSurfaceSyntax, ProjectionCatalogSyntax, SeparatedProjectionQueryPolicySyntax))
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
  (freshness, supply) <-
    if frontendSupportsFeature context SeparatedProjectionQueryPolicySyntax
      then pSeparatedPolicy
      else pLegacyPolicy
  group <- optionalLanguageFeature context ProjectionCatalogSyntax "group" (try (symbol "group" *> symbol "=" *> ident))
  observedTargets <- case group of
    Nothing -> pure []
    Just _ -> symbol "targets" *> symbol "=" *> brackets (many ident)
  backingTarget <- case group of
    Nothing -> pure Nothing
    Just _ -> optional (symbol "backing" *> symbol "=" *> ident)
  _ <- symbol "}"
  pure
    ReadModelNode
      { rmName = name,
        rmTable = table,
        rmSchema = schema,
        rmColumns = columns,
        rmVersion = version,
        rmShape = shape,
        rmFreshness = freshness,
        rmSupply = supply,
        rmGroup = group,
        rmObservedTargets = observedTargets,
        rmBackingTarget = backingTarget,
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
    pLegacyPolicy = do
      separatedMarker <- optional (try (withOwnedSpan (keyword "freshness")))
      case separatedMarker of
        Just marker -> requireLanguageFeatureAt context SeparatedProjectionQueryPolicySyntax (spanOf marker)
        Nothing -> pure ()
      _ <- symbol "consistency" *> symbol "="
      consistency <- pConsistency
      scope <- optional (symbol "scope" *> symbol "=" *> pScope)
      _ <- symbol "feed" *> symbol "="
      feed <- pFeed
      subscription <- optional (symbol "subscription" *> symbol "=" *> stringLit)
      let freshness = case consistency of
            Eventual -> FreshnessImmediate
            Strong -> FreshnessWaitForHead (maybe RmEntireLog id scope)
      pure
        ( freshness,
          LegacyReadModelSupply
            { legacyConsistency = consistency,
              legacyScope = scope,
              legacyFeed = feed,
              legacySubscription = subscription
            }
        )
    pSeparatedPolicy = do
      rejectLegacyPolicyClause
      _ <- symbol "freshness" *> symbol "="
      freshness <-
        choice
          [ FreshnessImmediate <$ keyword "immediate",
            FreshnessWaitForHead <$> (keyword "wait-for-head" *> pScope)
          ]
      rejectLegacyPolicyClause
      pure (freshness, OwnerDerivedSupply)
    rejectLegacyPolicyClause = do
      startOffset <- getOffset
      legacyClause <-
        optional
          ( lookAhead
              ( choice
                  [ "consistency" <$ keyword "consistency",
                    "scope" <$ keyword "scope",
                    "feed" <$ keyword "feed",
                    "subscription" <$ keyword "subscription"
                  ]
              )
          )
      case legacyClause of
        Nothing -> pure ()
        Just clauseName ->
          failAt
            startOffset
            ( "Language 5 readmodel policy is `freshness = immediate | wait-for-head ...`; remove legacy `"
                <> clauseName
                <> "` and derive delivery/subscription from its projection-owner"
            )
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
