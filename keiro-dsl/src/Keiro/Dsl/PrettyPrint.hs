{- | Pretty-printer for the keiro DSL: renders a 'Spec' back to @.kdsl@ text.
The layout need not be byte-identical to the original source (the parser
treats whitespace as insignificant), but it must round-trip:
@parseSpec (renderSpec s) == Right s@ modulo source locations. The only
subtle part is expression printing, which uses a @showsPrec@-style precedence
scheme so left-associative @&&@/@||@ and non-associative comparisons re-parse
to the identical AST.
-}
module Keiro.Dsl.PrettyPrint (
    renderSpec,
)
where

import Data.Text (Text)
import Keiro.Dsl.Grammar
import Prettyprinter
import Prettyprinter.Render.Text (renderStrict)

-- | Render a whole spec to text.
renderSpec :: Spec -> Text
renderSpec = renderStrict . layoutPretty opts . docSpec
  where
    opts = LayoutOptions{layoutPageWidth = Unbounded}

docSpec :: Spec -> Doc ann
docSpec s =
    vsep $
        ["context" <+> pretty (specContext s), mempty]
            ++ map docId (specIds s)
            ++ blankAfter (specIds s)
            ++ map docEnum (specEnums s)
            ++ blankAfter (specEnums s)
            ++ map docRule (specRules s)
            ++ blankAfter (specRules s)
            ++ map docNode (specNodes s)
  where
    blankAfter xs = if null xs then [] else [mempty]

docId :: IdDecl -> Doc ann
docId d = "id" <+> pretty (idName d) <+> ("prefix=" <> pretty (idPrefix d))

docEnum :: EnumDecl -> Doc ann
docEnum d =
    "enum" <+> pretty (enumName d) <+> braced (map ctor (enumCtors d))
  where
    ctor (c, w) = pretty c <> "=" <> pretty w

docRule :: RuleDecl -> Doc ann
docRule d =
    vsep
        [ "rule" <+> pretty (ruleName d) <+> ":" <+> pretty (ruleDomain d) <+> "->" <+> pretty (ruleCodomain d)
        , indent 2 ("ex" <+> hsep (punctuate " ;" (map cas (ruleCases d))))
        ]
  where
    cas (c, e) = pretty c <+> "=>" <+> docExpr 0 e

docNode :: Node -> Doc ann
docNode (NAggregate a) = docAggregate a
docNode (NProcess p) = docProcess p
docNode (NContract c) = docContract c

--------------------------------------------------------------------------------
-- Integration contract (EP-4)
--------------------------------------------------------------------------------

docContract :: ContractNode -> Doc ann
docContract c =
    vsep $
        [ "contract" <+> pretty (ctrName c) <+> "{"
        , indent 2 ("schemaVersion" <+> pretty (ctrSchemaVersion c))
        , indent 2 ("discriminator" <+> pretty (ctrDiscriminator c))
        ]
            ++ map (indent 2 . docTopic) (ctrTopics c)
            ++ map (indent 2 . docContractEvent) (ctrEvents c)
            ++ ["}"]
  where
    docTopic (alias, t) = "topic" <+> pretty alias <+> dquoted t
    docContractEvent e =
        vsep $
            ["event" <+> pretty (ceName e) <+> "on" <+> pretty (ceTopic e) <+> "{"]
                ++ map (indent 2 . docContractField) (ceFields e)
                ++ ["}"]
    docContractField f = pretty (cfName f) <> ":" <+> docContractType (cfType f)
    docContractType (CTypeId p) = "typeid" <+> dquoted p
    docContractType CText = "text"
    docContractType CInt = "int"

--------------------------------------------------------------------------------
-- Process + timer (EP-3)
--------------------------------------------------------------------------------

docProcess :: ProcessNode -> Doc ann
docProcess p =
    vsep
        [ "process" <+> pretty (procId p)
        , indent 2 ("name" <+> dquoted (procName p))
        , indent 2 (docInput (procInput p))
        , indent 2 (docCorrelate (procCorrelate p))
        , indent 2 (docSaga (procSaga p))
        , indent 2 ("target" <+> pretty (procTarget p))
        , indent 2 ("projections" <+> bracketed (map pretty (procProjections p)))
        , mempty
        , indent 2 (docHandle (procHandle p))
        , mempty
        , indent 2 "dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)"
        , mempty
        , indent 2 (docTimer (procTimer p))
        ]

docInput :: InputDecl -> Doc ann
docInput i = "input" <+> pretty (inName i) <+> braced (map docField (inFields i))

docCorrelate :: CorrelateDecl -> Doc ann
docCorrelate c = "correlate" <+> ("input." <> pretty (corrField c)) <+> "via" <+> pretty (corrVia c)

docSaga :: SagaRef -> Doc ann
docSaga s = "saga" <+> pretty (sagaAgg s) <+> ("stream=" <> dquoted (sagaStreamPrefix s) <+> "<>" <+> "correlationId")

docHandle :: HandleNode -> Doc ann
docHandle h =
    vsep $
        ["on" <+> pretty (hOn h)]
            ++ [indent 2 (docAdvance (hAdvance h))]
            ++ map (indent 2 . docDispatch) (hDispatch h)
            ++ [indent 2 ("schedule" <+> pretty (hSchedule h))]

docAdvance :: AdvanceNode -> Doc ann
docAdvance a = "advance" <+> pretty (advCommand a) <+> braced (map docFieldBinding (advFields a))

docDispatch :: DispatchNode -> Doc ann
docDispatch d =
    vsep
        [ "dispatch" <+> (pretty (dispTarget d) <> "@" <> pretty (dispKey d)) <+> pretty (dispCommand d) <+> braced (map docFieldBinding (dispFields d))
        , indent 2 (docDispDisposition (dispDisposition d))
        ]

docDispDisposition :: DispatchDisposition -> Doc ann
docDispDisposition x =
    "on-appended" <+> docDisp (onAppended x) <+> ";" <+> "on-duplicate" <+> docDisp (onDuplicate x) <+> ";" <+> "on-failed" <+> docDisp (onFailed x)

docDisp :: Disp -> Doc ann
docDisp DAckOk = "AckOk"
docDisp DRetry = "Retry"
docDisp (DDeadLetter r) = "DeadLetter" <+> dquoted r

docTimer :: TimerNode -> Doc ann
docTimer t =
    vsep
        [ "timer" <+> pretty (tmName t)
        , indent 2 ("id" <+> docIdExpr (tmId t))
        , indent 2 ("fireAt" <+> docFireAt (tmFireAt t))
        , indent 2 ("payload" <+> braced (map docFieldBinding (tmPayload t)))
        , indent 2 (docFire (tmFire t))
        , indent 2 ("decode unknown-status =>" <+> pretty (tmDecodeUnknown t))
        , indent 2 ("max-attempts" <+> pretty (tmMaxAttempts t) <+> "dead-letter" <+> dquoted (tmDeadLetter t))
        ]

docIdExpr :: IdExpr -> Doc ann
docIdExpr e = "uuidv5" <+> dquoted (idePrefix e) <+> "<>" <+> "correlationId"

docFireAt :: FireAtExpr -> Doc ann
docFireAt f = ("input." <> pretty (faField f)) <+> "+" <+> pretty (faWindow f)

docFire :: FireNode -> Doc ann
docFire f =
    vsep
        [ "fire dispatch" <+> (pretty (fireTarget f) <> "@" <> pretty (fireKey f)) <+> pretty (fireCommand f) <+> braced (map docFieldBinding (fireFields f))
        , indent 2 ("fired-event-id" <+> docIdExpr (fireFiredEventId f))
        , indent 2 (docFireDisposition (fireDisposition f))
        ]

docFireDisposition :: FireDisposition -> Doc ann
docFireDisposition x =
    "on-ok"
        <+> docFireOutcome (onOk x)
        <+> ";"
        <+> "on-reject"
        <+> docFireOutcome (onReject x)
        <+> ";"
        <+> "on-error"
        <+> docFireOutcome (onError x)
        <+> ";"
        <+> "not-mine"
        <+> docFireOutcome (notMine x)

docFireOutcome :: FireOutcome -> Doc ann
docFireOutcome OFired = "Fired"
docFireOutcome ORetry = "Retry"

docFieldBinding :: FieldBinding -> Doc ann
docFieldBinding b = case fbValue b of
    Nothing -> pretty (fbName b)
    Just v -> pretty (fbName b) <> "=" <> pretty v

dquoted :: Text -> Doc ann
dquoted t = "\"" <> pretty t <> "\""

bracketed :: [Doc ann] -> Doc ann
bracketed [] = "[ ]"
bracketed ds = "[" <+> hsep ds <+> "]"

docAggregate :: Aggregate -> Doc ann
docAggregate a =
    vsep $
        [ "aggregate" <+> pretty (aggName a)
        , indent 2 "regs"
        , indent 4 (vsep (map docReg (aggRegs a)))
        , indent 2 ("states" <+> hsep (map docState (aggStates a)))
        , mempty
        ]
            ++ map (indent 2 . docCommand) (aggCommands a)
            ++ blank (aggCommands a)
            ++ map (indent 2 . docEvent) (aggEvents a)
            ++ blank (aggEvents a)
            ++ map (indent 2 . docTransition) (aggTransitions a)
            ++ blank (aggTransitions a)
            ++ maybe [] (\w -> [indent 2 (docWire w)]) (aggWire a)
            ++ maybe [] (\p -> [indent 2 (docProjection p)]) (aggProjection a)
  where
    blank xs = if null xs then [] else [mempty]

docReg :: RegDecl -> Doc ann
docReg r = pretty (regName r) <+> pretty (regType r) <+> "=" <+> pretty (regInitial r)

docState :: StateDecl -> Doc ann
docState s = pretty (stName s) <> (if stTerminal s then "!" else mempty)

docCommand :: Command -> Doc ann
docCommand c = "command" <+> pretty (cmdName c) <+> braced (map docField (cmdFields c))

docField :: Field -> Doc ann
docField f = case fieldType f of
    Nothing -> pretty (fieldName f)
    Just ty -> pretty (fieldName f) <> ":" <> pretty ty

docEvent :: Event -> Doc ann
docEvent e =
    case evUpcastFrom e of
        Nothing -> line1
        Just (m, _) -> vsep [line1, indent 2 ("upcast from v" <> pretty m <+> "=" <+> "HOLE")]
  where
    kw = if evDeprecated e then "deprecated event" else "event"
    nameVer =
        pretty (evName e)
            <> (if evVersion e > 1 then " v" <> pretty (evVersion e) else mempty)
    bodyDoc = case evBody e of
        EventFromCommand cmd -> "=" <+> ("fields(" <> pretty cmd <> ")")
        EventFields fs -> braced (map docField fs)
    line1 = kw <+> nameVer <+> bodyDoc

docTransition :: Transition -> Doc ann
docTransition t =
    vsep $
        [pretty (tSource t) <+> "--" <+> pretty (tCommand t) <+> "-->"]
            ++ map (indent 2) clauses
  where
    clauses =
        maybe [] (\g -> ["guard" <+> docExpr 0 g]) (tGuard t)
            ++ map (\(r, e) -> "write" <+> pretty r <+> ":=" <+> docExpr 0 e) (tWrites t)
            ++ map (\ev -> "emit" <+> pretty ev) (tEmits t)
            ++ ["goto" <+> pretty (tGoto t)]

docWire :: WireSpec -> Doc ann
docWire w =
    "wire"
        <+> ("kind=" <> pretty (wireKind w))
        <+> ("fields=" <> pretty (wireFields w))
        <+> ("schemaVersion=" <> pretty (wireSchemaVersion w))

docProjection :: ProjectionSpec -> Doc ann
docProjection p =
    vsep $
        [ "projection"
            <+> pretty (projTable p)
            <+> ("consistency=" <> docConsistency (projConsistency p))
            <+> ("key=" <> pretty (projKey p))
        ]
            ++ maybe [] (\m -> [indent 2 ("status-map" <+> braced (map pair (mapPairs m)))]) (projStatusMap p)
  where
    pair (l, r) = pretty l <> "=>" <> pretty r

docConsistency :: Consistency -> Doc ann
docConsistency Strong = "Strong"
docConsistency Eventual = "Eventual"

{- | @showsPrec@-style expression renderer. The 'Int' is the minimum precedence
allowed without parentheses in the current context. Precedence levels:
@||@ = 1, @&&@ = 2, comparisons = 3, atoms = 4.
-}
docExpr :: Int -> Expr -> Doc ann
docExpr ctx e = parensIf (precOf e < ctx) (body e)
  where
    body (EOr l r) = docExpr 1 l <+> "||" <+> docExpr 2 r
    body (EAnd l r) = docExpr 2 l <+> "&&" <+> docExpr 3 r
    body (ECmp op l r) = docExpr 4 l <+> docCmp op <+> docExpr 4 r
    body (EAtom a) = docAtom a

precOf :: Expr -> Int
precOf EOr{} = 1
precOf EAnd{} = 2
precOf ECmp{} = 3
precOf EAtom{} = 4

docCmp :: CmpOp -> Doc ann
docCmp OpEq = "=="
docCmp OpNeq = "!="
docCmp OpLt = "<"
docCmp OpLe = "<="
docCmp OpGt = ">"
docCmp OpGe = ">="

docAtom :: Atom -> Doc ann
docAtom (AName n) = pretty n
docAtom (ABool True) = "true"
docAtom (ABool False) = "false"

parensIf :: Bool -> Doc ann -> Doc ann
parensIf True d = "(" <> d <> ")"
parensIf False d = d

-- | @{ a b c }@ with single-space separation, or @{ }@ when empty.
braced :: [Doc ann] -> Doc ann
braced [] = "{ }"
braced ds = "{" <+> hsep ds <+> "}"
