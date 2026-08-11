-- | Process-manager, router, timer, dispatch, and correlation syntax.
module Keiro.Dsl.Parser.Coordination
  ( pProcess,
    pRouter,
  )
where

import Data.List (intersperse)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Frontend.Internal (FrontendContext)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (LanguageFeature (DeclarativeRouterSelectionSyntax))
import Keiro.Dsl.Parser.Core
import Keiro.Dsl.Parser.Expression (pExpr)
import Keiro.Dsl.Parser.Mapped (pMappedTypeExpr)
import Keiro.Dsl.Source (SourceSpan)
import Text.Megaparsec
import Text.Megaparsec.Char (char)

-- Process manager + durable timer (EP-3)
--------------------------------------------------------------------------------

pProcess :: P ProcessNode
pProcess = do
  loc <- getLoc
  keyword "process"
  pid <- ident
  keyword "name"
  nm <- stringLit
  inp <- pInputDecl
  corr <- pCorrelate
  saga <- pSaga
  keyword "target"
  tgt <- ident
  projs <- keyword "projections" *> brackets (many ident)
  handle <- pHandle
  _ <- optional pDispatchIdLine
  rejected <- pPolicyLine "rejected"
  poison <- pPolicyLine "poison"
  timer <- pTimerNode
  pure
    ProcessNode
      { procId = pid,
        procName = nm,
        procInput = inp,
        procCorrelate = corr,
        procSaga = saga,
        procTarget = tgt,
        procProjections = projs,
        procHandle = handle,
        procRejected = rejected,
        procPoison = poison,
        procTimer = timer,
        procLoc = loc
      }

pRouter :: FrontendContext -> P RouterNode
pRouter context = do
  loc <- getLoc
  keyword "router"
  rid <- ident
  keyword "name"
  nm <- stringLit
  (inp, typedInputSpan) <- pRouterInputDecl context
  key <- pRouterKey (maybe False (const True) typedInputSpan)
  resolved <- pResolveDecl context
  case (typedInputSpan, rvSource resolved) of
    (Just _, ResolveDeclarative {}) -> pure ()
    (Nothing, ResolveReadModel {}) -> pure ()
    (Nothing, ResolveHole) -> pure ()
    (Just _, _) -> fail "typed router input requires declarative selection"
    (Nothing, ResolveDeclarative {}) -> fail "declarative selection requires a typed router input"
  keyword "target"
  target <- ident
  projections <- keyword "projections" *> brackets (many ident)
  dispatch <- pRouterDispatch
  pRouterDispatchIdLine
  rejected <- pPolicyLine "rejected"
  poison <- pPolicyLine "poison"
  pure
    RouterNode
      { rtId = rid,
        rtName = nm,
        rtInput = inp,
        rtKey = key,
        rtResolve = resolved,
        rtTarget = target,
        rtProjections = projections,
        rtDispatch = dispatch,
        rtRejected = rejected,
        rtPoison = poison,
        rtLoc = loc
      }

pRouterKey :: Bool -> P CorrelateDecl
pRouterKey declarative = do
  keyword "key"
  _ <- keyword "input" *> symbol "."
  field <- ident
  via <- if declarative then pure "idText" else keyword "via" *> ident
  pure CorrelateDecl {corrField = field, corrVia = via}

pResolveDecl :: FrontendContext -> P ResolveDecl
pResolveDecl context = do
  loc <- getLoc
  keyword "resolve"
  choice [pDeclarativeResolve context loc, pCustomResolve loc]

pCustomResolve :: Loc -> P ResolveDecl
pCustomResolve loc = do
  keyword "stable"
  keyword "via"
  source <- choice [ResolveReadModel <$> (keyword "read-model" *> ident), ResolveHole <$ keyword "hole"]
  keyword "row"
  row <- braces (many ident)
  pure ResolveDecl {rvSource = source, rvRow = row, rvLoc = loc}

pDeclarativeResolve :: FrontendContext -> Loc -> P ResolveDecl
pDeclarativeResolve context loc = do
  marker <- withOwnedSpan (keyword "declarative")
  requireLanguageFeatureAt context DeclarativeRouterSelectionSyntax (spanOf marker)
  selection <- braces (pRouterSelection context loc)
  pure ResolveDecl {rvSource = ResolveDeclarative selection, rvRow = [], rvLoc = loc}

pRouterSelection :: FrontendContext -> Loc -> P RouterSelectionDecl
pRouterSelection context loc = do
  (identity, identityLoc) <- locatedClause "identity" stringLit
  (version, versionLoc) <- locatedClause "version" (fromIntegral <$> boundedDecimal)
  queryLoc <- getLoc
  keyword "query"
  _ <- symbol "=" *> keyword "read-model"
  query <- ident
  keyword "with"
  queryInputLoc <- getLoc
  queryInput <- ident
  keyword "where"
  _ <- symbol "="
  predicate <- pExpr context
  keyword "recipient"
  _ <- symbol "="
  recipient <- pExpr context
  (order, orderLoc) <- locatedClause "order" pSelectionPolicyName
  (dedupe, dedupeLoc) <- locatedClause "dedupe" pSelectionPolicyName
  recipientLimit <- optional $ try $ do
    (limit, limitLoc) <- locatedClause "max-recipients" (fromIntegral <$> boundedDecimal)
    pure (limit, limitLoc)
  emptyPolicyLoc <- getLoc
  keyword "empty"
  _ <- symbol "=>"
  emptyPolicy <- pSelectionDisposition
  failurePolicyLoc <- getLoc
  keyword "failure"
  _ <- symbol "=>"
  failurePolicy <- pSelectionDisposition
  (redelivery, redeliveryLoc) <- locatedClause "redelivery" pSelectionPolicyName
  (partial, partialLoc) <- locatedClause "partial" pSelectionPolicyName
  pure
    RouterSelectionDecl
      { rsIdentity = identity,
        rsIdentityLoc = identityLoc,
        rsVersion = version,
        rsVersionLoc = versionLoc,
        rsQuery = query,
        rsQueryLoc = queryLoc,
        rsQueryInput = queryInput,
        rsQueryInputLoc = queryInputLoc,
        rsPredicate = predicate,
        rsRecipient = recipient,
        rsLimit = recipientLimit,
        rsOrder = order,
        rsOrderLoc = orderLoc,
        rsDedupe = dedupe,
        rsDedupeLoc = dedupeLoc,
        rsEmptyPolicy = emptyPolicy,
        rsEmptyPolicyLoc = emptyPolicyLoc,
        rsFailurePolicy = failurePolicy,
        rsFailurePolicyLoc = failurePolicyLoc,
        rsRedelivery = redelivery,
        rsRedeliveryLoc = redeliveryLoc,
        rsPartial = partial,
        rsPartialLoc = partialLoc,
        rsLoc = loc
      }

locatedClause :: Text -> P a -> P (a, Loc)
locatedClause clause parser = do
  clauseLoc <- getLoc
  keyword clause
  _ <- symbol "="
  value <- parser
  pure (value, clauseLoc)

pSelectionDisposition :: P SelectionDispositionSyntax
pSelectionDisposition =
  choice
    [ SelectionAck <$ keyword "ack",
      SelectionRetry <$ keyword "retry",
      SelectionDeadLetter <$ keyword "deadLetter",
      SelectionHalt <$ keyword "halt"
    ]

pSelectionPolicyName :: P Name
pSelectionPolicyName = T.intercalate "-" <$> ((:) <$> ident <*> many (symbol "-" *> ident))

pRouterDispatch :: P RouterDispatchNode
pRouterDispatch = do
  loc <- getLoc
  keyword "dispatch-each"
  command <- ident
  fields <- braces (many pFieldBinding)
  disposition <-
    DispatchDisposition
      <$> (keyword "on-appended" *> pDisp)
      <*> (symbol ";" *> keyword "on-duplicate" *> pDisp)
      <*> (symbol ";" *> keyword "on-failed" *> pDisp)
  pure RouterDispatchNode {rdCommand = command, rdFields = fields, rdDisposition = disposition, rdLoc = loc}

-- | @dispatch-id strategy=uuidv5 from=(…)@ where the tuple is fixed by the
-- runtime that derives the id. The line documents a derivation the spec cannot
-- change, so the only sound thing to accept is the exact spelling that is true.
pFixedDispatchIdLine :: [Text] -> P ()
pFixedDispatchIdLine inputs = do
  keyword "dispatch-id"
  _ <- symbol "strategy" *> symbol "=" *> keyword "uuidv5"
  _ <- symbol "from" *> symbol "=" *> parens (sequence_ (intersperse (() <$ symbol ",") (map keyword inputs)))
  pure ()

-- | @Keiro.Router.deterministicRouterCommandId@ keys on the router name, the
-- correlation key, the source event, the resolved target stream, and the
-- same-stream occurrence.
pRouterDispatchIdLine :: P ()
pRouterDispatchIdLine =
  pFixedDispatchIdLine ["name", "key", "sourceEventId", "targetStreamName", "occurrence"]

pPolicyLine :: Text -> P PolicyChoice
pPolicyLine clause = keyword clause *> symbol "=>" *> pPolicyChoice

pPolicyChoice :: P PolicyChoice
pPolicyChoice =
  choice
    [ PolHalt <$ keyword "halt",
      PolDeadLetter <$ keyword "deadLetter",
      PolSkip <$ keyword "skip"
    ]

pInputDecl :: P InputDecl
pInputDecl = do
  loc <- getLoc
  keyword "input"
  nm <- ident
  fs <- braces (many pField)
  pure InputDecl {inName = nm, inFields = fs, inType = Nothing, inLoc = loc}

pRouterInputDecl :: FrontendContext -> P (InputDecl, Maybe SourceSpan)
pRouterInputDecl context = do
  loc <- getLoc
  keyword "input"
  name <- ident
  choice
    [ do
        marker <- withOwnedSpan (symbol ":")
        inputType <- pMappedTypeExpr context
        pure (InputDecl {inName = name, inFields = [], inType = Just inputType, inLoc = loc}, Just (spanOf marker)),
      do
        fields <- braces (many pField)
        pure (InputDecl {inName = name, inFields = fields, inType = Nothing, inLoc = loc}, Nothing)
    ]

pCorrelate :: P CorrelateDecl
pCorrelate = do
  keyword "correlate"
  _ <- keyword "input" *> symbol "."
  f <- ident
  keyword "via"
  v <- ident
  pure CorrelateDecl {corrField = f, corrVia = v}

pSaga :: P SagaRef
pSaga = do
  keyword "saga"
  agg <- ident
  keyword "category"
  categoryName <- stringLit
  pure SagaRef {sagaAgg = agg, sagaCategory = categoryName}

pHandle :: P HandleNode
pHandle = do
  keyword "on"
  onName <- ident
  adv <- pAdvance
  disps <- many pDispatch
  keyword "schedule"
  sched <- ident
  pure HandleNode {hOn = onName, hAdvance = adv, hDispatch = disps, hSchedule = sched}

pAdvance :: P AdvanceNode
pAdvance = do
  keyword "advance"
  cmd <- ident
  fs <- braces (many pFieldBinding)
  pure AdvanceNode {advCommand = cmd, advFields = fs}

pDispatch :: P DispatchNode
pDispatch = do
  loc <- getLoc
  keyword "dispatch"
  tgt <- ident
  _ <- symbol "@"
  key <- dottedRef
  cmd <- ident
  fs <- braces (many pFieldBinding)
  disp <-
    DispatchDisposition
      <$> (keyword "on-appended" *> pDisp)
      <*> (symbol ";" *> keyword "on-duplicate" *> pDisp)
      <*> (symbol ";" *> keyword "on-failed" *> pDisp)
  pure DispatchNode {dispTarget = tgt, dispKey = key, dispCommand = cmd, dispFields = fs, dispDisposition = disp, dispLoc = loc}

pDisp :: P Disp
pDisp =
  choice
    [ DAckOk <$ keyword "AckOk",
      DRetry <$ keyword "Retry",
      DDeadLetter <$> (keyword "DeadLetter" *> stringLit)
    ]

-- | A process manager's twin of 'pRouterDispatchIdLine'.
-- @Keiro.ProcessManager.deterministicCommandId@ keys on the manager name, the
-- correlation id, the source event, and the positional emit index — a different
-- fixed tuple from the router's, so the two lines are checked separately but
-- equally strictly. Before ExecPlan 199 a process accepted any strategy
-- identifier and any tuple, so `dispatch-id strategy=md5 from=(banana)` checked
-- clean here while the same line was a parse error on a router.
pDispatchIdLine :: P ()
pDispatchIdLine =
  pFixedDispatchIdLine ["name", "correlationId", "sourceEventId", "emitIndex"]

pTimerNode :: P TimerNode
pTimerNode = do
  loc <- getLoc
  keyword "timer"
  nm <- ident
  tid <- keyword "id" *> pIdExpr
  fat <- keyword "fireAt" *> pFireAt
  pay <- keyword "payload" *> braces (many pFieldBinding)
  fire <- pFire
  _ <- keyword "decode" *> keyword "unknown-status" *> symbol "=>"
  unk <- ident
  keyword "max-attempts"
  ma <- boundedDecimal
  keyword "dead-letter"
  dl <- stringLit
  pure
    TimerNode
      { tmName = nm,
        tmId = tid,
        tmFireAt = fat,
        tmPayload = pay,
        tmFire = fire,
        tmDecodeUnknown = unk,
        tmMaxAttempts = ma,
        tmDeadLetter = dl,
        tmLoc = loc
      }

pIdExpr :: P IdExpr
pIdExpr = do
  keyword "uuidv5"
  pfx <- stringLit
  _ <- symbol "<>"
  field <- ident
  pure IdExpr {ideStrategy = UuidV5Id, idePrefix = pfx, ideField = field}

pFireAt :: P FireAtExpr
pFireAt = do
  _ <- keyword "input" *> symbol "."
  f <- ident
  _ <- symbol "+"
  w <- pWindow
  pure FireAtExpr {faField = f, faWindow = w}

pFire :: P FireNode
pFire = do
  keyword "fire"
  keyword "dispatch"
  tgt <- ident
  _ <- symbol "@"
  key <- dottedRef
  cmd <- ident
  fs <- braces (many pFieldBinding)
  fid <- keyword "fired-event-id" *> pIdExpr
  disp <-
    FireDisposition
      <$> (keyword "on-ok" *> pFireOutcome)
      <*> (symbol ";" *> keyword "on-reject" *> pFireOutcome)
      <*> (symbol ";" *> keyword "on-ambiguous" *> pFireOutcome)
      <*> (symbol ";" *> keyword "on-error" *> pFireOutcome)
      <*> (symbol ";" *> keyword "not-mine" *> pFireOutcome)
  pure FireNode {fireTarget = tgt, fireKey = key, fireCommand = cmd, fireFields = fs, fireFiredEventId = fid, fireDisposition = disp}

pFireOutcome :: P FireOutcome
pFireOutcome = choice [OFired <$ keyword "Fired", ORetry <$ keyword "Retry"]

pFieldBinding :: P FieldBinding
pFieldBinding = do
  n <- ident
  v <- optional (symbol "=" *> pBindingValue)
  pure FieldBinding {fbName = n, fbValue = v}

-- | A binding value: a quoted string (kept quoted) or a dotted reference.
pBindingValue :: P Text
pBindingValue = choice [quoted, dottedRef]
  where
    quoted = do
      s <- stringLit
      pure ("\"" <> s <> "\"")

-- | A dotted/plain reference token like @input.hospitalId@, @timer.id@,
-- @correlationId@.
dottedRef :: P Text
dottedRef = lexeme $ do
  c <- asciiLetter
  cs <- many (asciiAlphaNum <|> char '_' <|> char '.')
  pure (T.pack (c : cs))

-- | A double-quoted string literal, returning raw (unescaped) inner text.
-- The surface syntax supports a closed escape set so unknown escapes remain
-- available for backward-compatible extensions.
