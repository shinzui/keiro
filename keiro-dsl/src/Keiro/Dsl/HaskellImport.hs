-- | Deterministic imports and external references for generated Haskell.
--
-- The types are present while the presentation contract is developed. The
-- planner itself is implemented in Milestone 1 of ExecPlan 184.
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

import Data.Set (Set)
import Data.Text (Text)

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
  = HaskellImportPlanningUnavailable !Text
  | MissingHaskellReference !Text !HaskellReference
  deriving stock (Eq, Show)

newtype HaskellImportPlan = HaskellImportPlan Text

planHaskellImports :: ImportEnvironment -> Set HaskellReference -> Either HaskellImportError HaskellImportPlan
planHaskellImports environment _ = Left (HaskellImportPlanningUnavailable (targetModule environment))

renderPlannedImports :: HaskellImportPlan -> Text
renderPlannedImports (HaskellImportPlan rendered) = rendered

renderPlannedReference :: HaskellImportPlan -> HaskellReference -> Either HaskellImportError Text
renderPlannedReference (HaskellImportPlan target) reference = Left (MissingHaskellReference target reference)
