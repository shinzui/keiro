-- | Frozen canonical encoding for persisted aggregate-fold identity.
--
-- The bytes produced here feed snapshot compatibility decisions. They may
-- change only as part of an explicit, ADR-recorded identity migration with
-- updated golden fixtures. Keep this implementation independent from the
-- presentation-oriented pretty printer so readability changes cannot move
-- persisted identity accidentally.
module Keiro.Dsl.CanonicalEncoding
  ( canonicalExpr,
    canonicalTransition,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Prettyprinter
import Prettyprinter.Render.Text (renderStrict)

-- | Canonical concrete encoding of one expression.
canonicalExpr :: Expr -> Text
canonicalExpr =
  renderStrict
    . layoutPretty LayoutOptions {layoutPageWidth = Unbounded}
    . docExpr 0

-- | Canonical concrete encoding of one transition.
canonicalTransition :: Transition -> Text
canonicalTransition =
  renderStrict
    . layoutPretty LayoutOptions {layoutPageWidth = Unbounded}
    . docTransition

docTransition :: Transition -> Doc ann
docTransition transition =
  vsep $
    [modePrefix <> pretty (tSource transition) <+> "--" <+> pretty (tCommand transition) <+> "-->"]
      ++ map (indent 2) clauses
  where
    modePrefix = case tMode transition of
      TmLive -> mempty
      TmReplayOnly -> "replay-only "
    clauses =
      ["implementation hole" | tImplementation transition == HoleImplementation]
        ++ maybe [] (\guardExpression -> ["guard" <+> docExpr 0 guardExpression]) (tGuard transition)
        ++ map (\(registerName, expression) -> "write" <+> pretty registerName <+> ":=" <+> docExpr 0 expression) (tWrites transition)
        ++ map (\eventName -> "emit" <+> pretty eventName) (tEmits transition)
        ++ ["goto" <+> pretty (tGoto transition)]

-- | @showsPrec@-style frozen expression encoding. Precedence levels are
-- @||@ = 1, @&&@ = 2, comparisons = 3, addition/subtraction = 4,
-- multiplication = 5, and atoms = 6.
docExpr :: Int -> Expr -> Doc ann
docExpr context expression = parensIf (precedence expression < context) (body expression)
  where
    body (EOr left right) = docExpr 1 left <+> "||" <+> docExpr 2 right
    body (EAnd left right) = docExpr 2 left <+> "&&" <+> docExpr 3 right
    body (ECmp operator left right) = docExpr 4 left <+> docCmp operator <+> docExpr 4 right
    body (EAdd _ left right) = docExpr 4 left <+> "+" <+> docExpr 5 right
    body (ESubtract _ left right) = docExpr 4 left <+> "-" <+> docExpr 5 right
    body (EMultiply _ left right) = docExpr 5 left <+> "*" <+> docExpr 6 right
    body (EPath _ root path) = docPath root path
    body (ELiteral _ literal) = docLiteral literal
    body (EAtom atom) = docAtom atom

precedence :: Expr -> Int
precedence EOr {} = 1
precedence EAnd {} = 2
precedence ECmp {} = 3
precedence EAdd {} = 4
precedence ESubtract {} = 4
precedence EMultiply {} = 5
precedence EPath {} = 6
precedence ELiteral {} = 6
precedence EAtom {} = 6

docPath :: ExprRoot -> [Name] -> Doc ann
docPath UnqualifiedRoot [] = mempty
docPath UnqualifiedRoot (first : rest) = pretty first <> hcat (map (("." <>) . pretty) rest)
docPath root path = docRoot root <> hcat (map (("." <>) . pretty) path)

docRoot :: ExprRoot -> Doc ann
docRoot UnqualifiedRoot = mempty
docRoot RegisterRoot = "reg"
docRoot CommandRoot = "cmd"

docLiteral :: ScalarLiteral -> Doc ann
docLiteral (LiteralText value) = dquoted value
docLiteral (LiteralIntegral value) = pretty value
docLiteral (LiteralBool True) = "true"
docLiteral (LiteralBool False) = "false"
docLiteral (LiteralQualified typeName constructorName) = pretty typeName <> "." <> pretty constructorName
docLiteral (LiteralId typeName value) = pretty typeName <> "(" <> dquoted value <> ")"

dquoted :: Text -> Doc ann
dquoted value = "\"" <> pretty (T.concatMap escapeCharacter value) <> "\""
  where
    escapeCharacter '"' = "\\\""
    escapeCharacter '\\' = "\\\\"
    escapeCharacter '\n' = "\\n"
    escapeCharacter '\t' = "\\t"
    escapeCharacter '\r' = "\\r"
    escapeCharacter character = T.singleton character

docCmp :: CmpOp -> Doc ann
docCmp OpEq = "=="
docCmp OpNeq = "!="
docCmp OpLt = "<"
docCmp OpLe = "<="
docCmp OpGt = ">"
docCmp OpGe = ">="

docAtom :: Atom -> Doc ann
docAtom (AName name) = pretty name
docAtom (ABool True) = "true"
docAtom (ABool False) = "false"

parensIf :: Bool -> Doc ann -> Doc ann
parensIf True document = "(" <> document <> ")"
parensIf False document = document
