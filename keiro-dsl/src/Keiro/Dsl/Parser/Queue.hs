-- | Workqueue and pgmq-dispatch syntax.
module Keiro.Dsl.Parser.Queue
  ( pWorkqueue,
    pPgmqDispatch,
  )
where

import Keiro.Dsl.Grammar
import Keiro.Dsl.Parser.Core
import Text.Megaparsec

pWorkqueue :: P WorkqueueNode
pWorkqueue = do
  loc <- getLoc
  keyword "workqueue"
  nm <- ident
  _ <- symbol "{"
  keyword "queue"
  _ <- symbol "logical" *> symbol "="
  logical <- stringLit
  keyword "derive"
  _ <- symbol "physical" *> symbol "="
  phys <- stringLit
  _ <- symbol "dlq" *> symbol "="
  dlqName <- stringLit
  _ <- symbol "table" *> symbol "="
  tbl <- stringLit
  ordering <- option WqUnordered pOrdering
  groupKey <- optional pGroupKey
  provision <- option WqStandard pProvision
  keyword "payload"
  pn <- ident
  fields <- braces (many pWqField)
  keyword "retry"
  _ <- symbol "maxRetries" *> symbol "="
  mr <- boundedDecimal
  _ <- symbol "delay" *> symbol "="
  dl <- pWindow
  _ <- symbol "dlq" *> symbol "="
  dlqOn <- (True <$ keyword "on") <|> (False <$ keyword "off")
  keyword "disposition"
  disp <- braces (many pWqDispRow)
  _ <- symbol "}"
  pure
    WorkqueueNode
      { wqName = nm,
        wqLogical = logical,
        wqPhysical = phys,
        wqDlq = dlqName,
        wqTable = tbl,
        wqOrdering = ordering,
        wqGroupKey = groupKey,
        wqProvision = provision,
        wqPayloadName = pn,
        wqPayload = fields,
        wqMaxRetries = mr,
        wqDelay = dl,
        wqDlqOn = dlqOn,
        wqDisposition = disp,
        wqLoc = loc
      }
  where
    pOrdering = do
      _ <- symbol "ordering"
      choice
        [ WqUnordered <$ symbol "unordered",
          WqFifoThroughput <$ symbol "fifo-throughput",
          WqFifoRoundRobin <$ symbol "fifo-roundrobin"
        ]
    pGroupKey = do
      _ <- symbol "group" *> symbol "key" *> symbol "from"
      field <- ident
      _ <- symbol "via"
      via <- ident
      fixture <- optional (symbol "fixture" *> stringLit)
      pure WqGroupKey {gkField = field, gkVia = via, gkFixture = fixture}
    pProvision = do
      _ <- symbol "provision"
      choice
        [ WqStandard <$ symbol "standard",
          WqUnlogged <$ symbol "unlogged",
          do
            _ <- symbol "partitioned" *> symbol "("
            _ <- symbol "interval" *> symbol "="
            interval <- stringLit
            _ <- symbol "," *> symbol "retention" *> symbol "="
            retention <- stringLit
            _ <- symbol ")"
            pure (WqPartitioned interval retention)
        ]
    pWqField = do
      n <- ident
      _ <- symbol "->"
      w <- stringLit
      ty <- ident
      req <- option False (True <$ keyword "required")
      pure WqField {wqfName = n, wqfWire = w, wqfType = ty, wqfRequired = req}
    pWqDispRow = do
      loc <- getLoc
      o <- ident
      _ <- symbol "->"
      act <- choice [IAckOk <$ keyword "ackOk", IRetry <$> (keyword "retry" *> pWindow), IDeadLetter <$> (keyword "deadLetter" *> optional stringLit)]
      pure WqDispRow {wqdOutcome = o, wqdAction = act, wqdLoc = loc}

pPgmqDispatch :: P PgmqDispatchNode
pPgmqDispatch = do
  loc <- getLoc
  keyword "dispatch"
  nm <- ident
  _ <- symbol "{"
  keyword "source"
  _ <- symbol "readModel" *> symbol "="
  srm <- ident
  _ <- symbol "key" *> symbol "="
  sk <- ident
  keyword "fanout"
  _ <- symbol "body" *> symbol "="
  fb <- ident
  keyword "dedup"
  _ <- symbol "key" *> symbol "="
  dk <- ident
  _ <- keyword "seenIn" *> symbol "readModel" *> symbol "="
  drm <- ident
  _ <- symbol "field" *> symbol "="
  drmf <- ident
  _ <- keyword "seenIn" *> symbol "queue" *> symbol "="
  dq <- ident
  _ <- symbol "field" *> symbol "="
  dqf <- ident
  keyword "enqueue"
  _ <- symbol "to" *> symbol "="
  enq <- ident
  _ <- symbol "}"
  pure
    PgmqDispatchNode
      { pdName = nm,
        pdSourceReadModel = srm,
        pdSourceKey = sk,
        pdFanoutBody = fb,
        pdDedupKey = dk,
        pdDedupReadModel = drm,
        pdDedupReadModelField = drmf,
        pdDedupQueue = dq,
        pdDedupQueueField = dqf,
        pdEnqueueTo = enq,
        pdLoc = loc
      }
