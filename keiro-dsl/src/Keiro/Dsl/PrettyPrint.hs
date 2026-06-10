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
docEvent e = case evBody e of
    EventFromCommand cmd -> "event" <+> pretty (evName e) <+> "=" <+> ("fields(" <> pretty cmd <> ")")
    EventFields fs -> "event" <+> pretty (evName e) <+> braced (map docField fs)

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
    vsep
        [ "projection"
            <+> pretty (projTable p)
            <+> ("consistency=" <> docConsistency (projConsistency p))
            <+> ("key=" <> pretty (projKey p))
        , indent 2 ("status-map" <+> braced (map pair (mapPairs (projStatusMap p))))
        ]
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
