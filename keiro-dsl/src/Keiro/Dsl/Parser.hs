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
