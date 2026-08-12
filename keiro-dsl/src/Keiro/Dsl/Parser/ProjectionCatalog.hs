-- | Language-5 projection catalog syntax.
module Keiro.Dsl.Parser.ProjectionCatalog
  ( pProjectionTarget,
    pRebuildGroup,
    pProjectionOwner,
  )
where

import Keiro.Dsl.Frontend.Internal (FrontendContext, frontendSupportsFeature)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (LanguageFeature (ProjectionCatalogSyntax, SeparatedProjectionQueryPolicySyntax))
import Keiro.Dsl.Parser.Core
import Text.Megaparsec

pProjectionTarget :: FrontendContext -> P ProjectionTargetNode
pProjectionTarget context = do
  loc <- getLoc
  marker <- withOwnedSpan (keyword "target")
  requireLanguageFeatureAt context ProjectionCatalogSyntax (spanOf marker)
  name <- ident
  _ <- symbol "{"
  schema <- symbol "schema" *> symbol "=" *> stringLit
  table <- symbol "table" *> symbol "=" *> stringLit
  reset <- symbol "reset" *> symbol "=" *> pReset
  dependsOn <- option [] (try (symbol "depends-on" *> symbol "=" *> brackets (many ident)))
  _ <- symbol "}"
  pure ProjectionTargetNode {ptName = name, ptSchema = schema, ptTable = table, ptReset = reset, ptDependsOn = dependsOn, ptLoc = loc}
  where
    pReset = choice [TargetClear <$ keyword "clear", TargetPreserve <$ keyword "preserve"]

pRebuildGroup :: FrontendContext -> P RebuildGroupNode
pRebuildGroup context = do
  loc <- getLoc
  marker <- withOwnedSpan (keyword "rebuild-group")
  requireLanguageFeatureAt context ProjectionCatalogSyntax (spanOf marker)
  name <- ident
  _ <- symbol "{"
  targets <- symbol "targets" *> symbol "=" *> brackets (many ident)
  order <- symbol "order" *> symbol "=" *> brackets (many ident)
  _ <- symbol "}"
  pure RebuildGroupNode {rgName = name, rgTargets = targets, rgOrder = order, rgLoc = loc}

pProjectionOwner :: FrontendContext -> P ProjectionOwnerNode
pProjectionOwner context = do
  loc <- getLoc
  marker <- withOwnedSpan (keyword "projection-owner")
  requireLanguageFeatureAt context ProjectionCatalogSyntax (spanOf marker)
  name <- ident
  _ <- symbol "{"
  sources <- some pSource
  delivery <- pDeliveryClause
  group <- symbol "group" *> symbol "=" *> ident
  targets <- symbol "targets" *> symbol "=" *> brackets (many ident)
  ownerOrder <- symbol "order" *> symbol "=" *> boundedDecimal
  subscription <- optional (try (symbol "subscription" *> symbol "=" *> stringLit))
  dedup <- optional (try (symbol "dedup" *> symbol "=" *> stringLit))
  checkpointOnMissing <- many (try (symbol "checkpoint-on-missing") *> symbol "=" *> pCheckpointOnMissing)
  replay <- symbol "replay" *> symbol "=" *> pReplay
  _ <- symbol "}"
  pure
    ProjectionOwnerNode
      { poName = name,
        poSources = sources,
        poDelivery = delivery,
        poGroup = group,
        poTargets = targets,
        poOrder = ownerOrder,
        poSubscription = subscription,
        poDedup = dedup,
        poCheckpointOnMissing = checkpointOnMissing,
        poReplay = replay,
        poLoc = loc
      }
  where
    pSource = symbol "source" *> symbol "=" *> choice [CatalogAggregate <$> (keyword "aggregate" *> ident), CatalogCategory <$> (keyword "category" *> stringLit), CatalogAll <$ keyword "all"]
    pDeliveryClause
      | frontendSupportsFeature context SeparatedProjectionQueryPolicySyntax = do
          startOffset <- getOffset
          legacyFeed <- optional (lookAhead (keyword "feed"))
          case legacyFeed of
            Just _ -> failAt startOffset "Language 5 projection owners use `delivery = inline | subscription`; replace legacy `feed`"
            Nothing -> symbol "delivery" *> symbol "=" *> pDelivery
      | otherwise = do
          _ <- symbol "feed" *> symbol "="
          choice [DeliveryInline <$ keyword "inline", DeliverySubscription <$ keyword "subscription"]
    pDelivery = choice [DeliveryInline <$ keyword "inline", DeliverySubscription <$ keyword "subscription"]
    pCheckpointOnMissing = do
      startOffset <- getOffset
      choice
        [ CheckpointFromBeginning <$ keyword "from-beginning",
          CheckpointFromCurrentHead <$ keyword "from-current-head",
          CheckpointFail <$ keyword "fail",
          failAt startOffset "unknown checkpoint-on-missing policy; expected from-beginning, from-current-head, or fail"
        ]
    pReplay = choice [ProjectionReplayExplicit <$ keyword "explicit", ProjectionLiveOnly <$> (keyword "live-only" *> stringLit)]
