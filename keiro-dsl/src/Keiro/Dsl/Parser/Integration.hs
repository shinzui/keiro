-- | Contract, intake, emit, and publisher syntax.
module Keiro.Dsl.Parser.Integration
  ( pContract,
    pIntake,
    pEmit,
    pPublisher,
  )
where

import Keiro.Dsl.Grammar
import Keiro.Dsl.Parser.Core
import Text.Megaparsec

-- Integration contract (EP-4)
--------------------------------------------------------------------------------

pContract :: P ContractNode
pContract = do
  loc <- getLoc
  keyword "contract"
  nm <- ident
  _ <- symbol "{"
  keyword "schemaVersion"
  sv <- boundedDecimal
  keyword "discriminator"
  disc <- ident
  topics <- many pTopic
  events <- many pContractEvent
  _ <- symbol "}"
  pure
    ContractNode
      { ctrName = nm,
        ctrSchemaVersion = sv,
        ctrDiscriminator = disc,
        ctrTopics = topics,
        ctrEvents = events,
        ctrLoc = loc
      }
  where
    pTopic = do
      keyword "topic"
      alias <- ident
      t <- stringLit
      pure (alias, t)
    pContractEvent = do
      keyword "event"
      nm <- ident
      keyword "on"
      topicAlias <- ident
      fs <- braces (many pContractField)
      pure ContractEvent {ceName = nm, ceTopic = topicAlias, ceFields = fs}
    pContractField = do
      n <- ident
      _ <- symbol ":"
      ty <- pContractType
      _ <- optional (symbol ";")
      pure ContractField {cfName = n, cfType = ty}
    pContractType =
      choice
        [ CTypeId <$> (keyword "typeid" *> stringLit),
          CText <$ keyword "text",
          CInt <$ keyword "int"
        ]

pIntake :: P IntakeNode
pIntake = do
  loc <- getLoc
  keyword "intake"
  nm <- ident
  _ <- symbol "{"
  keyword "contract"
  ctr <- ident
  keyword "topic"
  tp <- ident
  keyword "accept"
  acc <- some ident
  binds <- many pBindRow
  keyword "dedupe"
  keyword "key"
  dk <- ident
  keyword "policy"
  dp <- ident
  persistence <-
    option InkPersistFull $
      keyword "persist"
        *> symbol "="
        *> choice
          [ InkPersistFull <$ keyword "full-envelope",
            InkPersistDedupeOnly <$ keyword "dedupe-only"
          ]
  dec <- pDecode
  disp <- pDisposition
  _ <- symbol "}"
  pure
    IntakeNode
      { inkName = nm,
        inkContract = ctr,
        inkTopic = tp,
        inkAccept = acc,
        inkBinds = binds,
        inkDedupeKey = dk,
        inkDedupePolicy = dp,
        inkPersist = persistence,
        inkDecode = dec,
        inkDisposition = disp,
        inkLoc = loc
      }
  where
    pBindRow = do
      keyword "bind"
      f <- ident
      keyword "from"
      src <- pWireSource
      req <- option False (True <$ keyword "required")
      xc <- option False (True <$ (keyword "cross-check" *> keyword "body"))
      pure BindRow {brField = f, brSource = src, brRequired = req, brCrossCheck = xc}
    pWireSource =
      choice
        [ SrcHeader <$> (keyword "header" *> stringLit),
          SrcKafkaKey <$ keyword "kafka-key",
          SrcKafkaCursor <$ keyword "kafka-cursor",
          SrcBody <$ keyword "body"
        ]
    pDecode = do
      keyword "decode"
      _ <- symbol "{"
      keyword "envelope"
      env <- pEnvelopePolicy
      keyword "body"
      strict <- (True <$ keyword "strict") <|> (False <$ keyword "lenient")
      keyword "schemaVersion"
      _ <- symbol "=="
      v <- boundedDecimal
      _ <- symbol "}"
      pure DecodeSpec {decEnvelope = env, decBodyStrict = strict, decBodySchemaVersion = v}
    pEnvelopePolicy = do
      a <- wireWord
      b <- wireWord
      pure (a <> " " <> b)
    pDisposition = do
      keyword "disposition"
      rows <- braces (many pDispositionRow)
      pure rows
    pDispositionRow = do
      loc <- getLoc
      o <- ident
      _ <- symbol "=>"
      act <- pInboxAction
      pure DispositionRow {drOutcome = o, drAction = act, drLoc = loc}
    pInboxAction =
      choice
        [ IAckOk <$ keyword "ackOk",
          IRetry <$> (keyword "retry" *> pWindow),
          IDeadLetter <$> (keyword "deadLetter" *> optional stringLit)
        ]

pEmit :: P EmitNode
pEmit = do
  loc <- getLoc
  keyword "emit"
  nm <- ident
  _ <- symbol "{"
  keyword "contract"
  ctr <- ident
  keyword "topic"
  tp <- ident
  keyword "source"
  src <- stringLit
  keyword "key"
  k <- ident
  keyword "map"
  disc <- ident
  (rows, skip) <- braces pMapRows
  keyword "messageId"
  mid <- pDerive
  keyword "idempotencyKey"
  idk <- pDerive
  _ <- symbol "}"
  pure
    EmitNode
      { emName = nm,
        emContract = ctr,
        emTopic = tp,
        emSource = src,
        emKey = k,
        emDiscriminant = disc,
        emMap = rows,
        emSkip = skip,
        emMessageId = mid,
        emIdempotencyKey = idk,
        emLoc = loc
      }
  where
    pMapRows = do
      rows <- many pMapRow
      skip <- option False (True <$ try (symbol "_" *> symbol "=>" *> keyword "skip"))
      pure (rows, skip)
    pMapRow = try $ do
      loc <- getLoc
      v <- stringLit
      _ <- symbol "=>"
      ev <- ident
      pure EmitMapRow {emrValue = v, emrEvent = ev, emrLoc = loc}
    pDerive = do
      keyword "derive"
      pfx <- optional stringLit
      keyword "hole"
      pure DeriveSpec {dsPrefix = pfx}

pPublisher :: P PublisherNode
pPublisher = do
  loc <- getLoc
  keyword "publisher"
  nm <- ident
  _ <- symbol "{"
  keyword "emit"
  em <- ident
  keyword "ordering"
  ord <- ident
  keyword "maxAttempts"
  ma <- boundedDecimal
  keyword "backoff"
  bk <- ident
  bw <- pWindow
  bm <- optional (keyword "max" *> symbol "=" *> pWindow)
  multiplier <- optional (keyword "multiplier" *> symbol "=" *> decimalText)
  keyword "outboxId"
  keyword "stable"
  keyword "from"
  obf <- ident
  _ <- symbol "}"
  pure
    PublisherNode
      { pubName = nm,
        pubEmit = em,
        pubOrdering = ord,
        pubMaxAttempts = ma,
        pubBackoff = BackoffSpec {boKind = bk, boWindow = bw, boMax = bm, boMultiplier = multiplier},
        pubOutboxField = obf,
        pubLoc = loc
      }
