{- | The scaffold engine. Given an 'Aggregate' (and a 'Context' naming the
service and output module-namespace root), it emits the __symbol-free
deterministic layer__ as @-- \@generated@ modules plus a single create-if-absent
@Holes.hs@ holding the typed holes a human or coding agent must fill.

The load-bearing invariant of this module is the __firewall__: no @Generated@
module ever contains a keiki symbolic operator (@./=@, @.==@, @.||@, @lit@,
@B.slot@, @B.requireGuard@). Those live only in the hand-owned @Holes.hs@. A
test ('Generated' text scan) enforces it.

Scope (EP-1, recorded in the plan's Decision Log): the scaffolder does /not/
emit the symbolic transducer body — that is the @buildTransducer@ hole in
@Holes.hs@, pinned by the harness. It also does not emit the read-model SQL
(the projection @apply@), which is a DB-coupled hole delegated to @codd@/the
agent; the @Generated@ Projection module emits only the deterministic
@InlineProjection@ wiring and the pure event→status mapping. The decode emitted
here is /strict/ (every field required); lenient\/optional decode is EP-4's
concern.
-}
module Keiro.Dsl.Scaffold (
    ScaffoldModule (..),
    ModuleKind (..),
    Context (..),
    scaffoldAggregate,

    -- * Internal resolution, shared with "Keiro.Dsl.Harness"
    Agg (..),
    ResolvedCtor (..),
    resolveAgg,
    FieldCat (..),
    fieldCat,
    vertexCtor,
    initialVertex,
    firstEnumCtor,
    lowerFirst,
    pascal,
    generatedBanner,
) where

import Data.Char (toLower, toUpper)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar

{- | One emitted module: its on-disk path (relative to the scaffold @--out@
directory), its full text, and whether it is overwritten every run
('Generated') or written only when absent ('HoleStub').
-}
data ScaffoldModule = ScaffoldModule
    { modulePath :: !FilePath
    , moduleText :: !Text
    , kind :: !ModuleKind
    }
    deriving stock (Eq, Show)

data ModuleKind
    = -- | @-- \@generated@; overwritten on every scaffold.
      Generated
    | -- | Hand-owned; created only when absent, never overwritten.
      HoleStub
    deriving stock (Eq, Show)

{- | The threading context: the spec's @context@ name and the chosen output
module-namespace root. Extended additively (never re-shaped) by later verticals.
-}
data Context = Context
    { contextName :: !Text
    , moduleRoot :: !Text
    }
    deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- Derived naming
--------------------------------------------------------------------------------

-- | Resolved, denormalized view of an aggregate used by every emitter.
data Agg = Agg
    { aCtxPascal :: !Text
    , aName :: !Text
    , aVertexType :: !Text
    , aIds :: ![IdDecl]
    , aEnums :: ![EnumDecl]
    , aRegs :: ![RegDecl]
    , aStates :: ![StateDecl]
    , aCommands :: ![ResolvedCtor]
    , aEvents :: ![ResolvedCtor]
    , aTransitions :: ![Transition]
    , aWire :: !WireSpec
    , aProjection :: !(Maybe ProjectionSpec)
    , aGenPrefix :: !Text
    -- ^ e.g. @Generated.HospitalCapacity.Reservation@
    , aHolePrefix :: !Text
    -- ^ e.g. @HospitalCapacity.Reservation@
    }

-- | A command or event constructor with its fully-resolved field types.
data ResolvedCtor = ResolvedCtor
    { rcName :: !Text
    , rcFields :: ![(Text, Text)]
    -- ^ (field name, resolved Haskell type)
    , rcVersion :: !Int
    -- ^ EP-2: schema version (1 for commands and unversioned events).
    , rcUpcastFrom :: !(Maybe Int)
    -- ^ EP-2: the source version this event migrates from (the upcaster step).
    }

defaultWire :: WireSpec
defaultWire = WireSpec{wireKind = "ctorName", wireFields = "camelCase", wireSchemaVersion = 1}

resolveAgg :: Context -> Spec -> Aggregate -> Agg
resolveAgg ctx spec agg =
    Agg
        { aCtxPascal = ctxPascal
        , aName = nm
        , aVertexType = vertexType
        , aIds = specIds spec
        , aEnums = specEnums spec
        , aRegs = aggRegs agg
        , aStates = aggStates agg
        , aCommands = map resolveCommand (aggCommands agg)
        , aEvents = map resolveEvent (aggEvents agg)
        , aTransitions = aggTransitions agg
        , aWire = fromMaybe defaultWire (aggWire agg)
        , aProjection = aggProjection agg
        , aGenPrefix = root <> "Generated." <> ctxPascal <> "." <> nm
        , aHolePrefix = root <> ctxPascal <> "." <> nm
        }
  where
    nm = aggName agg
    ctxPascal = pascalFromKebab (contextName ctx)
    vertexType = nm <> "Vertex"
    root = case moduleRoot ctx of r | T.null r -> ""; r -> r <> "."
    commandFieldTypes = [(cmdName c, cmdFields c) | c <- aggCommands agg]
    resolveCommand c = (mkCtor (cmdName c) (cmdFields c)){rcVersion = 1, rcUpcastFrom = Nothing}
    resolveEvent e =
        (mkCtor (evName e) (eventFields e))
            { rcVersion = evVersion e
            , rcUpcastFrom = fst <$> evUpcastFrom e
            }
      where
        eventFields ev = case evBody ev of
            EventFields fs -> fs
            EventFromCommand cn -> fromMaybe [] (lookup cn commandFieldTypes)
    mkCtor cn fs =
        ResolvedCtor
            { rcName = cn
            , rcFields = map (\f -> (fieldName f, resolveFieldType f)) fs
            , rcVersion = 1
            , rcUpcastFrom = Nothing
            }
    regTypes = [(regName r, regType r) | r <- aggRegs agg]
    idNames = map idName (specIds spec)
    enumNames = map enumName (specEnums spec)
    -- A bare field reuses a register's type if one shares its name; else it
    -- Pascal-cases to a declared id/enum/vertex; else falls back to Text.
    resolveFieldType f = case fieldType f of
        Just ty -> ty
        Nothing ->
            let nme = fieldName f
                pas = pascal nme
             in case lookup nme regTypes of
                    Just ty -> ty
                    Nothing
                        | pas `elem` idNames -> pas
                        | pas `elem` enumNames -> pas
                        | pas == vertexType -> pas
                        | otherwise -> "Text"

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

{- | Emit all modules for one aggregate. The 'Spec' is needed for the shared
id\/enum declarations.
-}
scaffoldAggregate :: Context -> Spec -> Aggregate -> [ScaffoldModule]
scaffoldAggregate ctx spec agg =
    [ genModule a "Domain" (emitDomain a)
    , genModule a "Codec" (emitCodec a)
    , genModule a "EventStream" (emitEventStream a)
    , genModule a "Projection" (emitProjection a)
    , holeModule a (emitHoles a)
    ]
  where
    a = resolveAgg ctx spec agg

genModule :: Agg -> Text -> Text -> ScaffoldModule
genModule a name body =
    ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" (aGenPrefix a) <> "/" <> name <> ".hs")
        , moduleText = body
        , kind = Generated
        }

holeModule :: Agg -> Text -> ScaffoldModule
holeModule a body =
    ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" (aHolePrefix a) <> "/" <> "Holes.hs")
        , moduleText = body
        , kind = HoleStub
        }

--------------------------------------------------------------------------------
-- Domain module
--------------------------------------------------------------------------------

emitDomain :: Agg -> Text
emitDomain a =
    nl
        [ "{-# LANGUAGE DataKinds #-}"
        , "{-# LANGUAGE DuplicateRecordFields #-}"
        , "{-# LANGUAGE OverloadedStrings #-}"
        , "{-# LANGUAGE TemplateHaskell #-}"
        , "{-# LANGUAGE TypeApplications #-}"
        , "{-# OPTIONS_GHC -Wno-unused-top-binds #-}"
        , generatedBanner
        , "module " <> aGenPrefix a <> ".Domain where"
        , ""
        , "import Data.Proxy (Proxy (..))"
        , "import Data.Text (Text)"
        , "import GHC.Generics (Generic)"
        , "import Keiki.Core (RegFile (..))"
        , "import Keiki.Generics.TH (deriveAggregateCtorsAll, deriveWireCtorsAll)"
        , ""
        , sectionsOf
            [ map emitId (aIds a)
            , map (emitEnum) (aEnums a)
            , [emitVertex a]
            , map (emitRecord) (aCommands a)
            , [emitSum (aName a <> "Command") (aCommands a)]
            , map (emitRecord) (aEvents a)
            , [emitSum (aName a <> "Event") (aEvents a)]
            , [emitRegsType a, emitInitialRegs a]
            ,
                [ "$(deriveAggregateCtorsAll ''" <> aName a <> "Command ''" <> aName a <> "Regs)"
                , ""
                , "$(deriveWireCtorsAll ''" <> aName a <> "Event)"
                ]
            ]
        ]

emitId :: IdDecl -> Text
emitId d =
    nl
        [ "newtype " <> idName d <> " = " <> idName d <> " Text"
        , "  deriving stock (Generic, Eq, Ord, Show)"
        , ""
        , lowerFirst (idName d) <> "Text :: " <> idName d <> " -> Text"
        , lowerFirst (idName d) <> "Text (" <> idName d <> " t) = t"
        ]

emitEnum :: EnumDecl -> Text
emitEnum d =
    nl
        [ "data " <> enumName d <> " = " <> T.intercalate " | " (map fst (enumCtors d))
        , "  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)"
        , ""
        , lowerFirst (enumName d) <> "Text :: " <> enumName d <> " -> Text"
        , lowerFirst (enumName d) <> "Text = \\case"
        , nl ["  " <> c <> " -> " <> tshow w | (c, w) <- enumCtors d]
        ]

emitVertex :: Agg -> Text
emitVertex a =
    nl
        [ "data " <> aVertexType a <> " = " <> T.intercalate " | " (map (vertexCtor a . stName) (aStates a))
        , "  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)"
        ]

emitRecord :: ResolvedCtor -> Text
emitRecord rc =
    nl $
        [ "data " <> rcName rc <> "Data = " <> rcName rc <> "Data"
        ]
            ++ recordFields (rcFields rc)
            ++ ["  deriving stock (Generic, Eq, Show)"]

recordFields :: [(Text, Text)] -> [Text]
recordFields [] =
    ["  {"]
        <> ["  }"]
recordFields fs =
    [ lead i <> n <> " :: !" <> ty
    | (i, (n, ty)) <- zip [(0 :: Int) ..] fs
    ]
        ++ ["  }"]
  where
    lead 0 = "  { "
    lead _ = "  , "

emitSum :: Text -> [ResolvedCtor] -> Text
emitSum tyName ctors =
    nl $
        [firstLine] ++ restLines ++ ["  deriving stock (Generic, Eq, Show)"]
  where
    arm rc = rc' rc
    rc' rc = rcName rc <> " !" <> rcName rc <> "Data"
    (firstLine, restLines) = case ctors of
        [] -> ("data " <> tyName <> " = ()", [])
        (c : cs) ->
            ( "data " <> tyName <> " = " <> arm c
            , ["  | " <> arm c2 | c2 <- cs]
            )

emitRegsType :: Agg -> Text
emitRegsType a =
    nl $
        ["type " <> aName a <> "Regs ="]
            ++ regListLines (aRegs a)

regListLines :: [RegDecl] -> [Text]
regListLines [] = ["  '[]"]
regListLines rs =
    [ lead i <> "'(" <> tshow (regName r) <> ", " <> regType r <> ")"
    | (i, r) <- zip [(0 :: Int) ..] rs
    ]
        ++ ["   ]"]
  where
    lead 0 = "  '[ "
    lead _ = "   , "

emitInitialRegs :: Agg -> Text
emitInitialRegs a =
    nl $
        [ "initial" <> aName a <> "Regs :: RegFile " <> aName a <> "Regs"
        , "initial" <> aName a <> "Regs ="
        ]
            ++ chain (aRegs a)
  where
    chain [] = ["  RNil"]
    chain rs =
        [ "  RCons (Proxy @" <> tshow (regName r) <> ") " <> regInitialValue a r <> " $"
        | r <- init rs
        ]
            ++ ["  RCons (Proxy @" <> tshow (regName lastR) <> ") " <> regInitialValue a lastR <> " RNil"]
      where
        lastR = last rs

-- | The Haskell initial value for a register, by the category of its type.
regInitialValue :: Agg -> RegDecl -> Text
regInitialValue a r
    | regType r `elem` idNames = "(" <> regType r <> " \"\")"
    | regType r == aVertexType a = vertexCtor a (regInitial r)
    | regType r == "Text" = "\"\""
    | otherwise = regInitial r
  where
    idNames = map idName (aIds a)

--------------------------------------------------------------------------------
-- Codec module
--------------------------------------------------------------------------------

emitCodec :: Agg -> Text
emitCodec a =
    nl
        [ "{-# LANGUAGE OverloadedRecordDot #-}"
        , "{-# LANGUAGE OverloadedStrings #-}"
        , generatedBanner
        , "module " <> aGenPrefix a <> ".Codec"
        , "  ( " <> lowerFirst (aName a) <> "Codec"
        , "  , parse" <> aName a <> "Event"
        , "  , encode" <> aName a <> "Event"
        , "  ) where"
        , ""
        , "import " <> aGenPrefix a <> ".Domain"
        , "import Data.Aeson (Value, object, withObject, (.:), (.=))"
        , "import Data.Aeson.Types (Parser, parseEither)"
        , "import Data.List.NonEmpty (NonEmpty (..))"
        , "import Data.Text (Text)"
        , "import qualified Data.Text as T"
        , "import Keiro.Codec (Codec (..))"
        , upcasterImport a
        , ""
        , emitEnumParsers a
        , ""
        , emitCodecValue a
        , ""
        , emitEncode a
        , ""
        , emitDecode a
        , ""
        , "mapLeftText :: Either String b -> Either Text b"
        , "mapLeftText = either (Left . T.pack) Right"
        ]

emitEnumParsers :: Agg -> Text
emitEnumParsers a = sectionsOf [[emitEnumParser e | e <- aEnums a]]

emitEnumParser :: EnumDecl -> Text
emitEnumParser d =
    nl $
        [ "parse" <> enumName d <> " :: Text -> Parser " <> enumName d
        , "parse" <> enumName d <> " = \\case"
        ]
            ++ ["  " <> tshow w <> " -> pure " <> c | (c, w) <- enumCtors d]
            ++ ["  _ -> fail " <> tshow ("unknown " <> enumName d)]

emitCodecValue :: Agg -> Text
emitCodecValue a =
    nl $
        [ lowerFirst (aName a) <> "Codec :: Codec " <> aName a <> "Event"
        , lowerFirst (aName a) <> "Codec ="
        , "  Codec"
        , "    { eventTypes = " <> eventTypesExpr
        , "    , eventType = \\case"
        ]
            ++ ["        " <> rcName e <> " {} -> " <> tshow (rcName e) | e <- aEvents a]
            ++ [ "    , schemaVersion = " <> tshow' (maxEventVersion a)
               , "    , encode = encode" <> aName a <> "Event"
               , "    , decode = parse" <> aName a <> "Event"
               , "    , upcasters = " <> upcastersExpr a
               , "    }"
               ]
  where
    eventTypesExpr = case map rcName (aEvents a) of
        [] -> "error \"no events\""
        (e : es) -> tshow e <> " :| [" <> T.intercalate ", " (map tshow es) <> "]"

-- | The codec's @schemaVersion@: the maximum declared event version (EP-2).
maxEventVersion :: Agg -> Int
maxEventVersion a = maximum (1 : map rcVersion (aEvents a))

{- | One @(sourceVersion, upcasterName)@ entry per event that declares an
@upcast from@. The upcaster name is per-event (e.g. @upcastFooV1@) and its
body is a hole in the hand-owned Holes module.
-}
upcasterEntries :: Agg -> [(Int, Text)]
upcasterEntries a =
    [ (m, "upcast" <> rcName e <> "V" <> tshow' m)
    | e <- aEvents a
    , Just m <- [rcUpcastFrom e]
    ]

upcastersExpr :: Agg -> Text
upcastersExpr a =
    "[" <> T.intercalate ", " ["(" <> tshow' m <> ", " <> fn <> ")" | (m, fn) <- upcasterEntries a] <> "]"

{- | When the codec references upcasters, it imports their (hole) definitions
from the hand-owned Holes module.
-}
upcasterImport :: Agg -> Text
upcasterImport a = case upcasterEntries a of
    [] -> ""
    es -> "import " <> aHolePrefix a <> ".Holes (" <> T.intercalate ", " (map snd es) <> ")"

emitEncode :: Agg -> Text
emitEncode a =
    nl $
        [ "encode" <> aName a <> "Event :: " <> aName a <> "Event -> Value"
        , "encode" <> aName a <> "Event = \\case"
        ]
            ++ concatMap encodeArm (aEvents a)
  where
    encodeArm e =
        [ "  " <> rcName e <> " payload ->"
        , "    object"
        ]
            ++ [ lead i <> kv
               | (i, kv) <- zip [(0 :: Int) ..] (("\"kind\" .= (" <> tshow (rcName e) <> " :: Text)") : map encodeField (rcFields e))
               ]
            ++ ["      ]"]
    lead 0 = "      [ "
    lead _ = "      , "
    encodeField (n, ty) =
        tshow n
            <> " .= "
            <> case fieldCat a ty of
                IdCat -> lowerFirst ty <> "Text payload." <> n
                EnumCat -> lowerFirst ty <> "Text payload." <> n
                _ -> "payload." <> n

emitDecode :: Agg -> Text
emitDecode a =
    nl $
        [ "parse" <> aName a <> "Event :: Value -> Either Text " <> aName a <> "Event"
        , "parse" <> aName a <> "Event = mapLeftText . parseEither (withObject " <> tshow (aName a <> "Event") <> " go)"
        , "  where"
        , "    go o = do"
        , "      kind <- o .: \"kind\" :: Parser Text"
        , "      case kind of"
        ]
            ++ concatMap decodeArm (aEvents a)
            ++ ["        _ -> fail \"unknown event kind\""]
  where
    decodeArm e =
        [ "        " <> tshow (rcName e) <> " ->"
        , "          " <> rcName e <> " <$> (" <> rcName e <> "Data" <> fieldApps (rcFields e) <> ")"
        ]
    fieldApps [] = ""
    fieldApps fs = " <$> " <> T.intercalate " <*> " (map decodeField fs)
    -- The first field uses <$> (handled above), the rest <*>. We instead build
    -- a uniform list and join; for an empty record there are no fields.
    decodeField (n, ty) = case fieldCat a ty of
        IdCat -> "(" <> ty <> " <$> o .: " <> tshow n <> ")"
        EnumCat -> "(o .: " <> tshow n <> " >>= parse" <> ty <> ")"
        _ -> "o .: " <> tshow n

--------------------------------------------------------------------------------
-- EventStream module
--------------------------------------------------------------------------------

emitEventStream :: Agg -> Text
emitEventStream a =
    nl
        [ generatedBanner
        , "module " <> aGenPrefix a <> ".EventStream"
        , "  ( " <> lowerFirst (aName a) <> "EventStream"
        , "  , " <> aName a <> "EventStream"
        , "  ) where"
        , ""
        , "import " <> aGenPrefix a <> ".Domain"
        , "import " <> aGenPrefix a <> ".Codec (" <> lowerFirst (aName a) <> "Codec)"
        , "import " <> aHolePrefix a <> ".Holes (" <> lowerFirst (aName a) <> "Transducer)"
        , "import Keiki.Core (HsPred)"
        , "import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))"
        , "import qualified Keiro.Stream as Stream"
        , ""
        , "type " <> aName a <> "EventStream ="
        , "  EventStream (HsPred " <> aName a <> "Regs " <> aName a <> "Command) " <> aName a <> "Regs " <> aVertexType a <> " " <> aName a <> "Command " <> aName a <> "Event"
        , ""
        , lowerFirst (aName a) <> "EventStream :: " <> aName a <> "EventStream"
        , lowerFirst (aName a) <> "EventStream ="
        , "  EventStream"
        , "    { transducer = " <> lowerFirst (aName a) <> "Transducer"
        , "    , initialState = " <> initialVertex a
        , "    , initialRegisters = initial" <> aName a <> "Regs"
        , "    , eventCodec = " <> lowerFirst (aName a) <> "Codec"
        , "    , resolveStreamName = Stream.streamName"
        , "    , snapshotPolicy = Never"
        , "    , stateCodec = Nothing"
        , "    }"
        ]

--------------------------------------------------------------------------------
-- Projection module
--------------------------------------------------------------------------------

emitProjection :: Agg -> Text
emitProjection a = case aProjection a of
    Nothing -> nl [generatedBanner, "module " <> aGenPrefix a <> ".Projection () where"]
    Just p ->
        nl
            [ "{-# LANGUAGE OverloadedRecordDot #-}"
            , "{-# LANGUAGE OverloadedStrings #-}"
            , generatedBanner
            , "module " <> aGenPrefix a <> ".Projection"
            , "  ( " <> lowerFirst (projTable p) <> "Projection"
            , "  , " <> lowerFirst (projTable p) <> "StatusFor"
            , "  ) where"
            , ""
            , "import " <> aGenPrefix a <> ".Domain"
            , "import " <> aHolePrefix a <> ".Holes (apply" <> pascal (projTable p) <> ")"
            , "import Data.Text (Text)"
            , "import Keiro.Projection (InlineProjection (..))"
            , ""
            , "-- The deterministic event->status mapping (hole-kind 3, /mapping/), derived"
            , "-- from the spec's status-map. The read-model SQL that consumes it lives in"
            , "-- the hand-owned Holes module (a DB-coupled hole, delegated to codd)."
            , lowerFirst (projTable p) <> "StatusFor :: " <> aName a <> "Event -> Maybe Text"
            , lowerFirst (projTable p) <> "StatusFor = \\case"
            , nl (statusArms a p)
            , ""
            , lowerFirst (projTable p) <> "Projection :: InlineProjection " <> aName a <> "Event"
            , lowerFirst (projTable p) <> "Projection ="
            , "  InlineProjection"
            , "    { name = " <> tshow (contextNameToProjName a p)
            , "    , apply = apply" <> pascal (projTable p)
            , "    }"
            ]

statusArms :: Agg -> ProjectionSpec -> [Text]
statusArms a p =
    [ "  " <> rcName e <> " {} -> " <> statusFor e
    | e <- aEvents a
    ]
        ++ ["  _ -> Nothing" | hasWildcard]
  where
    pairs = maybe [] mapPairs (projStatusMap p)
    statusFor e = case [v | (k, v) <- pairs, not (T.null k) && k `T.isSuffixOf` rcName e] of
        (v : _) -> "Just " <> tshow v
        [] -> "Nothing"
    -- A wildcard is only needed if some event is uncovered; otherwise every arm
    -- is explicit and a wildcard would be redundant (and -Wall would warn).
    hasWildcard = False

contextNameToProjName :: Agg -> ProjectionSpec -> Text
contextNameToProjName a p = contextKebab a <> "-" <> projTable p <> "-inline"

contextKebab :: Agg -> Text
contextKebab = kebabFromPascal . aCtxPascal

--------------------------------------------------------------------------------
-- Holes module (create-if-absent)
--------------------------------------------------------------------------------

emitHoles :: Agg -> Text
emitHoles a =
    nl
        [ "{-# LANGUAGE BlockArguments #-}"
        , "{-# LANGUAGE DataKinds #-}"
        , "{-# LANGUAGE OverloadedRecordDot #-}"
        , "{-# LANGUAGE QualifiedDo #-}"
        , "{-# LANGUAGE TypeApplications #-}"
        , "-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never"
        , "-- overwrites it. Fill the transducer body (and any other holes) against the"
        , "-- generated signatures, then run the harness to confirm behaviour."
        , "module " <> aHolePrefix a <> ".Holes"
        , "  ( " <> lowerFirst (aName a) <> "Transducer"
        , holeProjectionExport a
        , holeUpcasterExports a
        , "  ) where"
        , ""
        , "import " <> aGenPrefix a <> ".Domain"
        , "import Keiki.Builder ((=:))"
        , "import qualified Keiki.Builder as B"
        , "import Keiki.Core (HsPred, RegFile, SymTransducer, lit, (.==), (./=), (.||))"
        , holeUpcasterImports a
        , ""
        , "-- HOLE: the transducer body. Reproduce the structure below, replacing each"
        , "-- `-- HOLE` line with the keiki symbolic operators it describes."
        , lowerFirst (aName a) <> "Transducer"
        , "  :: SymTransducer"
        , "       (HsPred " <> aName a <> "Regs " <> aName a <> "Command)"
        , "       " <> aName a <> "Regs"
        , "       " <> aVertexType a
        , "       " <> aName a <> "Command"
        , "       " <> aName a <> "Event"
        , lowerFirst (aName a) <> "Transducer ="
        , "  B.buildTransducer " <> initialVertex a <> " initial" <> aName a <> "Regs isTerminal do"
        , nl (concatMap (fromBlock a) (groupBySource a))
        , " where"
        , "  isTerminal = \\case"
        , nl ["    " <> vertexCtor a (stName s) <> " -> True" | s <- aStates a, stTerminal s]
        , "    _ -> False"
        , holeProjectionStub a
        , holeUpcasterStubs a
        ]

-- | Export, import, and stub the per-event upcaster holes (EP-2 evolution).
holeUpcasterExports :: Agg -> Text
holeUpcasterExports a = case upcasterEntries a of
    [] -> ""
    es -> nl ["  , " <> fn | (_, fn) <- es]

holeUpcasterImports :: Agg -> Text
holeUpcasterImports a = case upcasterEntries a of
    [] -> ""
    _ -> nl ["import Data.Aeson (Value)", "import Data.Text (Text)"]

holeUpcasterStubs :: Agg -> Text
holeUpcasterStubs a = case upcasterEntries a of
    [] -> ""
    es ->
        nl $
            concat
                [ [ ""
                  , "-- HOLE upcaster: bring a " <> fn <> " payload up one version. Decide the"
                  , "-- default/derivation for any field added at the new version here."
                  , fn <> " :: Value -> Either Text Value"
                  , fn <> " _ = Left \"HOLE: upcaster not implemented\""
                  ]
                | (_, fn) <- es
                ]

holeProjectionExport :: Agg -> Text
holeProjectionExport a = case aProjection a of
    Nothing -> "  -- (no projection)"
    Just p -> "  , apply" <> pascal (projTable p)

holeProjectionStub :: Agg -> Text
holeProjectionStub a = case aProjection a of
    Nothing -> ""
    Just p ->
        nl
            [ ""
            , "-- HOLE: the read-model SQL for the projection (a DB-coupled hole; the"
            , "-- pure event->status mapping is generated as " <> lowerFirst (projTable p) <> "StatusFor)."
            , "-- Fill against your codd-managed read-model table."
            , "apply" <> pascal (projTable p) <> " :: " <> aName a <> "Event -> recorded -> txn ()"
            , "apply" <> pascal (projTable p) <> " _event _recorded = error \"HOLE: fill " <> projTable p <> " projection apply\""
            ]

-- Group transitions by source state, preserving order, for the B.from blocks.
groupBySource :: Agg -> [(Text, [Transition])]
groupBySource a = go [] (transitionsOf a)
  where
    go acc [] = reverse acc
    go acc (t : ts) =
        let src = tSource t
            (same, rest) = span ((== src) . tSource) ts
         in go ((src, t : same) : acc) rest

-- We don't keep the original Aggregate around in Agg, so reconstruct
-- transitions from a stored field. (Filled in resolveAgg via aTransitions.)
transitionsOf :: Agg -> [Transition]
transitionsOf = aTransitions

fromBlock :: Agg -> (Text, [Transition]) -> [Text]
fromBlock a (src, ts) =
    [ "    B.from " <> vertexCtor a src <> " do"
    ]
        ++ concatMap (onCmdBlock a) ts

onCmdBlock :: Agg -> Transition -> [Text]
onCmdBlock a t =
    [ "      B.onCmd inCtor" <> tCommand t <> " $ \\d -> B.do"
    ]
        ++ maybe [] (\g -> ["        -- HOLE guard: " <> renderGuard g]) (tGuard t)
        ++ ["        -- HOLE write " <> r <> " := " <> renderGuard e | (r, e) <- tWrites t]
        ++ ["        -- HOLE emit " <> ev <> " (B.emit wire" <> ev <> " ...)" | ev <- tEmits t]
        ++ ["        B.goto " <> vertexCtor a (tGoto t)]

--------------------------------------------------------------------------------
-- Field categories and shared helpers
--------------------------------------------------------------------------------

data FieldCat = IdCat | EnumCat | OtherCat

fieldCat :: Agg -> Text -> FieldCat
fieldCat a ty
    | ty `elem` map idName (aIds a) = IdCat
    | ty `elem` map enumName (aEnums a) = EnumCat
    | otherwise = OtherCat

-- | The first constructor of a declared enum, used to build sample values.
firstEnumCtor :: Agg -> Text -> Maybe Text
firstEnumCtor a ty =
    case [c | e <- aEnums a, enumName e == ty, (c, _) <- take 1 (enumCtors e)] of
        (c : _) -> Just c
        [] -> Nothing

vertexCtor :: Agg -> Text -> Text
vertexCtor a s = aName a <> s

initialVertex :: Agg -> Text
initialVertex a = case aStates a of
    (s : _) -> vertexCtor a (stName s)
    [] -> aName a <> "Init"

generatedBanner :: Text
generatedBanner = "-- @generated by keiro-dsl; do not edit. Regenerated from the .kdsl spec."

-- | Render an Expr back to source-ish text for a hole annotation.
renderGuard :: Expr -> Text
renderGuard = go (0 :: Int)
  where
    go ctx e = parenIf (prec e < ctx) (body e)
    body (EOr l r) = go 1 l <> " || " <> go 2 r
    body (EAnd l r) = go 2 l <> " && " <> go 3 r
    body (ECmp op l r) = go 4 l <> " " <> cmp op <> " " <> go 4 r
    body (EAtom (AName n)) = n
    body (EAtom (ABool True)) = "true"
    body (EAtom (ABool False)) = "false"
    prec :: Expr -> Int
    prec EOr{} = 1
    prec EAnd{} = 2
    prec ECmp{} = 3
    prec EAtom{} = 4
    parenIf True s = "(" <> s <> ")"
    parenIf False s = s
    cmp OpEq = "=="
    cmp OpNeq = "!="
    cmp OpLt = "<"
    cmp OpLe = "<="
    cmp OpGt = ">"
    cmp OpGe = ">="

--------------------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------------------

nl :: [Text] -> Text
nl = T.intercalate "\n"

-- | Join groups of declarations, blank-line-separated, dropping empties.
sectionsOf :: [[Text]] -> Text
sectionsOf = T.intercalate "\n\n" . filter (not . T.null) . map (T.intercalate "\n\n")

lowerFirst :: Text -> Text
lowerFirst t = case T.uncons t of
    Just (c, rest) -> T.cons (toLower c) rest
    Nothing -> t

pascal :: Text -> Text
pascal t = case T.uncons t of
    Just (c, rest) -> T.cons (toUpper c) rest
    Nothing -> t

pascalFromKebab :: Text -> Text
pascalFromKebab = T.concat . map pascal . T.splitOn "-"

kebabFromPascal :: Text -> Text
kebabFromPascal = T.intercalate "-" . map T.toLower . splitCamel

-- | Split CamelCase into its words (best-effort, for the projection name).
splitCamel :: Text -> [Text]
splitCamel = go . T.unpack
  where
    go [] = []
    go (c : cs) =
        let (rest, more) = break' cs
         in T.pack (c : rest) : go more
    break' [] = ([], [])
    break' (x : xs)
        | x `elem` ['A' .. 'Z'] = ([], x : xs)
        | otherwise = let (r, m) = break' xs in (x : r, m)

tshow :: Text -> Text
tshow t = T.pack (show t)

tshow' :: Int -> Text
tshow' = T.pack . show
