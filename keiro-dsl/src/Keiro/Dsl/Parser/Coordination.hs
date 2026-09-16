-- | Process-manager, router, timer, dispatch, and correlation syntax.
module Keiro.Dsl.Parser.Coordination
  ( pProcess,
    pRouter,
  )
where

import Data.List (intersperse)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Frontend.Internal (FrontendContext)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (LanguageFeature (DeclarativeRouterSelectionSyntax, ProcessReactionSyntax))
import Keiro.Dsl.Parser.Core
import Keiro.Dsl.Parser.Expression (pExpr)
import Keiro.Dsl.Parser.Mapped (pMappedTypeExpr)
import Keiro.Dsl.Source (Located (..), SourceSpan)
import Keiro.Dsl.Syntax (SurfaceElement (..))
import Text.Megaparsec
import Text.Megaparsec.Char (char)

-- Process manager + durable timer (EP-3)
--------------------------------------------------------------------------------

pProcess :: FrontendContext -> P (ProcessNode, [Located SurfaceElement])
pProcess context = do
  loc <- getLoc
  keyword "process"
  pid <- ident
  keyword "name"
  nm <- stringLit
  (processBody, corr, saga, tgt, projs, rejected, poison, reactionSpans) <- try (pReactionProcessBody context) <|> pLegacyProcessBody
  let processNode =
        ProcessNode
          { id = pid,
            name = nm,
            correlate = corr,
            saga = saga,
            target = tgt,
            projections = projs,
            body = processBody,
            rejected = rejected,
            poison = poison,
            loc = loc
          }
      elements =
        [ Located {span = sourceSpan, value = SurfaceProcessReaction pid inputName ordinal}
        | (inputName, ordinal, sourceSpan) <- reactionSpans
        ]
  pure (processNode, elements)

pLegacyProcessBody :: P (ProcessBody, CorrelateDecl, SagaRef, Name, [Name], PolicyChoice, PolicyChoice, [(Name, Int, SourceSpan)])
pLegacyProcessBody = do
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
  pure (LegacyProcessBody inp handle timer, corr, saga, tgt, projs, rejected, poison, [])

pReactionProcessBody :: FrontendContext -> P (ProcessBody, CorrelateDecl, SagaRef, Name, [Name], PolicyChoice, PolicyChoice, [(Name, Int, SourceSpan)])
pReactionProcessBody context = do
  marker <- withOwnedSpan (keyword "reactions")
  requireLanguageFeatureAt context ProcessReactionSyntax (spanOf marker)
  versionLoc <- getLoc
  keyword "version"
  reactionVersion <- fromIntegral <$> boundedDecimal
  inputs <- NE.fromList <$> some pInputDecl
  corr <- pCorrelate
  saga <- pSaga
  keyword "target"
  tgt <- ident
  projs <- keyword "projections" *> brackets (many ident)
  parsedReactions <- some (pReactionNode context)
  let reactions = NE.fromList (map fst parsedReactions)
      reactionSpans = numberReactionSpans (concatMap snd parsedReactions)
  pFixedDispatchIdLine ["name", "correlationId", "sourceEventId", "targetStreamName", "occurrence"]
  rejected <- pPolicyLine "rejected"
  poison <- pPolicyLine "poison"
  policy <- optional pTimerPolicy
  timers <- many pReactionTimerNode
  pure
    ( ReactionProcessBody
        ReactionBody
          { version = reactionVersion,
            versionLoc = versionLoc,
            inputs = inputs,
            reactions = reactions,
            timerPolicy = policy,
            timers = timers
          },
      corr,
      saga,
      tgt,
      projs,
      rejected,
      poison,
      reactionSpans
    )
  where
    numberReactionSpans raw =
      [ (inputName, length [() | (priorName, _, _) <- take index raw, priorName == inputName], sourceSpan)
      | (index, (inputName, _, sourceSpan)) <- zip [0 ..] raw
      ]

pReactionNode :: FrontendContext -> P (ReactionNode, [(Name, Int, SourceSpan)])
pReactionNode context = do
  loc <- getLoc
  keyword "on"
  inputName <- ident
  firstIsGuarded <- optional (lookAhead (keyword "when" <|> keyword "otherwise"))
  locatedArms <- case firstIsGuarded of
    Just _ -> some (withOwnedSpan (pGuardedReactionArm context))
    Nothing -> (: []) <$> withOwnedSpan pUnconditionalReactionArm
  let arms = NE.fromList [arm | Located {value = arm} <- locatedArms]
      spans = [(inputName, ordinal, spanOf arm) | (ordinal, arm) <- zip [0 ..] locatedArms]
  pure (ReactionNode {on = inputName, arms = arms, loc = loc}, spans)

pGuardedReactionArm :: FrontendContext -> P ReactionArm
pGuardedReactionArm context = do
  loc <- getLoc
  armGuard <-
    (WhenArm <$> (keyword "when" *> pExpr context))
      <|> (OtherwiseArm <$ keyword "otherwise")
  armBody <- pReactionArmBody
  pure ReactionArm {guard = armGuard, body = armBody, loc = loc}

pUnconditionalReactionArm :: P ReactionArm
pUnconditionalReactionArm = do
  loc <- getLoc
  armBody <- pReactionArmBody
  pure ReactionArm {guard = UnconditionalArm, body = armBody, loc = loc}

pReactionArmBody :: P ArmBody
pReactionArmBody =
  (NoAction <$ (keyword "no-action"))
    <|> do
      advance <- optional pAdvanceReaction
      followUps <- many pFollowUp
      case (advance, followUps) of
        (Nothing, []) -> fail "reaction arm must declare advance, a follow-up, or no-action"
        _ -> pure ArmActions {advance = advance, followUps = followUps}

pAdvanceReaction :: P AdvanceReaction
pAdvanceReaction = do
  loc <- getLoc
  keyword "advance"
  command <- ident
  fields <- braces (many pFieldBinding)
  acceptedBlock <- optional $ do
    keyword "accepted"
    acceptedFollowUps <- many pFollowUp
    silent <- optional (keyword "silent" *> keyword "no-action")
    pure (acceptedFollowUps, maybe False (const True) silent)
  pure
    AdvanceReaction
      { command = command,
        fields = fields,
        accepted = fst <$> acceptedBlock,
        silentNoAction = maybe False snd acceptedBlock,
        loc = loc
      }

pFollowUp :: P FollowUp
pFollowUp =
  choice
    [ FollowDispatch <$> try pDispatch,
      FollowSchedule <$> try pSchedule,
      do
        loc <- getLoc
        keyword "cancel"
        FollowCancel <$> ident <*> pure loc
    ]

pSchedule :: P ScheduleNode
pSchedule = do
  loc <- getLoc
  keyword "schedule"
  timer <- ident
  mode <- maybe ScheduleRearm (const ScheduleOnce) <$> optional (keyword "once")
  fireAt <- keyword "fireAt" *> pFireAt
  bindings <- braces (many pFieldBinding)
  pure ScheduleNode {timer = timer, mode = mode, fireAt = fireAt, bindings = bindings, loc = loc}

pTimerPolicy :: P TimerPolicy
pTimerPolicy = do
  loc <- getLoc
  keyword "timers"
  keyword "max-attempts"
  maxAttempts <- boundedDecimal
  keyword "dead-letter"
  deadLetter <- stringLit
  pure TimerPolicy {maxAttempts = maxAttempts, deadLetter = deadLetter, loc = loc}

pReactionTimerNode :: P ReactionTimerNode
pReactionTimerNode = do
  loc <- getLoc
  keyword "timer"
  name <- ident
  timerId <- keyword "id" *> pIdExpr
  payload <- keyword "payload" *> braces (many pPayloadField)
  fire <- pFire
  _ <- keyword "decode" *> keyword "unknown-status" *> symbol "=>"
  decodeUnknown <- ident
  pure ReactionTimerNode {name = name, id = timerId, payload = payload, fire = fire, decodeUnknown = decodeUnknown, loc = loc}

pPayloadField :: P PayloadField
pPayloadField = do
  name <- ident
  choice
    [ PayloadConstant name <$> (symbol "=" *> stringLit),
      PayloadTyped name <$> optional (symbol ":" *> ident)
    ]

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
  case (typedInputSpan, (.source) resolved) of
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
      { id = rid,
        name = nm,
        input = inp,
        key = key,
        resolve = resolved,
        target = target,
        projections = projections,
        dispatch = dispatch,
        rejected = rejected,
        poison = poison,
        loc = loc
      }

pRouterKey :: Bool -> P CorrelateDecl
pRouterKey declarative = do
  keyword "key"
  _ <- keyword "input" *> symbol "."
  field <- ident
  via <- if declarative then pure "idText" else keyword "via" *> ident
  pure CorrelateDecl {field = field, via = via}

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
  pure ResolveDecl {source = source, row = row, loc = loc}

pDeclarativeResolve :: FrontendContext -> Loc -> P ResolveDecl
pDeclarativeResolve context loc = do
  marker <- withOwnedSpan (keyword "declarative")
  requireLanguageFeatureAt context DeclarativeRouterSelectionSyntax (spanOf marker)
  selection <- braces (pRouterSelection context loc)
  pure ResolveDecl {source = ResolveDeclarative selection, row = [], loc = loc}

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
      { identity = identity,
        identityLoc = identityLoc,
        version = version,
        versionLoc = versionLoc,
        query = query,
        queryLoc = queryLoc,
        queryInput = queryInput,
        queryInputLoc = queryInputLoc,
        predicate = predicate,
        recipient = recipient,
        limit = recipientLimit,
        order = order,
        orderLoc = orderLoc,
        dedupe = dedupe,
        dedupeLoc = dedupeLoc,
        emptyPolicy = emptyPolicy,
        emptyPolicyLoc = emptyPolicyLoc,
        failurePolicy = failurePolicy,
        failurePolicyLoc = failurePolicyLoc,
        redelivery = redelivery,
        redeliveryLoc = redeliveryLoc,
        partial = partial,
        partialLoc = partialLoc,
        loc = loc
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
  pure RouterDispatchNode {command = command, fields = fields, disposition = disposition, loc = loc}

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
  pure InputDecl {name = nm, fields = fs, valueType = Nothing, loc = loc}

pRouterInputDecl :: FrontendContext -> P (InputDecl, Maybe SourceSpan)
pRouterInputDecl context = do
  loc <- getLoc
  keyword "input"
  name <- ident
  choice
    [ do
        marker <- withOwnedSpan (symbol ":")
        inputType <- pMappedTypeExpr context
        pure (InputDecl {name = name, fields = [], valueType = Just inputType, loc = loc}, Just (spanOf marker)),
      do
        fields <- braces (many pField)
        pure (InputDecl {name = name, fields = fields, valueType = Nothing, loc = loc}, Nothing)
    ]

pCorrelate :: P CorrelateDecl
pCorrelate = do
  keyword "correlate"
  _ <- keyword "input" *> symbol "."
  f <- ident
  keyword "via"
  v <- ident
  pure CorrelateDecl {field = f, via = v}

pSaga :: P SagaRef
pSaga = do
  keyword "saga"
  agg <- ident
  keyword "category"
  categoryName <- stringLit
  pure SagaRef {agg = agg, category = categoryName}

pHandle :: P HandleNode
pHandle = do
  keyword "on"
  onName <- ident
  adv <- pAdvance
  disps <- many pDispatch
  keyword "schedule"
  sched <- ident
  pure HandleNode {on = onName, advance = adv, dispatch = disps, schedule = sched}

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
  pure DispatchNode {target = tgt, key = key, command = cmd, fields = fs, disposition = disp, loc = loc}

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
      { name = nm,
        id = tid,
        fireAt = fat,
        payload = pay,
        fire = fire,
        decodeUnknown = unk,
        maxAttempts = ma,
        deadLetter = dl,
        loc = loc
      }

pIdExpr :: P IdExpr
pIdExpr = do
  keyword "uuidv5"
  pfx <- stringLit
  _ <- symbol "<>"
  field <- ident
  pure IdExpr {strategy = UuidV5Id, prefix = pfx, field = field}

pFireAt :: P FireAtExpr
pFireAt = do
  _ <- keyword "input" *> symbol "."
  f <- ident
  _ <- symbol "+"
  w <- pWindow
  pure FireAtExpr {field = f, window = w}

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
  pure FireNode {target = tgt, key = key, command = cmd, fields = fs, firedEventId = fid, disposition = disp}

pFireOutcome :: P FireOutcome
pFireOutcome = choice [OFired <$ keyword "Fired", ORetry <$ keyword "Retry"]

pFieldBinding :: P FieldBinding
pFieldBinding = do
  n <- ident
  v <- optional (symbol "=" *> pBindingValue)
  pure FieldBinding {name = n, value = v}

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
