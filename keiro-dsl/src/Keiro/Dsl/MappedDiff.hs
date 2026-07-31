{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Recursive, wire-aware differences for consumer-owned mapped types.
--
-- This module deliberately returns mapped findings rather than importing the
-- ordinary 'Change' type: 'Keiro.Dsl.Diff' owns compatibility vectors and turns
-- each complete mapped use path into the appropriate event, snapshot, or build
-- finding. Keeping that seam acyclic also makes the recursive comparison usable
-- by mutation coverage without rendering a report.
module Keiro.Dsl.MappedDiff
  ( MappedFinding (..),
    diffMapped,
    renderMappedSubject,
  )
where

import Data.List (find, nubBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.TypeGraph
import Keiro.Dsl.Validate (DiagnosticCode (..))

data MappedFinding = MappedFinding
  { mfDeclaration :: !Name,
    mfLeaf :: !Text,
    mfCode :: !DiagnosticCode,
    mfDetail :: !Text,
    mfUsePaths :: ![UsePath],
    mfOldUnknownFields :: !(Maybe UnknownFields)
  }
  deriving stock (Eq, Show)

-- | Compare valid old/new mapped graphs. A spec that cannot resolve has
-- already failed @check@; the ordinary differ therefore emits no speculative
-- mapped compatibility claim for it.
diffMapped :: Spec -> Spec -> [MappedFinding]
diffMapped oldSpec newSpec = case (resolveTypeGraph oldSpec, resolveTypeGraph newSpec) of
  (Right oldGraph, Right newGraph) ->
    concatMap (uncurry (diffDeclaration oldGraph newGraph)) matched
      ++ map (addedDeclaration newGraph) added
      ++ map (removedDeclaration oldGraph) removed
    where
      oldDeclarations = tgDeclarations oldGraph
      newDeclarations = tgDeclarations newGraph
      matched =
        [ (oldDeclaration, newDeclaration)
        | (key, newDeclaration) <- Map.toList newDeclarations,
          oldDeclaration <- maybeToList (Map.lookup key oldDeclarations)
        ]
      added =
        [ (key, declaration)
        | (key, declaration) <- Map.toList newDeclarations,
          Map.notMember key oldDeclarations
        ]
      removed =
        [ (key, declaration)
        | (key, declaration) <- Map.toList oldDeclarations,
          Map.notMember key newDeclarations
        ]
  _ -> []

renderMappedSubject :: UsePath -> Text -> Text
renderMappedSubject path leaf =
  renderUsePath path <> if T.null leaf then "" else " " <> leaf

data DeclView
  = StructuralView !StructuralDecl !ShapeView
  | OpaqueView !OpaqueDecl

data ShapeView
  = RecordView !Name !UnknownFields ![ResolvedWireField]
  | EnumView ![WireEnum]
  | UnionView !UnionEncoding ![ResolvedWireArm]

data ExprView
  = ExprText
  | ExprInt
  | ExprInteger
  | ExprBool
  | ExprNatural
  | ExprTime
  | ExprJson
  | ExprOptional !ExprView
  | ExprList !ExprView
  | ExprMap !ExprView
  | ExprRef !MappedKey
  deriving stock (Eq, Show)

declView :: ResolvedMappedDecl -> DeclView
declView =
  foldMappedDecl
    MappedDeclAlgebra
      { onStructuralDecl = \declaration shape -> StructuralView declaration (shapeView shape),
        onOpaqueDecl = OpaqueView
      }

shapeView :: ResolvedMappedShape -> ShapeView
shapeView =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = RecordView,
        onEnum = EnumView,
        onUnion = UnionView
      }

exprView :: ResolvedTypeExpr -> ExprView
exprView =
  foldTypeExpr
    TypeExprAlgebra
      { onText = ExprText,
        onInt = ExprInt,
        onInteger = ExprInteger,
        onBool = ExprBool,
        onNatural = ExprNatural,
        onTime = ExprTime,
        onJson = ExprJson,
        onOptional = ExprOptional,
        onList = ExprList,
        onMap = ExprMap,
        onRef = ExprRef
      }

diffDeclaration :: TypeGraph -> TypeGraph -> ResolvedMappedDecl -> ResolvedMappedDecl -> [MappedFinding]
diffDeclaration oldGraph newGraph oldResolved newResolved =
  case (declView oldResolved, declView newResolved) of
    (StructuralView oldDeclaration oldShape, StructuralView newDeclaration newShape) ->
      metadataDiff paths oldDeclaration newDeclaration
        ++ diffShape paths name oldShape newShape
    (OpaqueView oldDeclaration, OpaqueView newDeclaration) ->
      opaqueMetadataDiff paths oldDeclaration newDeclaration
    _ ->
      [ finding
          paths
          name
          ""
          MappedModeCrossed
          "mapped declaration crossed the structural/opaque boundary; no structural proof can establish codec parity"
      ]
  where
    name = resolvedName newResolved
    paths = pathsFor oldGraph newGraph name

metadataDiff :: [UsePath] -> StructuralDecl -> StructuralDecl -> [MappedFinding]
metadataDiff paths oldDeclaration newDeclaration =
  [ finding
      paths
      name
      "haskell"
      MappedHaskellSourceChanged
      "consumer package, module, or type changed without changing declared wire identity; recompile every affected consumer"
  | sdHaskell oldDeclaration /= sdHaskell newDeclaration
  ]
    ++ [ finding
           paths
           name
           "binding"
           MappedBindingChanged
           "binding symbol or binding-version changed; diff cannot inspect binding behavior, so run the two-law, codec, and historical-fixture conformance suite"
       | (sdBinding oldDeclaration, sdBindingVersion oldDeclaration)
           /= (sdBinding newDeclaration, sdBindingVersion newDeclaration)
       ]
    ++ [ finding
           paths
           name
           "fixtures"
           MappedFixturesChanged
           "fixture evidence symbol changed; runtime wire policy is unchanged, but the complete conformance suite must run"
       | sdFixtures oldDeclaration /= sdFixtures newDeclaration
       ]
    ++ [ finding
           paths
           name
           "initial"
           MappedInitialChanged
           "mapped initial symbol changed; new streams and snapshot fingerprints may change while historical event decoding does not"
       | sdInitial oldDeclaration /= sdInitial newDeclaration
       ]
    ++ [ finding
           paths
           name
           "canonical-type"
           MappedCanonicalTypeChanged
           "canonical type identity changed; rebuild generated projections and invalidate mapped snapshots while declared event bytes remain unchanged"
       | sdCanonical oldDeclaration /= sdCanonical newDeclaration
       ]
  where
    name = sdName newDeclaration

opaqueMetadataDiff :: [UsePath] -> OpaqueDecl -> OpaqueDecl -> [MappedFinding]
opaqueMetadataDiff paths oldDeclaration newDeclaration =
  [ finding
      paths
      name
      "haskell"
      MappedHaskellSourceChanged
      "consumer package, module, or type changed without changing the opaque codec claim; recompile every affected consumer"
  | odHaskell oldDeclaration /= odHaskell newDeclaration
  ]
    ++ [ finding
           paths
           name
           "codec"
           MappedOpaqueCodecChanged
           "opaque codec identity or version changed; Keiro cannot inspect the codec and historical payload compatibility is unproven"
       | (odCodecIdentity oldDeclaration, odCodecVersion oldDeclaration)
           /= (odCodecIdentity newDeclaration, odCodecVersion newDeclaration)
       ]
    ++ [ finding
           paths
           name
           "fixtures"
           MappedFixturesChanged
           "fixture evidence symbol changed; runtime codec identity is unchanged, but the complete conformance suite must run"
       | odFixtures oldDeclaration /= odFixtures newDeclaration
       ]
    ++ [ finding
           paths
           name
           "initial"
           MappedInitialChanged
           "mapped initial symbol changed; new streams and snapshot fingerprints may change while historical event decoding does not"
       | odInitial oldDeclaration /= odInitial newDeclaration
       ]
  where
    name = odName newDeclaration

diffShape :: [UsePath] -> Name -> ShapeView -> ShapeView -> [MappedFinding]
diffShape paths declaration oldShape newShape = case (oldShape, newShape) of
  (RecordView oldConstructor oldUnknown oldFields, RecordView newConstructor newUnknown newFields) ->
    [ finding
        paths
        declaration
        "constructor"
        MappedRecordConstructorChanged
        "record constructor changed without changing the JSON wire identity; recompile affected consumers"
    | oldConstructor /= newConstructor
    ]
      ++ [ finding
             paths
             declaration
             "unknown-fields"
             MappedUnionEncodingChanged
             "record unknown-fields policy changed; historical and mixed-version decoding posture is no longer the same"
         | oldUnknown /= newUnknown
         ]
      ++ diffRecord paths declaration oldUnknown oldFields newFields
  (EnumView oldEntries, EnumView newEntries) -> diffEnum paths declaration oldEntries newEntries
  (UnionView oldEncoding oldArms, UnionView newEncoding newArms) ->
    [ finding
        paths
        declaration
        "encoding"
        MappedUnionEncodingChanged
        "tagged-object encoding changed; version and upcast every affected private event root"
    | oldEncoding /= newEncoding
    ]
      ++ diffUnion paths declaration oldArms newArms
  _ ->
    [ finding
        paths
        declaration
        "shape"
        MappedUnionEncodingChanged
        "structural shape kind changed; version and upcast every affected private event root"
    ]

diffRecord :: [UsePath] -> Name -> UnknownFields -> [ResolvedWireField] -> [ResolvedWireField] -> [MappedFinding]
diffRecord paths declaration oldUnknown oldFields newFields =
  concatMap (uncurry (diffField paths declaration)) matched
    ++ map addedFinding added
    ++ map removedFinding removed
  where
    (matched, added, removed) = pairFields oldFields newFields
    addedFinding field =
      (findingWithUnknown paths declaration (fieldLeaf field) code detail (Just oldUnknown))
      where
        hasDefault = isJustValue (rwfOnMissing field)
        code
          | hasDefault = MappedFieldAddedWithDefault
          | otherwise = MappedFieldAddedNoDefault
        oldPolicy = case oldUnknown of RejectUnknown -> "reject"; IgnoreUnknown -> "ignore"
        detail
          | hasDefault =
              "field added with an explicit on-missing default; new readers preserve old meaning, while old readers use unknown-fields="
                <> oldPolicy
          | otherwise =
              "field added without an on-missing default; old payloads do not contain it, so version and upcast every affected private event root"
    removedFinding field =
      finding
        paths
        declaration
        (fieldLeaf field)
        MappedFieldRemoved
        "field removed; replay-relevant removal remains breaking even when a tolerant decoder would ignore the historical key"

pairFields :: [ResolvedWireField] -> [ResolvedWireField] -> ([(ResolvedWireField, ResolvedWireField)], [ResolvedWireField], [ResolvedWireField])
pairFields oldFields newFields = (exact <> fallback, added, removed)
  where
    exact =
      [ (oldField, newField)
      | newField <- newFields,
        oldField <- maybeToList (find ((== rwfHaskell newField) . rwfHaskell) oldFields)
      ]
    matchedOld = map (rwfHaskell . fst) exact
    matchedNew = map (rwfHaskell . snd) exact
    unmatchedOld = [field | field <- oldFields, rwfHaskell field `notElem` matchedOld]
    unmatchedNew = [field | field <- newFields, rwfHaskell field `notElem` matchedNew]
    fallback =
      [ (oldField, newField)
      | newField <- unmatchedNew,
        oldField <- maybeToList (find ((== rwfKey newField) . rwfKey) unmatchedOld)
      ]
    fallbackOld = map (rwfHaskell . fst) fallback
    fallbackNew = map (rwfHaskell . snd) fallback
    removed = [field | field <- unmatchedOld, rwfHaskell field `notElem` fallbackOld]
    added = [field | field <- unmatchedNew, rwfHaskell field `notElem` fallbackNew]

diffField :: [UsePath] -> Name -> ResolvedWireField -> ResolvedWireField -> [MappedFinding]
diffField paths declaration oldField newField =
  [ finding
      paths
      declaration
      leaf
      MappedWireKeyChanged
      ("wire key changed '" <> rwfKey oldField <> "' -> '" <> rwfKey newField <> "'; version and upcast every affected private event root")
  | rwfKey oldField /= rwfKey newField
  ]
    ++ [ finding
           paths
           declaration
           leaf
           MappedPresenceChanged
           "field presence changed between required and optional; historical decode policy changed"
       | rwfPresence oldField /= rwfPresence newField
       ]
    ++ defaultChanges
    ++ diffExpr paths declaration (leaf <> ".type") (rwfType oldField) (rwfType newField)
  where
    leaf = fieldLeaf newField
    defaultChanges = case (rwfOnMissing oldField, rwfOnMissing newField) of
      (Just _, Nothing) ->
        [ finding
            paths
            declaration
            leaf
            MappedDefaultRemoved
            "on-missing default was removed; old payloads may no longer decode with preserved meaning"
        ]
      (oldDefault, newDefault)
        | oldDefault /= newDefault ->
            [ finding
                paths
                declaration
                leaf
                MappedDefaultChanged
                "on-missing default changed; the same historical bytes now construct a different consumer value"
            ]
      _ -> []

diffExpr :: [UsePath] -> Name -> Text -> ResolvedTypeExpr -> ResolvedTypeExpr -> [MappedFinding]
diffExpr paths declaration leaf oldExpression newExpression =
  case (exprView oldExpression, exprView newExpression) of
    (oldView, newView)
      | oldView == newView -> []
    (ExprOptional oldValue, ExprOptional newValue) -> recurse ".optional" oldValue newValue
    (ExprList oldValue, ExprList newValue) -> recurse "[]" oldValue newValue
    (ExprMap oldValue, ExprMap newValue) -> recurse "{}" oldValue newValue
    (ExprOptional _, _) -> nullability
    (_, ExprOptional _) -> nullability
    _ ->
      [ finding
          paths
          declaration
          leaf
          MappedFieldTypeChanged
          "wire type changed; version and upcast every affected private event root"
      ]
  where
    recurse suffix oldView newView = diffExprViews paths declaration (leaf <> suffix) oldView newView
    nullability =
      [ finding
          paths
          declaration
          leaf
          MappedNullabilityChanged
          "Optional nullability changed; historical null and non-null meanings are no longer stable"
      ]

diffExprViews :: [UsePath] -> Name -> Text -> ExprView -> ExprView -> [MappedFinding]
diffExprViews paths declaration leaf oldView newView = case (oldView, newView) of
  _ | oldView == newView -> []
  (ExprOptional oldValue, ExprOptional newValue) -> diffExprViews paths declaration (leaf <> ".optional") oldValue newValue
  (ExprList oldValue, ExprList newValue) -> diffExprViews paths declaration (leaf <> "[]") oldValue newValue
  (ExprMap oldValue, ExprMap newValue) -> diffExprViews paths declaration (leaf <> "{}") oldValue newValue
  (ExprOptional _, _) -> nullability
  (_, ExprOptional _) -> nullability
  _ -> [finding paths declaration leaf MappedFieldTypeChanged "wire type changed; version and upcast every affected private event root"]
  where
    nullability = [finding paths declaration leaf MappedNullabilityChanged "Optional nullability changed; historical null and non-null meanings are no longer stable"]

diffEnum :: [UsePath] -> Name -> [WireEnum] -> [WireEnum] -> [MappedFinding]
diffEnum paths declaration oldEntries newEntries =
  [ finding
      paths
      declaration
      (enumLeaf newEntry)
      MappedEnumSpellingChanged
      ("enum wire spelling changed '" <> weTag oldEntry <> "' -> '" <> weTag newEntry <> "'")
  | newEntry <- newEntries,
    oldEntry <- maybeToList (find ((== weCtor newEntry) . weCtor) oldEntries),
    weTag oldEntry /= weTag newEntry
  ]
    ++ [ finding
           paths
           declaration
           (enumLeaf entry)
           MappedEnumValueAdded
           "enum value added; existing history remains readable, but deploy readers before writers emit the new spelling; a future public surface exposing this closed enum would classify the addition as consumer-breaking"
       | entry <- newEntries,
         isNothing (find ((== weCtor entry) . weCtor) oldEntries)
       ]
    ++ [ finding
           paths
           declaration
           (enumLeaf entry)
           MappedEnumValueRemoved
           "enum value removed; historical payloads carrying its wire spelling no longer decode"
       | entry <- oldEntries,
         isNothing (find ((== weCtor entry) . weCtor) newEntries)
       ]

diffUnion :: [UsePath] -> Name -> [ResolvedWireArm] -> [ResolvedWireArm] -> [MappedFinding]
diffUnion paths declaration oldArms newArms =
  concatMap (uncurry pairedArm) matched
    ++ map addedArm added
    ++ map removedArm removed
  where
    (matched, added, removed) = pairArms oldArms newArms
    pairedArm oldArm newArm =
      [ finding
          paths
          declaration
          (armLeaf newArm)
          MappedArmTagChanged
          ("union arm tag changed '" <> rwaTag oldArm <> "' -> '" <> rwaTag newArm <> "'")
      | rwaTag oldArm /= rwaTag newArm
      ]
        ++ case (rwaPayload oldArm, rwaPayload newArm) of
          (Nothing, Nothing) -> []
          (Just oldPayload, Just newPayload) -> diffExpr paths declaration (armLeaf newArm <> ".payload") oldPayload newPayload
          _ -> [finding paths declaration (armLeaf newArm) MappedFieldTypeChanged "union arm payload presence changed; historical tagged objects no longer share one wire shape"]
    addedArm arm = finding paths declaration (armLeaf arm) MappedArmAdded "union arm added; existing history remains readable, but older binaries cannot read the new arm once emitted, so deploy readers before writers; a future public surface exposing this closed union would classify the addition as consumer-breaking"
    removedArm arm = finding paths declaration (armLeaf arm) MappedArmRemoved "union arm removed; historical tagged objects carrying that tag no longer decode"

pairArms :: [ResolvedWireArm] -> [ResolvedWireArm] -> ([(ResolvedWireArm, ResolvedWireArm)], [ResolvedWireArm], [ResolvedWireArm])
pairArms oldArms newArms = (exact <> fallback, added, removed)
  where
    exact =
      [ (oldArm, newArm)
      | newArm <- newArms,
        oldArm <- maybeToList (find ((== rwaCtor newArm) . rwaCtor) oldArms)
      ]
    matchedOld = map (rwaCtor . fst) exact
    matchedNew = map (rwaCtor . snd) exact
    unmatchedOld = [arm | arm <- oldArms, rwaCtor arm `notElem` matchedOld]
    unmatchedNew = [arm | arm <- newArms, rwaCtor arm `notElem` matchedNew]
    fallback =
      [ (oldArm, newArm)
      | newArm <- unmatchedNew,
        oldArm <- maybeToList (find ((== rwaTag newArm) . rwaTag) unmatchedOld)
      ]
    fallbackOld = map (rwaCtor . fst) fallback
    fallbackNew = map (rwaCtor . snd) fallback
    removed = [arm | arm <- unmatchedOld, rwaCtor arm `notElem` fallbackOld]
    added = [arm | arm <- unmatchedNew, rwaCtor arm `notElem` fallbackNew]

addedDeclaration :: TypeGraph -> (MappedKey, ResolvedMappedDecl) -> MappedFinding
addedDeclaration _ (key, _) =
  finding
    []
    (unMappedKey key)
    ""
    MappedDeclAdded
    "new mapped declaration; use-site changes retain their own compatibility classification"

removedDeclaration :: TypeGraph -> (MappedKey, ResolvedMappedDecl) -> MappedFinding
removedDeclaration graph (key, _) =
  finding
    (usePaths graph (unMappedKey key))
    (unMappedKey key)
    ""
    MappedDeclRemoved
    "mapped declaration removed; persisted roots using its historical decoder require migration, while an unused source-only declaration requires consumer rebuild only"

pathsFor :: TypeGraph -> TypeGraph -> Name -> [UsePath]
pathsFor oldGraph newGraph name =
  nubBy sameRendered . sortOn renderUsePath $ usePaths oldGraph name <> usePaths newGraph name
  where
    sameRendered left right = renderUsePath left == renderUsePath right

resolvedName :: ResolvedMappedDecl -> Name
resolvedName =
  foldMappedDecl
    MappedDeclAlgebra
      { onStructuralDecl = \declaration _ -> sdName declaration,
        onOpaqueDecl = odName
      }

fieldLeaf :: ResolvedWireField -> Text
fieldLeaf field = ".field " <> rwfHaskell field <> "[\"" <> rwfKey field <> "\"]"

armLeaf :: ResolvedWireArm -> Text
armLeaf arm = ".arm " <> rwaCtor arm <> "[\"" <> rwaTag arm <> "\"]"

enumLeaf :: WireEnum -> Text
enumLeaf entry = ".enum " <> weCtor entry <> "[\"" <> weTag entry <> "\"]"

finding :: [UsePath] -> Name -> Text -> DiagnosticCode -> Text -> MappedFinding
finding paths declaration leaf code detail =
  findingWithUnknown paths declaration leaf code detail Nothing

findingWithUnknown :: [UsePath] -> Name -> Text -> DiagnosticCode -> Text -> Maybe UnknownFields -> MappedFinding
findingWithUnknown paths declaration leaf code detail unknownFields =
  MappedFinding
    { mfDeclaration = declaration,
      mfLeaf = leaf,
      mfCode = code,
      mfDetail = detail,
      mfUsePaths = paths,
      mfOldUnknownFields = unknownFields
    }

isJustValue :: Maybe a -> Bool
isJustValue = not . isNothing

maybeToList :: Maybe a -> [a]
maybeToList = maybe [] pure
