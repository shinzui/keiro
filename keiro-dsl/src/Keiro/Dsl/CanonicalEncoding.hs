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
    canonicalReactionSurface,
    canonicalDomainOutcomeTypes,
    canonicalTransitionOutcome,
    foldFingerprint128,
  )
where

import Data.Bits (shiftR, xor, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Keiro.Codec.CalendarDay (calendarDayCodecPolicyIdentity)
import Keiro.Dsl.Grammar
import Numeric (showHex)
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

-- | Frozen semantic encoding for the Language 6 reaction fingerprint. Every
-- component is UTF-8 length framed, so punctuation and non-ASCII text cannot
-- alias adjacent fields. Operator-only timer retry policy is deliberately
-- absent: it has its own diff diagnostic and is not reaction replay identity.
canonicalReactionSurface :: ReactionBody -> Text
canonicalReactionSurface reaction =
  record
    "reaction-v1"
    [ scalar (T.pack (show reaction.version)),
      list (map input (NE.toList reaction.inputs)),
      list (map reactionNode (NE.toList reaction.reactions)),
      scalar "target-keyed-source-event-occurrence-v1",
      list (map timer reaction.timers)
    ]
  where
    input value =
      record
        "input"
        [ scalar value.name,
          list [record "field" [scalar field.name, optional scalar field.valueType] | field <- value.fields],
          optional typeExpr value.valueType
        ]
    typeExpr = \case
      TText -> scalar "text"
      TInt -> scalar "int"
      TInteger -> scalar "integer"
      TBool -> scalar "bool"
      TNatural -> scalar "natural"
      TTime -> scalar "time"
      TDay -> scalar ("calendar-day:" <> calendarDayCodecPolicyIdentity)
      TJson -> scalar "json"
      TOptional value -> record "optional" [typeExpr value]
      TList value -> record "list-type" [typeExpr value]
      TMap value -> record "map-type" [typeExpr value]
      TKeyedMap key value -> record "keyed-map-type" [scalar key, typeExpr value]
      TRef name -> record "ref" [scalar name]
    reactionNode node = record "on" [scalar node.on, list (map arm (NE.toList node.arms))]
    arm value = record "arm" [armGuard value.guard, armBody value.body]
    armGuard = \case
      UnconditionalArm -> scalar "unconditional"
      WhenArm expression -> record "when" [scalar (canonicalExpr expression)]
      OtherwiseArm -> scalar "otherwise"
    armBody = \case
      NoAction -> scalar "no-action"
      ArmActions advance followUps -> record "actions" [optional advanceNode advance, list (map followUp followUps)]
    advanceNode value =
      record
        "advance"
        [ scalar value.command,
          list (map binding value.fields),
          optional (list . map followUp) value.accepted,
          bool value.silentNoAction
        ]
    followUp = \case
      FollowDispatch value -> dispatch value
      FollowSchedule value -> schedule value
      FollowCancel name _ -> record "cancel" [scalar name]
    dispatch value =
      record
        "dispatch"
        [ scalar value.target,
          scalar value.key,
          scalar value.command,
          list (map binding value.fields),
          disposition value.disposition
        ]
    disposition value =
      record
        "dispatch-disposition"
        [disp value.onAppended, disp value.onDuplicate, disp value.onFailed]
    disp = \case
      DAckOk -> scalar "ack-ok"
      DRetry -> scalar "retry"
      DDeadLetter value -> record "dead-letter" [scalar value]
    schedule value =
      record
        "schedule"
        [ scalar value.timer,
          scalar (case value.mode of ScheduleRearm -> "rearm"; ScheduleOnce -> "once"),
          fireAt value.fireAt,
          list (map binding value.bindings)
        ]
    fireAt value = record "fire-at" [scalar value.field, scalar value.window]
    binding value = record "binding" [scalar value.name, optional scalar value.value]
    timer value =
      record
        "timer"
        [ scalar value.name,
          identity value.id,
          list (map payload value.payload),
          fire value.fire,
          scalar value.decodeUnknown
        ]
    identity value = record "uuidv5" [scalar value.prefix, scalar value.field]
    payload = \case
      PayloadConstant name value -> record "payload-constant" [scalar name, scalar value]
      PayloadTyped name valueType -> record "payload-typed" [scalar name, optional scalar valueType]
    fire value =
      record
        "fire"
        [ scalar value.target,
          scalar value.key,
          scalar value.command,
          list (map binding value.fields),
          identity value.firedEventId,
          fireDisposition value.disposition
        ]
    fireDisposition value =
      record
        "fire-disposition"
        [ outcome value.onOk,
          outcome value.onReject,
          outcome value.onAmbiguous,
          outcome value.onError,
          outcome value.notMine
        ]
    outcome OFired = scalar "fired"
    outcome ORetry = scalar "retry"

    record tag values = scalar tag <> list values
    list values = scalar (T.concat values)
    optional render = maybe (scalar "none") (record "some" . pure . render)
    bool False = scalar "false"
    bool True = scalar "true"
    scalar value = T.pack (show (BS.length (Text.encodeUtf8 value))) <> ":" <> value

-- | Deterministic command-behavior identity for the aggregate-wide outcome
-- types. This is deliberately separate from 'canonicalTransition', whose bytes
-- are the frozen replay-fold surface.
canonicalDomainOutcomeTypes :: Maybe DomainOutcomeTypes -> Text
canonicalDomainOutcomeTypes Nothing = ""
canonicalDomainOutcomeTypes (Just declaration) =
  "rejection=" <> (.rejectionType) declaration <> "|no-op=" <> (.noOpType) declaration

-- | Deterministic command-behavior identity for one transition outcome. It is
-- excluded from persisted fold identity because it labels a selected edge
-- without changing that edge's state update or event word.
canonicalTransitionOutcome :: Maybe TransitionOutcome -> Text
canonicalTransitionOutcome Nothing = ""
canonicalTransitionOutcome (Just (OutcomeAccepted _)) = "accepted"
canonicalTransitionOutcome (Just (OutcomeRejected expression _)) = "rejected:" <> canonicalExpr expression
canonicalTransitionOutcome (Just (OutcomeNoOp expression _)) = "no-op:" <> canonicalExpr expression

-- | A fixed-width FNV-1a-128 digest over the frozen fold surface's UTF-8
-- bytes. The constants and octet fold are the standard values from RFC 9923;
-- multiplication is reduced modulo 2^128 explicitly so the result does not
-- depend on a machine integer width.
foldFingerprint128 :: Text -> Text
foldFingerprint128 input =
  T.justifyRight 32 '0' (T.pack (showHex digest ""))
  where
    digest = foldl' step fnvOffsetBasis128 (concatMap utf8Bytes (T.unpack input))
    step hash octet = ((hash `xor` octet) * fnvPrime128) `mod` fnvModulus128

fnvOffsetBasis128 :: Integer
fnvOffsetBasis128 = 0x6c62272e07bb014262b821756295c58d

fnvPrime128 :: Integer
fnvPrime128 = 0x0000000001000000000000000000013b

fnvModulus128 :: Integer
fnvModulus128 = 2 ^ (128 :: Int)

-- | Encode one Unicode scalar value as UTF-8 octets without coupling the
-- persisted identity implementation to a text or bytestring encoder version.
utf8Bytes :: Char -> [Integer]
utf8Bytes character
  | codePoint <= 0x7f = [byte codePoint]
  | codePoint <= 0x7ff =
      [ byte (0xc0 .|. (codePoint `shiftR` 6)),
        continuation codePoint
      ]
  | codePoint <= 0xffff =
      [ byte (0xe0 .|. (codePoint `shiftR` 12)),
        continuation (codePoint `shiftR` 6),
        continuation codePoint
      ]
  | otherwise =
      [ byte (0xf0 .|. (codePoint `shiftR` 18)),
        continuation (codePoint `shiftR` 12),
        continuation (codePoint `shiftR` 6),
        continuation codePoint
      ]
  where
    codePoint = fromEnum character
    byte = toInteger
    continuation value = byte (0x80 .|. (value .&. 0x3f))

docTransition :: Transition -> Doc ann
docTransition transition =
  vsep $
    [modePrefix <> pretty ((.source) transition) <+> "--" <+> pretty ((.command) transition) <+> "-->"]
      ++ map (indent 2) clauses
  where
    modePrefix = case (.mode) transition of
      TmLive -> mempty
      TmReplayOnly -> "replay-only "
    clauses =
      ["implementation hole" | (.implementation) transition == HoleImplementation]
        ++ maybe [] (\guardExpression -> ["guard" <+> docExpr 0 guardExpression]) ((.guard) transition)
        ++ map (\(registerName, expression) -> "write" <+> pretty registerName <+> ":=" <+> docExpr 0 expression) ((.writes) transition)
        ++ map (\eventName -> "emit" <+> pretty eventName) ((.emits) transition)
        ++ ["goto" <+> pretty ((.goto) transition)]

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
