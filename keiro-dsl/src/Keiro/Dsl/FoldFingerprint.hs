{- | Canonical identities for the aggregate fold surface used while hydrating
event streams. The fingerprint deliberately excludes payload codecs,
projections, snapshot policy, and source locations: those inputs do not change
how an existing event log becomes aggregate state.
-}
module Keiro.Dsl.FoldFingerprint (
    aggregateFoldFingerprint,
    aggregateFoldSurface,
) where

import Data.List (find)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.PrettyPrint (renderExpr)
import Keiro.Dsl.ReadModelShape (fnv1a64)

-- | The sixteen-hex-digit identity of an aggregate's replay fold.
aggregateFoldFingerprint :: Spec -> Aggregate -> Text
aggregateFoldFingerprint spec = fnv1a64 . aggregateFoldSurface spec

{- | Canonical pre-hash text for an aggregate's replay fold.

Rules are declarations on 'Spec', not children of 'Aggregate', so the complete
spec is required. Only rules reached from transition guards and writes are
included, transitively, in declaration order.
-}
aggregateFoldSurface :: Spec -> Aggregate -> Text
aggregateFoldSurface spec aggregate =
    T.intercalate
        "\n"
        ( map stateSegment (aggStates aggregate)
            ++ map registerSegment (aggRegs aggregate)
            ++ map transitionSegment (aggTransitions aggregate)
            ++ map ruleSegment referencedRules
        )
  where
    referencedRules =
        [ rule
        | rule <- specRules spec
        , ruleName rule `Set.member` referencedRuleNames spec aggregate
        ]

stateSegment :: StateDecl -> Text
stateSegment state =
    "state:"
        <> stName state
        <> "|terminal="
        <> if stTerminal state then "true" else "false"

registerSegment :: RegDecl -> Text
registerSegment register =
    "reg:"
        <> regName register
        <> ":"
        <> regType register
        <> "="
        <> renderInitial (regInitial register)

renderInitial :: RegInitial -> Text
renderInitial (RegInitBare value) = value
renderInitial (RegInitText value) = "\"" <> escapeText value <> "\""

escapeText :: Text -> Text
escapeText = T.concatMap $ \case
    '"' -> "\\\""
    '\\' -> "\\\\"
    '\n' -> "\\n"
    '\t' -> "\\t"
    '\r' -> "\\r"
    character -> T.singleton character

transitionSegment :: Transition -> Text
transitionSegment transition =
    T.intercalate
        "|"
        [ "transition:" <> renderMode (tMode transition)
        , tSource transition
        , tCommand transition
        , "guard=" <> maybe "" renderExpr (tGuard transition)
        , "writes=" <> T.intercalate ";" (map renderWrite (tWrites transition))
        , "emits=" <> T.intercalate "," (tEmits transition)
        , "goto=" <> tGoto transition
        ]
  where
    renderWrite (registerName, expression) = registerName <> ":=" <> renderExpr expression

renderMode :: TransitionMode -> Text
renderMode TmLive = "live"
renderMode TmReplayOnly = "replay-only"

ruleSegment :: RuleDecl -> Text
ruleSegment rule =
    T.intercalate
        "|"
        [ "rule:" <> ruleName rule
        , ruleDomain rule
        , ruleCodomain rule
        , "cases=" <> T.intercalate ";" (map renderCase (ruleCases rule))
        ]
  where
    renderCase (constructorName, expression) = constructorName <> "=>" <> renderExpr expression

referencedRuleNames :: Spec -> Aggregate -> Set Name
referencedRuleNames spec aggregate = close directNames
  where
    rules = specRules spec
    directNames =
        Set.unions
            [ exprNames expression
            | transition <- aggTransitions aggregate
            , expression <- maybeToList (tGuard transition) ++ map snd (tWrites transition)
            ]
    close names =
        let expanded =
                Set.unions
                    ( names
                        : [ Set.unions (map (exprNames . snd) (ruleCases rule))
                          | name <- Set.toList names
                          , Just rule <- [find ((== name) . ruleName) rules]
                          ]
                    )
         in if expanded == names then names else close expanded

exprNames :: Expr -> Set Name
exprNames = \case
    EOr left right -> exprNames left <> exprNames right
    EAnd left right -> exprNames left <> exprNames right
    ECmp _ left right -> exprNames left <> exprNames right
    EAtom (AName name) -> Set.singleton name
    EAtom (ABool _) -> Set.empty

maybeToList :: Maybe a -> [a]
maybeToList Nothing = []
maybeToList (Just value) = [value]
