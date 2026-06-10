{- | The megaparsec parser for the keiro DSL. Turns @.kdsl@ text into the typed
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
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Keiro.Dsl.Grammar
import Text.Megaparsec hiding (ParseError)
import Text.Megaparsec.Char (alphaNumChar, char, digitChar, letterChar, space1)
import Text.Megaparsec.Char.Lexer qualified as L

-- | A rendered, line-numbered parse error, ready to print to the user.
type ParseError = Text

type P = Parsec Void Text

{- | Parse a @.kdsl@ source. The 'FilePath' is used only as the source name in
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
keyword w = (lexeme . try) (string' w *> notFollowedBy identChar)
  where
    string' = chunk

identChar :: P Char
identChar = alphaNumChar <|> char '_'

{- | Words that may not be used as bare identifiers, because they introduce a
different construct and would otherwise be swallowed (e.g. @aggregate@ ending
one node and beginning the next).
-}
reservedWords :: [Text]
reservedWords =
    [ "context"
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
    ]

{- | A CamelCase / snake_case identifier (no dashes): type names, register
names, command\/event\/state names, enum constructors, projection keys.
-}
ident :: P Name
ident = (lexeme . try) $ do
    c <- letterChar <|> char '_'
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
    c <- letterChar <|> digitChar
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
    items <- many pTopItem
    pure
        Spec
            { specContext = ctx
            , specIds = [d | TIId d <- items]
            , specEnums = [d | TIEnum d <- items]
            , specRules = [d | TIRule d <- items]
            , specNodes = [n | TINode n <- items]
            }

pTopItem :: P TopItem
pTopItem =
    choice
        [ TIId <$> pIdDecl
        , TIEnum <$> pEnumDecl
        , TIRule <$> pRuleDecl
        , TINode . NProcess <$> pProcess
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
    items <- many pBodyItem
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
    many (try pRegDecl)

pRegDecl :: P RegDecl
pRegDecl = do
    loc <- getLoc
    name <- ident
    ty <- ident
    _ <- symbol "="
    initial <- ident
    pure RegDecl{regName = name, regType = ty, regInitial = initial, regLoc = loc}

pStatesLine :: P [StateDecl]
pStatesLine = do
    keyword "states"
    some pStateDecl
  where
    -- A state decl is an identifier with an optional terminal @!@. The
    -- @notFollowedBy@ lookahead stops the list before a transition whose source
    -- state would otherwise be swallowed as an extra state, e.g. when a
    -- transition directly follows the @states@ line with no command\/event
    -- between them. The @try@ backtracks so the identifier is left for
    -- 'pTransition'.
    pStateDecl = try $ do
        n <- ident
        term <- option False (True <$ symbol "!")
        notFollowedBy (symbol "--")
        pure StateDecl{stName = n, stTerminal = term}

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
pVersion = lexeme (try (char 'v' *> L.decimal <* notFollowedBy identChar))

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
    v <- lexeme L.decimal
    pure WireSpec{wireKind = k, wireFields = f, wireSchemaVersion = v}

pProjection :: P ProjectionSpec
pProjection = do
    loc <- getLoc
    keyword "projection"
    table <- ident
    _ <- symbol "consistency"
    _ <- symbol "="
    cons <- pConsistency
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
    pairs <- braces (many pPair)
    pure Mapping{mapPairs = pairs, mapPartial = False}
  where
    pPair = do
        l <- ident
        _ <- symbol "=>"
        r <- wireWord
        pure (l, r)

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
    pure DispatchNode{dispTarget = tgt, dispKey = key, dispCommand = cmd, dispFields = fs, dispDisposition = disp}

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
    ma <- lexeme L.decimal
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
    u <- some letterChar
    pure (T.pack (ds <> u))

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
    c <- letterChar
    cs <- many (alphaNumChar <|> char '_' <|> char '.')
    pure (T.pack (c : cs))

-- | A double-quoted string literal (no escapes), returning the inner text.
stringLit :: P Text
stringLit = lexeme $ do
    _ <- char '"'
    s <- many (anySingleBut '"')
    _ <- char '"'
    pure (T.pack s)

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
    loc <- getLoc
    src <- ident
    _ <- symbol "--"
    cmd <- ident
    _ <- symbol "-->"
    cs <- many (pClause <* optional (symbol ";"))
    gt <- case [n | CGoto n <- cs] of
        (n : _) -> pure n
        [] -> fail ("transition " <> T.unpack src <> " -- " <> T.unpack cmd <> " is missing a goto clause")
    let guards = [e | CGuard e <- cs]
    pure
        Transition
            { tSource = src
            , tCommand = cmd
            , tGuard = case guards of [] -> Nothing; es -> Just (foldr1 EAnd es)
            , tWrites = [(r, e) | CWrite r e <- cs]
            , tEmits = [n | CEmit n <- cs]
            , tGoto = gt
            , tLoc = loc
            }

pClause :: P Clause
pClause =
    choice
        [ CGuard <$> (keyword "guard" *> pExpr)
        , (\r e -> CWrite r e) <$> (keyword "write" *> ident) <*> (symbol ":=" *> pExpr)
        , CEmit <$> (keyword "emit" *> ident)
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
