{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Consumer-owned Haskell obligations implied by checked structural mapped
-- declarations. The same values drive create-once skeletons, scaffold-record
-- diffs, and the @check --explain-bindings@ report.
module Keiro.Dsl.ExplainBindings
  ( BindingResolutionError (..),
    BindingObligationKind (..),
    BindingObligation (..),
    BindingHole (..),
    bindingObligations,
    bindingHoles,
    renderBindingObligations,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Bifunctor (first)
import Data.Char (toUpper)
import Data.List (groupBy, sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.NominalType
import Keiro.Dsl.TypeGraph

data BindingResolutionError
  = BindingTypeGraphError !TypeGraphError
  | BindingNominalTypeError !NominalTypeError
  deriving stock (Eq, Show)

data BindingObligationKind
  = BindingValue
  | FixtureValue
  | InitialValue
  deriving stock (Eq, Ord, Show)

data BindingObligation = BindingObligation
  { obligationMappedName :: !Name,
    obligationPackage :: !Text,
    obligationModule :: !Text,
    obligationSymbol :: !Text,
    obligationKind :: !BindingObligationKind,
    obligationSignature :: !Text,
    obligationUseSites :: ![Text],
    obligationBindingVersion :: !(Maybe Text),
    obligationCanonicalType :: !(Maybe Text),
    obligationCategory :: !Text
  }
  deriving stock (Eq, Ord, Show)

data BindingHole = BindingHole
  { holeMappedName :: !Name,
    holeModule :: !Text,
    holeSymbol :: !Text,
    holeKind :: !BindingObligationKind,
    holePath :: !(Maybe Text),
    holeSignature :: !Text
  }
  deriving stock (Eq, Ord, Show)

instance ToJSON BindingObligation where
  toJSON obligation =
    object
      [ "schema" .= (1 :: Int),
        "mappedName" .= obligationMappedName obligation,
        "package" .= obligationPackage obligation,
        "module" .= obligationModule obligation,
        "symbol" .= obligationSymbol obligation,
        "kind" .= renderKind (obligationKind obligation),
        "signature" .= obligationSignature obligation,
        "useSites" .= obligationUseSites obligation,
        "bindingVersion" .= obligationBindingVersion obligation,
        "canonicalType" .= obligationCanonicalType obligation,
        "category" .= obligationCategory obligation
      ]

instance FromJSON BindingObligation where
  parseJSON = withObject "keiro-dsl binding obligation" $ \value -> do
    schema <- value .: "schema"
    if schema /= (1 :: Int)
      then fail "unsupported binding obligation schema"
      else do
        kindText <- value .: "kind"
        kindValue <- maybe (fail "unknown binding obligation kind") pure (parseKind kindText)
        BindingObligation
          <$> value .: "mappedName"
          <*> value .: "package"
          <*> value .: "module"
          <*> value .: "symbol"
          <*> pure kindValue
          <*> value .: "signature"
          <*> value .: "useSites"
          <*> value .:? "bindingVersion"
          <*> value .:? "canonicalType"
          <*> (value .:? "category" >>= pure . maybe "structural" id)

instance ToJSON BindingHole where
  toJSON hole =
    object
      [ "schema" .= (1 :: Int),
        "mappedName" .= holeMappedName hole,
        "module" .= holeModule hole,
        "symbol" .= holeSymbol hole,
        "kind" .= renderKind (holeKind hole),
        "path" .= holePath hole,
        "signature" .= holeSignature hole
      ]

instance FromJSON BindingHole where
  parseJSON = withObject "keiro-dsl binding hole" $ \value -> do
    schema <- value .: "schema"
    if schema /= (1 :: Int)
      then fail "unsupported binding hole schema"
      else do
        kindText <- value .: "kind"
        kindValue <- maybe (fail "unknown binding hole kind") pure (parseKind kindText)
        BindingHole
          <$> value .: "mappedName"
          <*> value .: "module"
          <*> value .: "symbol"
          <*> pure kindValue
          <*> value .:? "path"
          <*> value .: "signature"

bindingObligations :: Spec -> Either (NonEmpty BindingResolutionError) [BindingObligation]
bindingObligations spec = do
  graph <- first (fmap BindingTypeGraphError) (resolveTypeGraph spec)
  nominalRegistry <- first (fmap BindingNominalTypeError) (resolveNominalTypes spec)
  pure . sortOn obligationSortKey $
    concat
      [ obligationsFor graph declaration
      | ResolvedStructural declaration _ <- Map.elems (tgDeclarations graph)
      ]
      <> concatMap (nominalObligationsFor spec) (Map.elems (nominalTypes nominalRegistry))

bindingHoles :: Spec -> Either (NonEmpty BindingResolutionError) [BindingHole]
bindingHoles spec = do
  graph <- first (fmap BindingTypeGraphError) (resolveTypeGraph spec)
  obligations <- bindingObligations spec
  pure . sortOn holeSortKey $
    concat
      [ holesFor graph declaration shape obligations
      | ResolvedStructural declaration shape <- Map.elems (tgDeclarations graph)
      ]
      <> [ BindingHole
             { holeMappedName = obligationMappedName obligation,
               holeModule = obligationModule obligation,
               holeSymbol = obligationSymbol obligation,
               holeKind = obligationKind obligation,
               holePath = Nothing,
               holeSignature = obligationSignature obligation
             }
         | obligation <- obligations,
           obligationCategory obligation /= "structural"
         ]

holesFor :: TypeGraph -> StructuralDecl -> ResolvedMappedShape -> [BindingObligation] -> [BindingHole]
holesFor _graph declaration shape obligations = bindingEntries <> auxiliaryEntries
  where
    own = filter ((== sdName declaration) . obligationMappedName) obligations
    binding = onlyKind BindingValue
    bindingEntries = case binding of
      Nothing -> []
      Just obligation -> map (bindingHole obligation) (shapeHolePaths shape)
    auxiliaryEntries =
      [ BindingHole
          { holeMappedName = obligationMappedName obligation,
            holeModule = obligationModule obligation,
            holeSymbol = obligationSymbol obligation,
            holeKind = obligationKind obligation,
            holePath = Nothing,
            holeSignature = obligationSignature obligation
          }
      | obligation <- own,
        obligationKind obligation /= BindingValue
      ]
    onlyKind wanted = case filter ((== wanted) . obligationKind) own of
      entry : _ -> Just entry
      [] -> Nothing
    bindingHole obligation (path, expectedType) =
      BindingHole
        { holeMappedName = obligationMappedName obligation,
          holeModule = obligationModule obligation,
          holeSymbol = obligationSymbol obligation,
          holeKind = BindingValue,
          holePath = Just path,
          holeSignature = obligationSymbol obligation <> "." <> path <> " :: " <> expectedType
        }

shapeHolePaths :: ResolvedMappedShape -> [(Text, Text)]
shapeHolePaths =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ fields -> [(rwfHaskell field, renderExprType (rwfType field)) | field <- fields],
        onEnum = \entries -> [(weCtor entry, "constructor case") | entry <- entries],
        onUnion = \_ arms ->
          [ (rwaCtor arm, maybe "constructor case" renderExprType (rwaPayload arm))
          | arm <- arms
          ]
      }

renderExprType :: ResolvedTypeExpr -> Text
renderExprType =
  foldTypeExpr
    TypeExprAlgebra
      { onText = "Text",
        onInt = "Int",
        onInteger = "Integer",
        onBool = "Bool",
        onNatural = "Natural",
        onTime = "UTCTime",
        onJson = "Value",
        onOptional = \value -> "Maybe (" <> value <> ")",
        onList = \value -> "[" <> value <> "]",
        onMap = \value -> "Map Text (" <> value <> ")",
        onRef = unMappedKey
      }

obligationsFor :: TypeGraph -> StructuralDecl -> [BindingObligation]
obligationsFor graph declaration = bindingEntry : fixtureEntry : initialEntries
  where
    source = sdHaskell declaration
    consumerType = hsModule source <> "." <> hsType source
    shapeType = sdName declaration <> "Shape"
    paths = map renderUsePath (usePaths graph (sdName declaration))
    registerPaths =
      [ renderUsePath path
      | path@UsePath {upRoot = RootRegister {}} <- usePaths graph (sdName declaration)
      ]
    bindingEntry =
      obligationFor
        declaration
        (sdBinding declaration)
        BindingValue
        ("StructuralBinding " <> consumerType <> " " <> shapeType)
        paths
        (Just (unBindingVersion (sdBindingVersion declaration)))
        (Just (unCanonicalTypeId (sdCanonical declaration)))
    fixtureEntry =
      obligationFor
        declaration
        (sdFixtures declaration)
        FixtureValue
        ("FixtureCases " <> consumerType)
        paths
        Nothing
        (Just (unCanonicalTypeId (sdCanonical declaration)))
    initialEntries = case (registerPaths, sdInitial declaration) of
      ([], _) -> []
      (_, Nothing) -> []
      (_, Just initialValue) ->
        [ obligationFor declaration initialValue InitialValue consumerType registerPaths Nothing (Just (unCanonicalTypeId (sdCanonical declaration)))
        ]

obligationFor :: StructuralDecl -> QualifiedValueName -> BindingObligationKind -> Text -> [Text] -> Maybe Text -> Maybe Text -> BindingObligation
obligationFor declaration qualified kindValue signature paths version canonical =
  BindingObligation
    { obligationMappedName = sdName declaration,
      obligationPackage = hsPackage (sdHaskell declaration),
      obligationModule = ownerModule,
      obligationSymbol = symbol,
      obligationKind = kindValue,
      obligationSignature = symbol <> " :: " <> signature,
      obligationUseSites = paths,
      obligationBindingVersion = version,
      obligationCanonicalType = canonical,
      obligationCategory = "structural"
    }
  where
    (ownerModule, symbol) = splitQualified (unQualifiedValueName qualified)

nominalObligationsFor :: Spec -> ResolvedNominalType -> [BindingObligation]
nominalObligationsFor spec nominal = case resolvedNominalOwnership nominal of
  GeneratedNominal -> []
  ConsumerNominal binding -> bindingEntry : fixtureEntry : initialEntries
    where
      name = resolvedNominalName nominal
      source = consumerNominalHaskell binding
      consumerType = hsModule source <> "." <> hsType source
      paths = nominalUseSites spec name
      registerPaths = [path | path <- paths, " register " `T.isInfixOf` path]
      category = case resolvedNominalRepresentation nominal of
        IdRepresentation {} -> "nominal-id"
        EnumRepresentation {} -> "nominal-enum"
        ScalarRepresentation {} -> "nominal-scalar"
      representation = case resolvedNominalRepresentation nominal of
        IdRepresentation prefix -> "(KindID " <> quoted prefix <> ")"
        EnumRepresentation {} -> nominalEnumRepresentationModule spec name <> "." <> name <> "Representation"
        ScalarRepresentation NominalText -> "Text"
        ScalarRepresentation NominalInt -> "Int"
        ScalarRepresentation NominalNatural -> "Natural"
        ScalarRepresentation NominalBool -> "Bool"
        ScalarRepresentation NominalTime -> "UTCTime"
      canonical = Just (unCanonicalTypeId (consumerNominalCanonical binding))
      bindingEntry = nominalObligation name binding category (consumerNominalBinding binding) BindingValue ("NominalBinding " <> consumerType <> " " <> representation) paths (Just (unBindingVersion (consumerNominalBindingVersion binding))) canonical
      fixtureEntry = nominalObligation name binding category (consumerNominalFixtures binding) FixtureValue ("NominalFixtureCases " <> consumerType) paths Nothing canonical
      initialEntries = case (registerPaths, consumerNominalInitial binding) of
        ([], _) -> []
        (_, Nothing) -> []
        (_, Just initialValue) -> [nominalObligation name binding category initialValue InitialValue consumerType registerPaths Nothing canonical]
  where
    quoted value = T.pack (show value)

nominalObligation :: Name -> ConsumerNominalBinding -> Text -> QualifiedValueName -> BindingObligationKind -> Text -> [Text] -> Maybe Text -> Maybe Text -> BindingObligation
nominalObligation name binding category qualified kindValue signature paths version canonical =
  BindingObligation
    { obligationMappedName = name,
      obligationPackage = hsPackage (consumerNominalHaskell binding),
      obligationModule = ownerModule,
      obligationSymbol = symbol,
      obligationKind = kindValue,
      obligationSignature = symbol <> " :: " <> signature,
      obligationUseSites = paths,
      obligationBindingVersion = version,
      obligationCanonicalType = canonical,
      obligationCategory = category
    }
  where
    (ownerModule, symbol) = splitQualified (unQualifiedValueName qualified)

nominalUseSites :: Spec -> Name -> [Text]
nominalUseSites spec target = concatMap aggregatePaths [aggregate | NAggregate aggregate <- specNodes spec]
  where
    aggregatePaths aggregate =
      [ aggName aggregate <> " command " <> cmdName command <> " ." <> aggregateFieldName field <> " : " <> target
      | command <- aggCommands aggregate,
        field <- cmdFields command,
        fieldUses field
      ]
        <> [ aggName aggregate <> " event " <> evName event <> " ." <> aggregateFieldName field <> " : " <> target
           | event <- aggEvents aggregate,
             field <- eventFields aggregate event,
             fieldUses field
           ]
        <> [ aggName aggregate <> " register " <> regName register <> " : " <> target
           | register <- aggRegs aggregate,
             regType register == TRef target
           ]
    eventFields aggregate event = case evBody event of
      EventFields fields -> fields
      EventFromCommand commandName -> concat [cmdFields command | command <- aggCommands aggregate, cmdName command == commandName]
    fieldUses field = aggregateFieldType field == Just (TRef target)

nominalEnumRepresentationModule :: Spec -> Name -> Text
nominalEnumRepresentationModule spec name = case maybe GeneratedPrefix id (specLayout spec) of
  GeneratedPrefix -> root <> "Generated." <> contextName <> ".Nominal.Shape." <> name
  CollocatedLeaf -> root <> contextName <> ".Nominal.Shape." <> name <> ".Generated"
  where
    root = maybe "" (<> ".") (specModuleRoot spec)
    contextName = T.concat (map titleSegment (T.splitOn "-" (specContext spec)))
    titleSegment value = case T.uncons value of
      Nothing -> ""
      Just (initialChar, rest) -> T.cons (toUpper initialChar) rest

renderBindingObligations :: Text -> [BindingObligation] -> Text
renderBindingObligations context obligations = case obligations of
  [] -> "no binding obligations for context " <> context
  _ ->
    T.unlines $
      ["binding obligations for context " <> context]
        <> concatMap renderGroup grouped
  where
    grouped = groupBy sameOwner (sortOn obligationSortKey obligations)
    sameOwner left right = ownerKey left == ownerKey right
    renderGroup [] = []
    renderGroup entries@(firstEntry : _) =
      ("  " <> obligationModule firstEntry <> " (package " <> obligationPackage firstEntry <> ")")
        : concatMap renderEntry entries
    renderEntry obligation =
      [ "    " <> obligationSignature obligation,
        "      reason: " <> renderKind (obligationKind obligation) <> " — " <> obligationCategory obligation <> " type " <> obligationMappedName obligation <> renderPaths (obligationUseSites obligation)
      ]
        <> maybe [] (\version -> ["      provenance: binding-version " <> quoted version]) (obligationBindingVersion obligation)
        <> maybe [] (\canonical -> ["      canonical-type: " <> quoted canonical]) (obligationCanonicalType obligation)
    renderPaths [] = " (not currently used by an aggregate root)"
    renderPaths paths = " (" <> T.intercalate "; " paths <> ")"
    quoted value = T.pack (show value)

obligationSortKey :: BindingObligation -> (Text, Text, Text, BindingObligationKind, Text)
obligationSortKey obligation =
  ( obligationPackage obligation,
    obligationModule obligation,
    obligationMappedName obligation,
    obligationKind obligation,
    obligationSymbol obligation
  )

ownerKey :: BindingObligation -> (Text, Text)
ownerKey obligation = (obligationPackage obligation, obligationModule obligation)

holeSortKey :: BindingHole -> (Text, Name, BindingObligationKind, Maybe Text, Text)
holeSortKey hole =
  (holeModule hole, holeMappedName hole, holeKind hole, holePath hole, holeSymbol hole)

renderKind :: BindingObligationKind -> Text
renderKind BindingValue = "binding"
renderKind FixtureValue = "fixtures"
renderKind InitialValue = "initial-value"

parseKind :: Text -> Maybe BindingObligationKind
parseKind "binding" = Just BindingValue
parseKind "fixtures" = Just FixtureValue
parseKind "initial-value" = Just InitialValue
parseKind _ = Nothing

splitQualified :: Text -> (Text, Text)
splitQualified value =
  let (prefix, name) = T.breakOnEnd "." value
   in (T.dropEnd 1 prefix, name)
