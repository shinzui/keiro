-- | Language-5 projection catalog syntax.
module Keiro.Dsl.Parser.ProjectionCatalog
  ( pProjectionTarget,
    pRebuildGroup,
    pProjectionRevision,
    pExternalRead,
    pProjectionOwner,
  )
where

import Keiro.Dsl.Frontend.Internal (FrontendContext, frontendSupportsFeature)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (LanguageFeature (ExternalReadContractSyntax, ProjectionCatalogSyntax, SeparatedProjectionQueryPolicySyntax))
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

pProjectionRevision :: FrontendContext -> P ProjectionRevisionNode
pProjectionRevision context = do
  loc <- getLoc
  marker <- withOwnedSpan (keyword "projection-revision")
  requireLanguageFeatureAt context ProjectionCatalogSyntax (spanOf marker)
  name <- ident
  _ <- symbol "{"
  group <- symbol "group" *> symbol "=" *> ident
  revisionTargets <- many pRevisionTarget
  _ <- symbol "}"
  pure ProjectionRevisionNode {prvName = name, prvGroup = group, prvTargets = revisionTargets, prvLoc = loc}
  where
    pRevisionTarget = do
      _ <- keyword "target"
      targetName <- ident
      _ <- symbol "{"
      schemaVersion <- symbol "schema-version" *> symbol "=" *> stringLit
      provisioner <- symbol "provisioner" *> symbol "=" *> stringLit
      provisionerVersion <- symbol "provisioner-version" *> symbol "=" *> boundedDecimal
      expectedShape <- symbol "expected-shape" *> symbol "=" *> stringLit
      validator <- symbol "validator" *> symbol "=" *> stringLit
      validatorVersion <- symbol "validator-version" *> symbol "=" *> boundedDecimal
      promotionObjects <- many pPromotionObject
      _ <- symbol "}"
      pure
        RevisionTargetNode
          { prtTarget = targetName,
            prtSchemaVersion = schemaVersion,
            prtProvisioner = provisioner,
            prtProvisionerVersion = provisionerVersion,
            prtExpectedShape = expectedShape,
            prtValidator = validator,
            prtValidatorVersion = validatorVersion,
            prtPromotionObjects = promotionObjects
          }
    pPromotionObject = do
      _ <- keyword "promotion"
      objectKind <-
        choice
          [ PromotionIndexNode <$ keyword "index",
            PromotionConstraintNode <$ keyword "constraint",
            PromotionOwnedSequenceNode <$ keyword "owned-sequence"
          ]
      generationName <- stringLit
      _ <- symbol "->"
      canonicalName <- stringLit
      pure (PromotionObjectNode objectKind generationName canonicalName)

pExternalRead :: FrontendContext -> P ExternalReadNode
pExternalRead context = do
  loc <- getLoc
  marker <- withOwnedSpan (keyword "external-read")
  requireLanguageFeatureAt context ExternalReadContractSyntax (spanOf marker)
  name <- ident
  _ <- symbol "{"
  version <- symbol "version" *> symbol "=" *> boundedDecimal
  queryModel <- symbol "query" *> symbol "=" *> ident
  resultSchema <- symbol "result-schema" *> symbol "=" *> stringLit
  resultType <- symbol "result-type" *> symbol "=" *> stringLit
  compatibleRevisions <- symbol "compatible-revisions" *> symbol "=" *> brackets (many ident)
  surfaceGeneration <- symbol "surface-generation" *> symbol "=" *> boundedDecimal
  _ <- symbol "}"
  pure
    ExternalReadNode
      { erName = name,
        erVersion = version,
        erQueryModel = queryModel,
        erResultSchema = resultSchema,
        erResultType = resultType,
        erCompatibleRevisions = compatibleRevisions,
        erSurfaceGeneration = surfaceGeneration,
        erLoc = loc
      }

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
