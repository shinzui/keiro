-- | Deterministic imports and external references for generated Haskell.
--
-- A renderer supplies every external reference needed by one target module.
-- This module makes all qualification choices over that complete set so the
-- resulting aliases and bytes do not depend on declaration traversal order.
module Keiro.Dsl.HaskellImport
  ( HaskellNamespace (..),
    QualificationPreference (..),
    HaskellReference (..),
    ImportEnvironment (..),
    HaskellImportError (..),
    HaskellImportPlan,
    planHaskellImports,
    renderPlannedImports,
    renderPlannedReference,
  )
where

import Data.Foldable (traverse_)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.HaskellName (haskellKeywords)

data HaskellNamespace
  = TypeNamespace
  | ValueNamespace
  | ConstructorNamespace
  deriving stock (Eq, Ord, Show)

data QualificationPreference
  = PreferUnqualified
  | RequireQualified
  deriving stock (Eq, Ord, Show)

data HaskellReference = HaskellReference
  { referenceModule :: !Text,
    referenceName :: !Text,
    referenceNamespace :: !HaskellNamespace,
    referenceQualification :: !QualificationPreference
  }
  deriving stock (Eq, Ord, Show)

data ImportEnvironment = ImportEnvironment
  { targetModule :: !Text,
    localNames :: !(Set Text),
    reservedQualifiers :: !(Set Text)
  }
  deriving stock (Eq, Show)

data HaskellImportError
  = InvalidHaskellModule !Text !Text
  | InvalidHaskellOccurrence !Text !HaskellNamespace !Text
  | HaskellSelfImport !Text
  | ImpossibleHaskellAlias !Text !(Set Text)
  | MissingHaskellReference !Text !HaskellReference
  deriving stock (Eq, Show)

data HaskellImportPlan = HaskellImportPlan
  { importPlanTargetModule :: !Text,
    importPlanDeclarations :: !(Set Text),
    importPlanReferences :: !(Map HaskellReference Text)
  }

planHaskellImports :: ImportEnvironment -> Set HaskellReference -> Either HaskellImportError HaskellImportPlan
planHaskellImports environment references = do
  validateModuleName target target
  traverse_ (validateReference target) orderedReferences
  aliases <- allocateAliases environment unqualifiedNames qualifiedModules
  plannedReferences <- Map.fromList <$> traverse (renderReference aliases) orderedReferences
  pure
    HaskellImportPlan
      { importPlanTargetModule = target,
        importPlanDeclarations = explicitDeclarations <> qualifiedDeclarations aliases,
        importPlanReferences = plannedReferences
      }
  where
    target = targetModule environment
    orderedReferences = Set.toAscList references
    occurrenceOwners =
      Map.fromListWith
        (<>)
        [ (referenceName reference, Set.singleton (referenceModule reference, referenceName reference))
        | reference <- orderedReferences,
          referenceNamespace reference == TypeNamespace,
          referenceQualification reference == PreferUnqualified
        ]
    unqualified reference =
      referenceNamespace reference == TypeNamespace
        && referenceQualification reference == PreferUnqualified
        && Set.notMember (referenceName reference) (localNames environment)
        && Set.notMember (referenceName reference) (reservedQualifiers environment)
        && maybe False ((== 1) . Set.size) (Map.lookup (referenceName reference) occurrenceOwners)
    unqualifiedReferences = Set.filter unqualified references
    unqualifiedNames = Set.map referenceName unqualifiedReferences
    qualifiedModules =
      Set.map referenceModule (references `Set.difference` unqualifiedReferences)
    explicitImports =
      Map.fromListWith
        (<>)
        [ (referenceModule reference, Set.singleton (referenceName reference))
        | reference <- Set.toAscList unqualifiedReferences
        ]
    explicitDeclarations =
      Set.fromList
        [ "import " <> moduleName <> " (" <> T.intercalate ", " (Set.toAscList names) <> ")"
        | (moduleName, names) <- Map.toAscList explicitImports
        ]
    qualifiedDeclarations aliases =
      Set.fromList
        [ "import " <> moduleName <> " qualified as " <> alias
        | (moduleName, alias) <- Map.toAscList aliases
        ]
    renderReference aliases reference
      | Set.member reference unqualifiedReferences = pure (reference, referenceName reference)
      | otherwise = case Map.lookup (referenceModule reference) aliases of
          Nothing -> Left (ImpossibleHaskellAlias target (Set.singleton (referenceModule reference)))
          Just alias -> pure (reference, alias <> "." <> referenceName reference)

renderPlannedImports :: HaskellImportPlan -> Text
renderPlannedImports = T.intercalate "\n" . Set.toAscList . importPlanDeclarations

renderPlannedReference :: HaskellImportPlan -> HaskellReference -> Either HaskellImportError Text
renderPlannedReference plan reference =
  maybe
    (Left (MissingHaskellReference (importPlanTargetModule plan) reference))
    Right
    (Map.lookup reference (importPlanReferences plan))

allocateAliases :: ImportEnvironment -> Set Text -> Set Text -> Either HaskellImportError (Map Text Text)
allocateAliases environment unqualifiedNames modules = do
  let moduleCandidates = Map.fromSet suffixCandidates modules
      candidateOwners =
        Map.fromListWith
          (<>)
          [ (candidate, Set.singleton moduleName)
          | (moduleName, candidates) <- Map.toAscList moduleCandidates,
            candidate <- candidates
          ]
      occupied = reservedQualifiers environment <> localNames environment <> unqualifiedNames
      choose moduleName candidates =
        case find (isAvailable moduleName candidateOwners occupied) candidates of
          Just candidate -> candidate
          Nothing -> T.intercalate "_" (moduleComponents moduleName)
      aliases = Map.mapWithKey choose moduleCandidates
      ownersByAlias =
        Map.fromListWith
          (<>)
          [ (alias, Set.singleton moduleName)
          | (moduleName, alias) <- Map.toAscList aliases
          ]
      impossibleModules =
        Set.unions
          [ owners
          | (alias, owners) <- Map.toAscList ownersByAlias,
            Set.member alias occupied || Set.size owners /= 1 || not (validUpperIdentifier alias)
          ]
  if Set.null impossibleModules
    then pure aliases
    else Left (ImpossibleHaskellAlias (targetModule environment) impossibleModules)

isAvailable :: Text -> Map Text (Set Text) -> Set Text -> Text -> Bool
isAvailable moduleName candidateOwners occupied candidate =
  Set.notMember candidate occupied
    && Map.lookup candidate candidateOwners == Just (Set.singleton moduleName)
    && validUpperIdentifier candidate

suffixCandidates :: Text -> [Text]
suffixCandidates moduleName =
  [ T.concat (drop (componentCount - suffixLength) components)
  | suffixLength <- [1 .. componentCount]
  ]
  where
    components = moduleComponents moduleName
    componentCount = length components

moduleComponents :: Text -> [Text]
moduleComponents = T.splitOn "."

validateReference :: Text -> HaskellReference -> Either HaskellImportError ()
validateReference target reference = do
  validateModuleName target (referenceModule reference)
  if referenceModule reference == target
    then Left (HaskellSelfImport target)
    else pure ()
  if validOccurrence (referenceNamespace reference) (referenceName reference)
    then pure ()
    else Left (InvalidHaskellOccurrence target (referenceNamespace reference) (referenceName reference))

validateModuleName :: Text -> Text -> Either HaskellImportError ()
validateModuleName target candidate
  | not (null components) && all validUpperIdentifier components = pure ()
  | otherwise = Left (InvalidHaskellModule target candidate)
  where
    components = moduleComponents candidate

validOccurrence :: HaskellNamespace -> Text -> Bool
validOccurrence namespace name =
  not (Set.member name haskellKeywords)
    && case namespace of
      TypeNamespace -> validUpperIdentifier name
      ConstructorNamespace -> validUpperIdentifier name
      ValueNamespace -> validLowerIdentifier name

validUpperIdentifier :: Text -> Bool
validUpperIdentifier name = case T.uncons name of
  Just (first, rest) -> asciiUpper first && T.all identifierTail rest
  Nothing -> False

validLowerIdentifier :: Text -> Bool
validLowerIdentifier name = case T.uncons name of
  Just (first, rest) -> (asciiLower first || first == '_') && T.all identifierTail rest
  Nothing -> False

identifierTail :: Char -> Bool
identifierTail character =
  asciiUpper character
    || asciiLower character
    || asciiDigit character
    || character == '_'
    || character == '\''

asciiUpper :: Char -> Bool
asciiUpper character = character >= 'A' && character <= 'Z'

asciiLower :: Char -> Bool
asciiLower character = character >= 'a' && character <= 'z'

asciiDigit :: Char -> Bool
asciiDigit character = character >= '0' && character <= '9'
