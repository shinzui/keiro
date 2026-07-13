{- | The megaparsec parser for the keiro DSL. Turns @.keiro@ text into the typed
'Spec' AST. The notation is keyword-driven: newlines and @#@-comments are
whitespace, structure comes from keywords (@aggregate@, @regs@, @states@,
@command@, @event@, @wire@, @projection@) and the transition arrow
@Src -- Command --> clauses@. Guards and write right-hand sides are parsed as
a typed 'Expr' (never an opaque string) so the validator can scope-check them.
-}
module Keiro.Dsl.Parser (
    ParseError,
    parseSpec,
    parseSpecText,
)
where

import Control.Monad.Combinators.Expr (Operator (..), makeExprParser)
import Data.Char (isAlpha, isAlphaNum, isAscii, isDigit, isUpper)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Keiro.Dsl.Grammar
import Text.Megaparsec hiding (ParseError)
import Text.Megaparsec.Char (char, digitChar, letterChar, space1)
import Text.Megaparsec.Char.Lexer qualified as L

-- | A rendered, line-numbered parse error, ready to print to the user.
type ParseError = Text

type P = Parsec Void Text

{- | Parse a @.keiro@ source. The 'FilePath' is used only as the source name in
diagnostics (megaparsec's line/column reporting); it need not exist on disk.
This is the canonical signature shared across all keiro-dsl plans.
-}
parseSpec :: FilePath -> Text -> Either ParseError Spec
parseSpec src input =
    case runParser (sc *> pSpec <* eof) src input of
        Left bundle -> Left (T.pack (errorBundlePretty bundle))
        Right spec -> Right spec

-- | Convenience wrapper for callers without a source name (tests, stdin).
parseSpecText :: Text -> Either ParseError Spec
parseSpecText = parseSpec "<input>"

--------------------------------------------------------------------------------
-- Lexer
--------------------------------------------------------------------------------

-- | Space consumer: spaces, newlines, and @#@ line comments are all whitespace.
sc :: P ()
sc = L.space space1 (L.skipLineComment "#") empty

lexeme :: P a -> P a
lexeme = L.lexeme sc

symbol :: Text -> P Text
symbol = L.symbol sc

{- | A reserved keyword: the literal word not followed by an identifier
character (so @goto@ matches @goto@ but not @gotoX@).
-}
keyword :: Text -> P ()
keyword w = (lexeme . try) (string' w *> notFollowedBy (identChar <|> (char '-' *> identChar)))
  where
    string' = chunk

identChar :: P Char
identChar = asciiAlphaNum <|> char '_'

asciiLetter :: P Char
asciiLetter = satisfy (\c -> isAscii c && isAlpha c)

asciiUpper :: P Char
asciiUpper = satisfy (\c -> isAscii c && isUpper c)

asciiDigit :: P Char
asciiDigit = satisfy (\c -> isAscii c && isDigit c)

asciiAlphaNum :: P Char
asciiAlphaNum = satisfy (\c -> isAscii c && isAlphaNum c)

-- | Fail with the diagnostic caret placed at a previously captured offset.
failAt :: Int -> String -> P a
failAt offset message = region (setErrorOffset offset) (fail message)

{- | Parse a decimal as an unbounded Integer, then reject values that cannot be
represented as Int. Parsing L.decimal directly at Int silently wraps.
-}
boundedDecimal :: P Int
boundedDecimal = do
    offset <- getOffset
    value <- lexeme (L.decimal :: P Integer)
    checkedDecimal offset value

checkedDecimal :: Int -> Integer -> P Int
checkedDecimal offset value
    | value > fromIntegral (maxBound :: Int) =
        failAt
            offset
            ( "decimal literal "
                <> show value
                <> " is out of range (maximum "
                <> show (maxBound :: Int)
                <> ")"
            )
    | otherwise = pure (fromIntegral value)

{- | Words that may not be used as bare identifiers, because they introduce a
different construct and would otherwise be swallowed (e.g. @aggregate@ ending
one node and beginning the next).
-}
reservedWords :: [Text]
reservedWords =
    [ "context"
    , "module"
    , "layout"
    , "prefixed"
    , "collocated"
    , "id"
    , "enum"
    , "rule"
    , "ex"
    , "aggregate"
    , "regs"
    , "states"
    , "command"
    , "event"
    , "wire"
    , "projection"
    , "guard"
    , "write"
    , "emit"
    , "goto"
    , "fields"
    , "status-map"
    , "true"
    , "false"
    , "deprecated"
    , "upcast"
    , "from"
    , "HOLE"
    , "process"
    , "dispatch"
    , -- EP-4 integration: structural keywords never used as identifiers, so a
      -- list like @accept A B C@ stops at the next block keyword.
      "intake"
    , "contract"
    , "topic"
    , "accept"
    , "bind"
    , "dedupe"
    , "decode"
    , "disposition"
    , "publisher"
    , "map"
    , -- EP-5 pgmq structural keywords.
      "workqueue"
    , "queue"
    , "payload"
    , "retry"
    , "fanout"
    , "dedup"
    , "enqueue"
    , "seenIn"
    , -- EP-6 workflow/operation: reserved so the multi-word result-type parse and
      -- node boundaries don't swallow the next block keyword.
      "workflow"
    , "operation"
    , "consistency"
    , "body"
    , "step"
    , "await"
    , "sleep"
    , "child"
    , -- EP-107 read-model structural words. Clause labels such as table and
      -- schema remain usable identifiers because their block parser consumes
      -- them with symbol-style matching.
      "readmodel"
    , "columns"
    , "feed"
    , "scope"
    , "shape"
    ]

{- | A CamelCase / snake_case identifier (no dashes): type names, register
names, command\/event\/state names, enum constructors, projection keys.
-}
ident :: P Name
ident = (lexeme . try) $ do
    c <- asciiLetter <|> char '_'
    cs <- many identChar
    let w = T.pack (c : cs)
    if w `elem` reservedWords
        then fail ("unexpected reserved word " <> T.unpack w)
        else pure w

{- | A wire-spelling token, which may contain dashes (@partial-divert@,
@hospital-capacity@). Used for the context name, id prefixes, enum wire
spellings, and status-map values.
-}
wireWord :: P Text
wireWord = lexeme $ do
    c <- asciiLetter <|> asciiDigit
    cs <- many (identChar <|> char '-')
    pure (T.pack (c : cs))

getLoc :: P Loc
getLoc = (Loc . unPos . sourceLine) <$> getSourcePos

--------------------------------------------------------------------------------
-- Top level
--------------------------------------------------------------------------------

data TopItem
    = TIId IdDecl
    | TIEnum EnumDecl
    | TIRule RuleDecl
    | TINode Node

pSpec :: P Spec
pSpec = do
    keyword "context"
    ctx <- wireWord
    mroot <- optional pModuleClause
    mlayout <- optional pLayoutClause
    items <- many pTopItem
    pure
        Spec
            { specContext = ctx
            , specModuleRoot = mroot
            , specLayout = mlayout
            , specIds = [d | TIId d <- items]
            , specEnums = [d | TIEnum d <- items]
            , specRules = [d | TIRule d <- items]
            , specNodes = [n | TINode n <- items]
            }

-- | @module Acme.Services@ — the optional namespace-prefix clause.
pModuleClause :: P Text
pModuleClause = keyword "module" *> pModulePrefix

-- | @layout (prefixed|collocated)@ — the optional placement-style clause.
pLayoutClause :: P Placement
pLayoutClause =
    keyword "layout"
        *> choice
            [ GeneratedPrefix <$ keyword "prefixed"
            , CollocatedLeaf <$ keyword "collocated"
            ]

{- | A dotted module prefix: one-or-more PascalCase segments joined by dots,
e.g. @Acme@ or @Acme.Services@.
-}
pModulePrefix :: P Text
pModulePrefix = lexeme $ do
    seg0 <- pSeg
    segs <- many (char '.' *> pSeg)
    pure (T.intercalate "." (seg0 : segs))
  where
    pSeg = do
        c <- asciiUpper
        cs <- many identChar
        pure (T.pack (c : cs))

pTopItem :: P TopItem
pTopItem =
    choice
        [ TIId <$> pIdDecl
        , TIEnum <$> pEnumDecl
        , TIRule <$> pRuleDecl
        , TINode . NProcess <$> pProcess
        , TINode . NContract <$> pContract
        , TINode . NIntake <$> pIntake
        , TINode . NEmit <$> pEmit
        , TINode . NPublisher <$> pPublisher
        , TINode . NWorkqueue <$> pWorkqueue
        , TINode . NPgmqDispatch <$> pPgmqDispatch
        , TINode . NReadModel <$> pReadModel
        , TINode . NWorkflow <$> pWorkflow
        , TINode . NOperation <$> pOperation
        , TINode . NAggregate <$> pAggregate
        ]

pIdDecl :: P IdDecl
pIdDecl = do
    loc <- getLoc
    keyword "id"
    name <- ident
    _ <- symbol "prefix"
    _ <- symbol "="
    pfx <- wireWord
    pure IdDecl{idName = name, idPrefix = pfx, idLoc = loc}

pEnumDecl :: P EnumDecl
pEnumDecl = do
    loc <- getLoc
    keyword "enum"
    name <- ident
    ctors <- braces (many pEnumCtor)
    pure EnumDecl{enumName = name, enumCtors = ctors, enumLoc = loc}
  where
    pEnumCtor = do
        c <- ident
        _ <- symbol "="
        w <- wireWord
        pure (c, w)

pRuleDecl :: P RuleDecl
pRuleDecl = do
    loc <- getLoc
    keyword "rule"
    name <- ident
    _ <- symbol ":"
    dom <- ident
    _ <- symbol "->"
    cod <- ident
    keyword "ex"
    cases <- sepBy1 pCase (symbol ";")
    pure
        RuleDecl
            { ruleName = name
            , ruleDomain = dom
            , ruleCodomain = cod
            , ruleCases = cases
            , ruleLoc = loc
            }
  where
    pCase = do
        c <- ident
        _ <- symbol "=>"
        e <- pExpr
        pure (c, e)

--------------------------------------------------------------------------------
-- Aggregate node
--------------------------------------------------------------------------------

data BodyItem
    = BICommand Command
    | BIEvent Event
    | BIWire WireSpec
    | BIProjection ProjectionSpec
    | BITransition Transition

pAggregate :: P Aggregate
pAggregate = do
    loc <- getLoc
    keyword "aggregate"
    name <- ident
    regs <- pRegsBlock
    states <- pStatesLine
    positionedItems <- many ((,) <$> getOffset <*> pBodyItem)
    let items = map snd positionedItems
        wireOffsets = [offset | (offset, BIWire _) <- positionedItems]
        projectionOffsets = [offset | (offset, BIProjection _) <- positionedItems]
    case wireOffsets of
        _ : duplicateOffset : _ ->
            failAt duplicateOffset ("duplicate wire block in aggregate " <> T.unpack name <> " (only one is allowed)")
        _ -> pure ()
    case projectionOffsets of
        _ : duplicateOffset : _ ->
            failAt duplicateOffset ("duplicate projection block in aggregate " <> T.unpack name <> " (only one is allowed)")
        _ -> pure ()
    pure
        Aggregate
            { aggName = name
            , aggRegs = regs
            , aggStates = states
            , aggCommands = [c | BICommand c <- items]
            , aggEvents = [e | BIEvent e <- items]
            , aggTransitions = [t | BITransition t <- items]
            , aggWire = listToMaybe [w | BIWire w <- items]
            , aggProjection = listToMaybe [p | BIProjection p <- items]
            , aggLoc = loc
            }
  where
    listToMaybe xs = case xs of (x : _) -> Just x; [] -> Nothing

pRegsBlock :: P [RegDecl]
pRegsBlock = do
    keyword "regs"
    many pRegDecl

pRegDecl :: P RegDecl
pRegDecl = do
    loc <- getLoc
    name <- ident
    ty <- ident
    _ <- symbol "="
    initial <- (RegInitText <$> stringLit) <|> (RegInitBare <$> (ident <|> signedDecimalText))
    pure RegDecl{regName = name, regType = ty, regInitial = initial, regLoc = loc}

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
        n <- ident
        term <- option False (True <$ symbol "!")
        notFollowedBy (symbol "--")
        pure StateDecl{stName = n, stTerminal = term, stLoc = loc}

pBodyItem :: P BodyItem
pBodyItem =
    choice
        [ BICommand <$> pCommand
        , BIEvent <$> pEvent
        , BIWire <$> pWire
        , BIProjection <$> pProjection
        , BITransition <$> pTransition
        ]

pCommand :: P Command
pCommand = do
    loc <- getLoc
    keyword "command"
    name <- ident
    fs <- braces (many pField)
    pure Command{cmdName = name, cmdFields = fs, cmdLoc = loc}

pField :: P Field
pField = do
    n <- ident
    mty <- optional (symbol ":" *> ident)
    pure Field{fieldName = n, fieldType = mty}

pEvent :: P Event
pEvent = do
    loc <- getLoc
    dep <- option False (True <$ keyword "deprecated")
    keyword "event"
    name <- ident
    ver <- option 1 pVersion
    body <-
        choice
            [ EventFromCommand <$> (symbol "=" *> keyword "fields" *> parens ident)
            , EventFields <$> braces (many pField)
            ]
    up <- optional pUpcast
    pure
        Event
            { evName = name
            , evBody = body
            , evVersion = ver
            , evUpcastFrom = up
            , evDeprecated = dep
            , evLoc = loc
            }
  where
    pUpcast = do
        keyword "upcast"
        keyword "from"
        m <- pVersion
        _ <- symbol "="
        keyword "HOLE"
        pure (m, Hole)

{- | A @vN@ schema-version token (e.g. @v2@). Fails (backtracking) on anything
that is not @v@ immediately followed by digits.
-}
pVersion :: P Int
pVersion = do
    offset <- getOffset
    value <- lexeme (try (char 'v' *> (L.decimal :: P Integer) <* notFollowedBy identChar))
    checkedDecimal offset value

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
    pure WireSpec{wireKind = k, wireFields = f, wireSchemaVersion = v}

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
            { projTable = table
            , projConsistency = cons
            , projKey = k
            , projStatusMap = sm
            , projLoc = loc
            }
  where
    pConsistency =
        choice [Strong <$ keyword "Strong", Eventual <$ keyword "Eventual"]

pStatusMap :: P Mapping
pStatusMap = do
    keyword "status-map"
    partial <- option False (True <$ keyword "partial")
    pairs <- braces (many pPair)
    pure Mapping{mapPairs = pairs, mapPartial = partial}
  where
    pPair = do
        l <- ident
        _ <- symbol "=>"
        r <- wireWord
        pure (l, r)

--------------------------------------------------------------------------------
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
            { ctrName = nm
            , ctrSchemaVersion = sv
            , ctrDiscriminator = disc
            , ctrTopics = topics
            , ctrEvents = events
            , ctrLoc = loc
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
        pure ContractEvent{ceName = nm, ceTopic = topicAlias, ceFields = fs}
    pContractField = do
        n <- ident
        _ <- symbol ":"
        ty <- pContractType
        _ <- optional (symbol ";")
        pure ContractField{cfName = n, cfType = ty}
    pContractType =
        choice
            [ CTypeId <$> (keyword "typeid" *> stringLit)
            , CText <$ keyword "text"
            , CInt <$ keyword "int"
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
    dec <- pDecode
    disp <- pDisposition
    _ <- symbol "}"
    pure
        IntakeNode
            { inkName = nm
            , inkContract = ctr
            , inkTopic = tp
            , inkAccept = acc
            , inkBinds = binds
            , inkDedupeKey = dk
            , inkDedupePolicy = dp
            , inkDecode = dec
            , inkDisposition = disp
            , inkLoc = loc
            }
  where
    pBindRow = do
        keyword "bind"
        f <- ident
        keyword "from"
        src <- pWireSource
        req <- option False (True <$ keyword "required")
        xc <- option False (True <$ (keyword "cross-check" *> keyword "body"))
        pure BindRow{brField = f, brSource = src, brRequired = req, brCrossCheck = xc}
    pWireSource =
        choice
            [ SrcHeader <$> (keyword "header" *> stringLit)
            , SrcKafkaKey <$ keyword "kafka-key"
            , SrcKafkaCursor <$ keyword "kafka-cursor"
            , SrcBody <$ keyword "body"
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
        pure DecodeSpec{decEnvelope = env, decBodyStrict = strict, decBodySchemaVersion = v}
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
        pure DispositionRow{drOutcome = o, drAction = act, drLoc = loc}
    pInboxAction =
        choice
            [ IAckOk <$ keyword "ackOk"
            , IRetry <$> (keyword "retry" *> pWindow)
            , IDeadLetter <$> (keyword "deadLetter" *> optional stringLit)
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
            { emName = nm
            , emContract = ctr
            , emTopic = tp
            , emSource = src
            , emKey = k
            , emDiscriminant = disc
            , emMap = rows
            , emSkip = skip
            , emMessageId = mid
            , emIdempotencyKey = idk
            , emLoc = loc
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
        pure EmitMapRow{emrValue = v, emrEvent = ev, emrLoc = loc}
    pDerive = do
        keyword "derive"
        pfx <- optional stringLit
        keyword "hole"
        pure DeriveSpec{dsPrefix = pfx}

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
            { pubName = nm
            , pubEmit = em
            , pubOrdering = ord
            , pubMaxAttempts = ma
            , pubBackoff = BackoffSpec{boKind = bk, boWindow = bw, boMax = bm, boMultiplier = multiplier}
            , pubOutboxField = obf
            , pubLoc = loc
            }

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
            { wqName = nm
            , wqLogical = logical
            , wqPhysical = phys
            , wqDlq = dlqName
            , wqTable = tbl
            , wqPayloadName = pn
            , wqPayload = fields
            , wqMaxRetries = mr
            , wqDelay = dl
            , wqDlqOn = dlqOn
            , wqDisposition = disp
            , wqLoc = loc
            }
  where
    pWqField = do
        n <- ident
        _ <- symbol "->"
        w <- stringLit
        ty <- ident
        req <- option False (True <$ keyword "required")
        pure WqField{wqfName = n, wqfWire = w, wqfType = ty, wqfRequired = req}
    pWqDispRow = do
        loc <- getLoc
        o <- ident
        _ <- symbol "->"
        act <- choice [IAckOk <$ keyword "ackOk", IRetry <$> (keyword "retry" *> pWindow), IDeadLetter <$> (keyword "deadLetter" *> optional stringLit)]
        pure WqDispRow{wqdOutcome = o, wqdAction = act, wqdLoc = loc}

pReadModel :: P ReadModelNode
pReadModel = do
    loc <- getLoc
    keyword "readmodel"
    name <- ident
    _ <- symbol "{"
    _ <- symbol "table" *> symbol "="
    table <- stringLit
    _ <- symbol "schema" *> symbol "="
    schema <- stringLit
    _ <- symbol "columns"
    columns <- braces (many pColumn)
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
    _ <- symbol "}"
    pure
        ReadModelNode
            { rmName = name
            , rmTable = table
            , rmSchema = schema
            , rmColumns = columns
            , rmVersion = version
            , rmShape = shape
            , rmConsistency = consistency
            , rmScope = scope
            , rmFeed = feed
            , rmSubscription = subscription
            , rmLoc = loc
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
            [ RmEntireLog <$ keyword "entire-log"
            , RmCategory <$> (keyword "category" *> stringLit)
            ]
    pFeed = choice [RmInline <$ keyword "inline", RmSubscription <$ keyword "subscription"]

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
            { pdName = nm
            , pdSourceReadModel = srm
            , pdSourceKey = sk
            , pdFanoutBody = fb
            , pdDedupKey = dk
            , pdDedupReadModel = drm
            , pdDedupReadModelField = drmf
            , pdDedupQueue = dq
            , pdDedupQueueField = dqf
            , pdEnqueueTo = enq
            , pdLoc = loc
            }

pWorkflow :: P WorkflowNode
pWorkflow = do
    loc <- getLoc
    keyword "workflow"
    wid <- ident
    keyword "name"
    nm <- stringLit
    keyword "in"
    inTy <- ident
    inFields <- option [] (braces (many pField))
    keyword "out"
    outTy <- ident
    keyword "id"
    keyword "from"
    keyword "input"
    idField <- optional (symbol "." *> ident)
    keyword "via"
    idVia <- ident
    keyword "body"
    body <- many pWfBodyItem
    pure
        WorkflowNode
            { wfId = wid
            , wfStable = nm
            , wfInput = inTy
            , wfInputFields = inFields
            , wfOutput = outTy
            , wfIdField = idField
            , wfIdVia = idVia
            , wfBody = body
            , wfLoc = loc
            }
  where
    pWfBodyItem =
        choice
            [ do
                loc <- getLoc
                WfStep <$> (keyword "step" *> wireWord) <*> (symbol "->" *> ident) <*> pure loc
            , do
                loc <- getLoc
                WfAwait <$> (keyword "await" *> wireWord) <*> (symbol "->" *> ident) <*> pure loc
            , do
                loc <- getLoc
                WfSleep <$> (keyword "sleep" *> wireWord) <*> (keyword "after" *> ident) <*> pure loc
            , do
                loc <- getLoc
                WfChild
                    <$> (keyword "child" *> wireWord)
                    <*> (keyword "id" *> keyword "input" *> keyword "via" *> ident)
                    <*> (symbol "->" *> ident)
                    <*> pure loc
            ]

pOperation :: P OperationNode
pOperation = do
    loc <- getLoc
    keyword "operation"
    nm <- ident
    shape <-
        choice
            [ pCommandOp
            , pQueryOp
            , pSignalOp
            , pRunOp
            ]
    pure OperationNode{opName = nm, opShape = shape, opLoc = loc}
  where
    pCommandOp = do
        keyword "command"
        keyword "on"
        agg <- ident
        _ <- keyword "stream" *> keyword "from"
        sf <- ident
        keyword "via"
        sv <- ident
        proj <- option [] (keyword "project" *> brackets (many ident))
        pure (CommandOp agg sf sv proj)
    pQueryOp = do
        keyword "query"
        rm <- ident
        keyword "input"
        inp <- ident
        keyword "result"
        res <- pTypeExpr
        cons <- option "Strong" (keyword "consistency" *> ident)
        pure (QueryOp rm inp res cons)
    pSignalOp = do
        keyword "signal"
        lbl <- wireWord
        keyword "of"
        wf <- ident
        _ <- keyword "key" *> keyword "from"
        kf <- ident
        keyword "via"
        kv <- ident
        keyword "value"
        val <- ident
        pure (SignalOp lbl wf kf kv val)
    pRunOp = do
        keyword "run"
        wf <- ident
        keyword "input"
        inp <- ident
        _ <- keyword "outcome" *> symbol "->"
        oc <- ident
        pure (RunOp wf inp oc)
    -- A result type expression, possibly multi-word like @Maybe TransferDecision@.
    pTypeExpr = do
        ws <- some ident
        pure (T.unwords ws)

--------------------------------------------------------------------------------
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
    timer <- pTimerNode
    pure
        ProcessNode
            { procId = pid
            , procName = nm
            , procInput = inp
            , procCorrelate = corr
            , procSaga = saga
            , procTarget = tgt
            , procProjections = projs
            , procHandle = handle
            , procTimer = timer
            , procLoc = loc
            }

pInputDecl :: P InputDecl
pInputDecl = do
    keyword "input"
    nm <- ident
    fs <- braces (many pField)
    pure InputDecl{inName = nm, inFields = fs}

pCorrelate :: P CorrelateDecl
pCorrelate = do
    keyword "correlate"
    _ <- keyword "input" *> symbol "."
    f <- ident
    keyword "via"
    v <- ident
    pure CorrelateDecl{corrField = f, corrVia = v}

pSaga :: P SagaRef
pSaga = do
    keyword "saga"
    agg <- ident
    _ <- symbol "stream"
    _ <- symbol "="
    pfx <- stringLit
    _ <- symbol "<>"
    _ <- ident -- correlationId (fixed)
    pure SagaRef{sagaAgg = agg, sagaStreamPrefix = pfx}

pHandle :: P HandleNode
pHandle = do
    keyword "on"
    onName <- ident
    adv <- pAdvance
    disps <- many pDispatch
    keyword "schedule"
    sched <- ident
    pure HandleNode{hOn = onName, hAdvance = adv, hDispatch = disps, hSchedule = sched}

pAdvance :: P AdvanceNode
pAdvance = do
    keyword "advance"
    cmd <- ident
    fs <- braces (many pFieldBinding)
    pure AdvanceNode{advCommand = cmd, advFields = fs}

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
    pure DispatchNode{dispTarget = tgt, dispKey = key, dispCommand = cmd, dispFields = fs, dispDisposition = disp, dispLoc = loc}

pDisp :: P Disp
pDisp =
    choice
        [ DAckOk <$ keyword "AckOk"
        , DRetry <$ keyword "Retry"
        , DDeadLetter <$> (keyword "DeadLetter" *> stringLit)
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
            { tmName = nm
            , tmId = tid
            , tmFireAt = fat
            , tmPayload = pay
            , tmFire = fire
            , tmDecodeUnknown = unk
            , tmMaxAttempts = ma
            , tmDeadLetter = dl
            , tmLoc = loc
            }

pIdExpr :: P IdExpr
pIdExpr = do
    keyword "uuidv5"
    pfx <- stringLit
    _ <- symbol "<>"
    _ <- ident -- correlationId (fixed)
    pure IdExpr{ideStrategy = UuidV5Id, idePrefix = pfx}

pFireAt :: P FireAtExpr
pFireAt = do
    _ <- keyword "input" *> symbol "."
    f <- ident
    _ <- symbol "+"
    w <- pWindow
    pure FireAtExpr{faField = f, faWindow = w}

pWindow :: P Text
pWindow = lexeme $ do
    ds <- some digitChar
    u <- choice [char 's', char 'm', char 'h'] <?> "time unit: s, m, or h"
    notFollowedBy letterChar <?> "time unit: s, m, or h"
    pure (T.pack (ds <> [u]))

decimalText :: P Text
decimalText = lexeme $ do
    whole <- some digitChar
    fractional <- optional (char '.' *> some digitChar)
    pure (T.pack (whole <> maybe "" ('.' :) fractional))

signedDecimalText :: P Text
signedDecimalText = lexeme $ do
    sign <- optional (char '-')
    digits <- some digitChar
    pure (T.pack (maybe "" pure sign <> digits))

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
            <*> (symbol ";" *> keyword "on-error" *> pFireOutcome)
            <*> (symbol ";" *> keyword "not-mine" *> pFireOutcome)
    pure FireNode{fireTarget = tgt, fireKey = key, fireCommand = cmd, fireFields = fs, fireFiredEventId = fid, fireDisposition = disp}

pFireOutcome :: P FireOutcome
pFireOutcome = choice [OFired <$ keyword "Fired", ORetry <$ keyword "Retry"]

pFieldBinding :: P FieldBinding
pFieldBinding = do
    n <- ident
    v <- optional (symbol "=" *> pBindingValue)
    pure FieldBinding{fbName = n, fbValue = v}

-- | A binding value: a quoted string (kept quoted) or a dotted reference.
pBindingValue :: P Text
pBindingValue = choice [quoted, dottedRef]
  where
    quoted = do
        s <- stringLit
        pure ("\"" <> s <> "\"")

{- | A dotted/plain reference token like @input.hospitalId@, @timer.id@,
@correlationId@.
-}
dottedRef :: P Text
dottedRef = lexeme $ do
    c <- asciiLetter
    cs <- many (asciiAlphaNum <|> char '_' <|> char '.')
    pure (T.pack (c : cs))

{- | A double-quoted string literal, returning raw (unescaped) inner text.
The surface syntax supports a closed escape set so unknown escapes remain
available for backward-compatible extensions.
-}
stringLit :: P Text
stringLit = lexeme $ do
    _ <- char '"'
    s <- many strChar
    _ <- char '"'
    pure (T.pack s)
  where
    strChar =
        choice
            [ char '\\' *> escapeCode
            , char '\n' *> fail "unescaped newline in string literal (write \\n)"
            , anySingleBut '"'
            ]
    escapeCode =
        choice
            [ '"' <$ char '"'
            , '\\' <$ char '\\'
            , '\n' <$ char 'n'
            , '\t' <$ char 't'
            , '\r' <$ char 'r'
            , anySingle >>= \c -> fail ("unknown escape sequence \\" <> [c] <> " in string literal")
            ]

brackets :: P a -> P a
brackets = between (symbol "[") (symbol "]")

--------------------------------------------------------------------------------
-- Transitions
--------------------------------------------------------------------------------

data Clause
    = CGuard Expr
    | CWrite Name Expr
    | CEmit Name
    | CGoto Name

pTransition :: P Transition
pTransition = do
    startOffset <- getOffset
    loc <- getLoc
    src <- ident
    _ <- symbol "--"
    cmd <- ident
    _ <- symbol "-->"
    positionedClauses <- many ((,) <$> getOffset <*> (pClause <* optional (symbol ";")))
    let clauses = map snd positionedClauses
        gotos = [(offset, target) | (offset, CGoto target) <- positionedClauses]
        transitionName = T.unpack src <> " -- " <> T.unpack cmd
    gt <- case gotos of
        [] -> failAt startOffset ("transition " <> transitionName <> " is missing a goto clause")
        [(_, target)] -> pure target
        (_, firstTarget) : (duplicateOffset, _) : _ ->
            failAt
                duplicateOffset
                ("duplicate goto clause (transition " <> transitionName <> " already declared goto " <> T.unpack firstTarget <> ")")
    let guards = [e | CGuard e <- clauses]
    pure
        Transition
            { tSource = src
            , tCommand = cmd
            , tGuard = case guards of [] -> Nothing; es -> Just (foldr1 EAnd es)
            , tWrites = [(r, e) | CWrite r e <- clauses]
            , tEmits = [n | CEmit n <- clauses]
            , tGoto = gt
            , tLoc = loc
            }

pClause :: P Clause
pClause =
    choice
        [ CGuard <$> (keyword "guard" *> pExpr)
        , (\r e -> CWrite r e) <$> (keyword "write" *> ident) <*> (symbol ":=" *> pExpr)
        , try $ do
            keyword "emit"
            eventName <- ident
            notFollowedBy (symbol "{")
            pure (CEmit eventName)
        , CGoto <$> (keyword "goto" *> ident)
        ]

--------------------------------------------------------------------------------
-- Expr sublanguage
--------------------------------------------------------------------------------

pExpr :: P Expr
pExpr = makeExprParser pTerm operatorTable

pTerm :: P Expr
pTerm =
    choice
        [ parens pExpr
        , EAtom . ABool <$> (True <$ keyword "true" <|> False <$ keyword "false")
        , EAtom . AName <$> ident
        ]

{- | Highest precedence first: relational comparisons bind tighter than @&&@,
which binds tighter than @||@.
-}
operatorTable :: [[Operator P Expr]]
operatorTable =
    [
        [ InfixN (ECmp OpLe <$ op "<=")
        , InfixN (ECmp OpGe <$ op ">=")
        , InfixN (ECmp OpEq <$ op "==")
        , InfixN (ECmp OpNeq <$ op "!=")
        , InfixN (ECmp OpLt <$ op "<")
        , InfixN (ECmp OpGt <$ op ">")
        ]
    , [InfixL (EAnd <$ op "&&")]
    , [InfixL (EOr <$ op "||")]
    ]
  where
    op s = symbol s

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

braces :: P a -> P a
braces = between (symbol "{") (symbol "}")

parens :: P a -> P a
parens = between (symbol "(") (symbol ")")
