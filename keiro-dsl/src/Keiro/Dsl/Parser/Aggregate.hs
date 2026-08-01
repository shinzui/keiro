{-# LANGUAGE ImportQualifiedPost #-}

-- | Aggregate declarations, clauses, transitions, and expression ownership.
module Keiro.Dsl.Parser.Aggregate
  ( pAggregate,
  )
where

import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser.Core
import Keiro.Dsl.Parser.Expression (pExpr)
import Keiro.Dsl.Parser.Mapped (pMappedTypeExpr)
import Keiro.Dsl.Source (Located, mapLocated)
import Keiro.Dsl.Syntax (SurfaceElement (..))
import Text.Megaparsec

-- Aggregate node
--------------------------------------------------------------------------------

data BodyItem
  = BICommand Command [Located SurfaceElement]
  | BIEvent Event [Located SurfaceElement]
  | BIWire WireSpec
  | BIProjection ProjectionSpec
  | BISnapshot SnapshotSpec
  | BITransition Transition [Located SurfaceElement]

pAggregate :: LanguageVersion -> P (Aggregate, [Located SurfaceElement])
pAggregate version = do
  loc <- getLoc
  keyword "aggregate"
  name <- ident
  regs <- pRegsBlock version
  states <- pStatesLine
  positionedItems <- many ((,) <$> getOffset <*> pBodyItem version)
  let items = map snd positionedItems
      wireOffsets = [offset | (offset, BIWire _) <- positionedItems]
      projectionOffsets = [offset | (offset, BIProjection _) <- positionedItems]
      snapshotOffsets = [offset | (offset, BISnapshot _) <- positionedItems]
  case wireOffsets of
    _ : duplicateOffset : _ ->
      failAt duplicateOffset ("duplicate wire block in aggregate " <> T.unpack name <> " (only one is allowed)")
    _ -> pure ()
  case projectionOffsets of
    _ : duplicateOffset : _ ->
      failAt duplicateOffset ("duplicate projection block in aggregate " <> T.unpack name <> " (only one is allowed)")
    _ -> pure ()
  case snapshotOffsets of
    _ : duplicateOffset : _ ->
      failAt duplicateOffset ("duplicate snapshot block in aggregate " <> T.unpack name <> " (only one is allowed)")
    _ -> pure ()
  pure
    ( Aggregate
        { aggName = name,
          aggRegs = regs,
          aggStates = states,
          aggCommands = [c | BICommand c _ <- items],
          aggEvents = [e | BIEvent e _ <- items],
          aggTransitions = [t | BITransition t _ <- items],
          aggWire = listToMaybe [w | BIWire w <- items],
          aggProjection = listToMaybe [p | BIProjection p <- items],
          aggSnapshot = listToMaybe [s | BISnapshot s <- items],
          aggLoc = loc
        },
      concatMap bodyElements items
    )
  where
    listToMaybe xs = case xs of (x : _) -> Just x; [] -> Nothing
    bodyElements = \case
      BICommand _ elements -> elements
      BIEvent _ elements -> elements
      BITransition _ elements -> elements
      BIWire _ -> []
      BIProjection _ -> []
      BISnapshot _ -> []

pRegsBlock :: LanguageVersion -> P [RegDecl]
pRegsBlock version = do
  keyword "regs"
  many (pRegDecl version)

pRegDecl :: LanguageVersion -> P RegDecl
pRegDecl version = do
  loc <- getLoc
  name <- ident
  ty <- pMappedTypeExpr version
  _ <- symbol "="
  initial <- (RegInitText <$> stringLit) <|> (RegInitBare <$> (ident <|> signedDecimalText))
  pure RegDecl {regName = name, regType = ty, regInitial = initial, regLoc = loc}

pStatesLine :: P [StateDecl]
pStatesLine = do
  keyword "states"
  many pStateDecl
  where
    -- A state decl is an identifier with an optional terminal @!@. The
    -- @notFollowedBy@ lookahead stops the list before a transition whose source
    -- state would otherwise be swallowed as an extra state, e.g. when a
    -- transition directly follows the @states@ line with no command\/event
    -- between them. The @try@ backtracks so the identifier is left for
    -- 'pTransition'.
    pStateDecl = try $ do
      loc <- getLoc
      -- A @replay-only@ transition marker directly after the states line
      -- must not be swallowed: 'ident' would take @replay@ (hyphens are
      -- not identifier characters) and strand @-only@.
      notFollowedBy (keyword "replay-only")
      n <- ident
      term <- option False (True <$ symbol "!")
      notFollowedBy (symbol "--")
      pure StateDecl {stName = n, stTerminal = term, stLoc = loc}

pBodyItem :: LanguageVersion -> P BodyItem
pBodyItem version =
  choice
    [ uncurry BICommand <$> pCommand version,
      uncurry BIEvent <$> pEvent version,
      BIWire <$> pWire,
      BIProjection <$> pProjection,
      BISnapshot <$> pSnapshot,
      uncurry BITransition <$> pTransition version
    ]

pSnapshot :: P SnapshotSpec
pSnapshot = do
  loc <- getLoc
  keyword "snapshot"
  policy <-
    choice
      [ SnapEvery <$> (keyword "every" *> boundedDecimal),
        SnapOnTerminal <$ symbol "on-terminal"
      ]
  _ <- symbol "state-codec"
  _ <- symbol "version" *> symbol "="
  version <- boundedDecimal
  _ <- symbol "shape-hash" *> symbol "="
  hash <- stringLit
  pure SnapshotSpec {snapPolicy = policy, snapCodecVersion = version, snapShapeHash = hash, snapLoc = loc}

pCommand :: LanguageVersion -> P (Command, [Located SurfaceElement])
pCommand version = do
  loc <- getLoc
  keyword "command"
  name <- ident
  fields <- braces (many (withOwnedSpan (pAggregateField version)))
  pure
    ( Command {cmdName = name, cmdFields = map locatedValue fields, cmdLoc = loc},
      map (mapLocated (SurfaceField . aggregateFieldName)) fields
    )

pAggregateField :: LanguageVersion -> P AggregateField
pAggregateField version = do
  loc <- getLoc
  n <- ident
  mty <- optional (symbol ":" *> pMappedTypeExpr version)
  pure AggregateField {aggregateFieldName = n, aggregateFieldType = mty, aggregateFieldLoc = loc}

pEvent :: LanguageVersion -> P (Event, [Located SurfaceElement])
pEvent version = do
  loc <- getLoc
  (retiring, deprecated) <-
    option
      (False, False)
      ( choice
          [ (True, False) <$ keyword "retiring",
            (False, True) <$ keyword "deprecated"
          ]
      )
  keyword "event"
  name <- ident
  ver <- option 1 pVersion
  (body, elements) <-
    choice
      [ (\commandName -> (EventFromCommand commandName, [])) <$> (symbol "=" *> keyword "fields" *> parens ident),
        do
          fields <- braces (many (withOwnedSpan (pAggregateField version)))
          pure
            ( EventFields (map locatedValue fields),
              map (mapLocated (SurfaceField . aggregateFieldName)) fields
            )
      ]
  up <- optional pUpcast
  pure
    ( Event
        { evName = name,
          evBody = body,
          evVersion = ver,
          evUpcastFrom = up,
          evRetiring = retiring,
          evDeprecated = deprecated,
          evLoc = loc
        },
      elements
    )
  where
    pUpcast = do
      keyword "upcast"
      keyword "from"
      m <- pVersion
      _ <- symbol "="
      keyword "HOLE"
      pure (m, Hole)

pWire :: P WireSpec
pWire = do
  keyword "wire"
  _ <- symbol "kind"
  _ <- symbol "="
  k <- wireWord
  _ <- symbol "fields"
  _ <- symbol "="
  f <- wireWord
  _ <- symbol "schemaVersion"
  _ <- symbol "="
  v <- boundedDecimal
  pure WireSpec {wireKind = k, wireFields = f, wireSchemaVersion = v}

pProjection :: P ProjectionSpec
pProjection = do
  loc <- getLoc
  keyword "projection"
  table <- ident
  cons <- optional (symbol "consistency" *> symbol "=" *> pConsistency)
  _ <- symbol "key"
  _ <- symbol "="
  k <- ident
  sm <- optional pStatusMap
  pure
    ProjectionSpec
      { projTable = table,
        projConsistency = cons,
        projKey = k,
        projStatusMap = sm,
        projLoc = loc
      }
  where
    pConsistency =
      choice [Strong <$ keyword "Strong", Eventual <$ keyword "Eventual"]

pStatusMap :: P Mapping
pStatusMap = do
  keyword "status-map"
  partial <- option False (True <$ keyword "partial")
  pairs <- braces (many pPair)
  pure Mapping {mapPairs = pairs, mapPartial = partial}
  where
    pPair = do
      l <- ident
      _ <- symbol "=>"
      r <- wireWord
      pure (l, r)

--------------------------------------------------------------------------------
-- Transitions
--------------------------------------------------------------------------------

data Clause
  = CGuard Expr
  | CWrite Name Expr
  | CEmit Name
  | CGoto Name
  | CImplementationHole

pTransition :: LanguageVersion -> P (Transition, [Located SurfaceElement])
pTransition version = do
  startOffset <- getOffset
  loc <- getLoc
  -- Plan 143: a @replay-only@ prefix marks the transition as serving
  -- inversion only; it lowers to a keiki 'ReplayOnly' edge.
  mode <- option TmLive (TmReplayOnly <$ keyword "replay-only")
  src <- ident
  _ <- symbol "--"
  cmd <- ident
  _ <- symbol "-->"
  positionedClauses <- many ((,) <$> getOffset <*> (pClause version <* optional (symbol ";")))
  let clauses = map (fst . snd) positionedClauses
      elements = concatMap (snd . snd) positionedClauses
      gotos = [(offset, target) | (offset, (CGoto target, _)) <- positionedClauses]
      holeOffsets = [offset | (offset, (CImplementationHole, _)) <- positionedClauses]
      transitionName = T.unpack src <> " -- " <> T.unpack cmd
  gt <- case gotos of
    [] -> failAt startOffset ("transition " <> transitionName <> " is missing a goto clause")
    [(_, target)] -> pure target
    (_, firstTarget) : (duplicateOffset, _) : _ ->
      failAt
        duplicateOffset
        ("duplicate goto clause (transition " <> transitionName <> " already declared goto " <> T.unpack firstTarget <> ")")
  case holeOffsets of
    _ : duplicateOffset : _ -> failAt duplicateOffset ("duplicate implementation hole clause in transition " <> transitionName)
    _ -> pure ()
  let guards = [e | CGuard e <- clauses]
  pure
    ( Transition
        { tSource = src,
          tCommand = cmd,
          tImplementation = case holeOffsets of
            _ : _ -> HoleImplementation
            [] | languageSupportsFeature version TypedAggregateExpressionSyntax -> GeneratedImplementation
            [] -> LegacyHoleImplementation,
          tGuard = case guards of [] -> Nothing; es -> Just (foldr1 EAnd es),
          tWrites = [(r, e) | CWrite r e <- clauses],
          tEmits = [n | CEmit n <- clauses],
          tGoto = gt,
          tMode = mode,
          tLoc = loc
        },
      elements
    )

pClause :: LanguageVersion -> P (Clause, [Located SurfaceElement])
pClause version =
  choice
    [ do
        loc <- getLoc
        keyword "implementation"
        keyword "hole"
        requireLanguageFeatureAt version ExplicitTransitionImplementationSyntax loc
        pure (CImplementationHole, []),
      do
        keyword "guard"
        expression <- withOwnedSpan (pExpr version)
        pure (CGuard (locatedValue expression), [mapLocated SurfaceExpression expression]),
      do
        register <- keyword "write" *> ident
        _ <- symbol ":="
        expression <- withOwnedSpan (pExpr version)
        pure (CWrite register (locatedValue expression), [mapLocated SurfaceExpression expression]),
      try $ do
        keyword "emit"
        eventName <- ident
        notFollowedBy (symbol "{")
        pure (CEmit eventName, []),
      (\target -> (CGoto target, [])) <$> (keyword "goto" *> ident)
    ]

--------------------------------------------------------------------------------
