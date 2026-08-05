-- | Process-manager, router, timer, dispatch, and correlation syntax.
module Keiro.Dsl.Parser.Coordination
  ( pProcess,
    pRouter,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.Parser.Core
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

pRouter :: P RouterNode
pRouter = do
  loc <- getLoc
  keyword "router"
  rid <- ident
  keyword "name"
  nm <- stringLit
  inp <- pInputDecl
  key <- pRouterKey
  resolved <- pResolveDecl
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

pRouterKey :: P CorrelateDecl
pRouterKey = do
  keyword "key"
  _ <- keyword "input" *> symbol "."
  field <- ident
  keyword "via"
  via <- ident
  pure CorrelateDecl {corrField = field, corrVia = via}

pResolveDecl :: P ResolveDecl
pResolveDecl = do
  loc <- getLoc
  keyword "resolve"
  keyword "stable"
  keyword "via"
  source <- choice [ResolveReadModel <$> (keyword "read-model" *> ident), ResolveHole <$ keyword "hole"]
  keyword "row"
  row <- braces (many ident)
  pure ResolveDecl {rvSource = source, rvRow = row, rvLoc = loc}

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

pRouterDispatchIdLine :: P ()
pRouterDispatchIdLine = do
  keyword "dispatch-id"
  _ <- symbol "strategy" *> symbol "=" *> keyword "uuidv5"
  _ <- symbol "from" *> symbol "=" *> parens fixedInputs
  pure ()
  where
    fixedInputs = do
      keyword "name"
      _ <- symbol ","
      keyword "key"
      _ <- symbol ","
      keyword "sourceEventId"
      _ <- symbol ","
      keyword "targetStreamName"
      _ <- symbol ","
      keyword "occurrence"

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
  keyword "input"
  nm <- ident
  fs <- braces (many pField)
  pure InputDecl {inName = nm, inFields = fs}

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

-- The dispatch-id line is a fixed, runtime-owned strategy; parse and discard.
pDispatchIdLine :: P ()
pDispatchIdLine = do
  keyword "dispatch-id"
  _ <- symbol "strategy" *> symbol "=" *> ident
  _ <- symbol "from" *> symbol "=" *> parens (sepBy dottedRef (symbol ","))
  pure ()

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
