-- | Pure construction and JSON encoding for @check@ reports.
--
-- The JSON schema identifier is @keiro-dsl/check-report/1@. Object keys and
-- array element keys are append-only, and consumers must ignore unknown keys.
-- Source and workspace checks share the schema; workspace inputs add a
-- top-level @members@ array. The report's @ok@ field covers parse-successful
-- semantic validation, minimum-language enforcement, denied warnings, and — when
-- the invocation supplies @--coverage-report@ — the structural-coverage
-- findings, which appear as ordinary diagnostic entries at line 0 so one warning
-- policy governs every warning @check@ can emit. The separate coverage report
-- remains the place for the full root and boundary inventory.
--
-- Severity is spelled @"error"@ or @"warning"@ here and in the coverage report;
-- there is exactly one severity vocabulary across keiro-dsl's JSON.
module Keiro.Dsl.CheckReport
  ( CheckReportLanguage (..),
    CheckReportEnforcement (..),
    CheckReportRelated (..),
    CheckReportEntry (..),
    CheckReportSummary (..),
    CheckReportMember (..),
    CheckReport,
    effectiveDenyCodes,
    checkReport,
    workspaceCheckReport,
    workspaceRefusalReport,
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.List.NonEmpty qualified as NE
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Keiro.Dsl.LanguageVersion (LanguageSupport (..), LanguageVersion, SourceLanguage, declaredLanguageVersionMaybe, languageSupportText, sourceFormText)
import Keiro.Dsl.SemanticContract (EffectiveLanguageContract (..), effectiveLanguageSupport, effectiveRuntimeSemantics)
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode, Severity (..), diagnosticCodeText)
import Keiro.Dsl.Workspace (WorkspaceDiagnostic (..), WorkspaceLocation (..), WorkspaceMember (..), WorkspaceSpec (..), workspaceDisplayPath)

data CheckReportLanguage = CheckReportLanguage
  { sourceForm :: !Text,
    declaredLanguageVersion :: !(Maybe LanguageVersion),
    effectiveLanguageVersion :: !LanguageVersion,
    runtimeSemantics :: !Text,
    languageSupport :: !LanguageSupport,
    stable :: !Bool
  }
  deriving stock (Eq, Show)

data CheckReportEnforcement = CheckReportEnforcement
  { minLanguage :: !(Maybe LanguageVersion),
    denyWarnings :: !Bool,
    denyCodes :: ![DiagnosticCode]
  }
  deriving stock (Eq, Show)

data CheckReportRelated = CheckReportRelated
  { file :: !FilePath,
    line :: !Int,
    note :: !Text
  }
  deriving stock (Eq, Show)

data CheckReportEntry = CheckReportEntry
  { code :: !DiagnosticCode,
    severity :: !Severity,
    file :: !FilePath,
    line :: !Int,
    message :: !Text,
    denied :: !Bool,
    related :: ![CheckReportRelated]
  }
  deriving stock (Eq, Show)

data CheckReportSummary = CheckReportSummary
  { errors :: !Int,
    warnings :: !Int,
    deniedWarnings :: !Int
  }
  deriving stock (Eq, Show)

data CheckReportMember = CheckReportMember
  { path :: !FilePath,
    sourceForm :: !Text,
    declaredLanguageVersion :: !(Maybe LanguageVersion)
  }
  deriving stock (Eq, Show)

data CheckReportKind = SourceReport | WorkspaceReport
  deriving stock (Eq, Show)

data CheckReport = CheckReport
  { kind :: !CheckReportKind,
    subject :: !FilePath,
    -- | 'Nothing' only for a workspace that was refused during composition:
    -- there is no composed service, so no effective language contract exists to
    -- describe. Such a report serializes @"language": null@.
    language :: !(Maybe CheckReportLanguage),
    enforcement :: !CheckReportEnforcement,
    diagnostics :: ![CheckReportEntry],
    summary :: !CheckReportSummary,
    ok :: !Bool,
    members :: ![CheckReportMember]
  }
  deriving stock (Eq, Show)

-- | Expand one invocation's warning policy to the actual stable-code set used
-- by report entries. @--deny-warnings@ is the union with every registered code.
effectiveDenyCodes :: CheckReportEnforcement -> Set DiagnosticCode
effectiveDenyCodes enforcement
  | (.denyWarnings) enforcement = Set.fromList [minBound .. maxBound]
  | otherwise = Set.fromList ((.denyCodes) enforcement)

checkReport ::
  FilePath ->
  SourceLanguage ->
  EffectiveLanguageContract ->
  CheckReportEnforcement ->
  [Diagnostic] ->
  Set DiagnosticCode ->
  CheckReport
checkReport subject sourceLanguage contract enforcement diagnostics deniedCodes =
  buildReport
    SourceReport
    subject
    (Just (sourceLanguageValue sourceLanguage contract))
    enforcement
    (map (sourceEntry subject deniedCodes) diagnostics)
    []

workspaceCheckReport ::
  FilePath ->
  WorkspaceSpec ->
  EffectiveLanguageContract ->
  CheckReportEnforcement ->
  [WorkspaceDiagnostic] ->
  Set DiagnosticCode ->
  CheckReport
workspaceCheckReport subject workspace contract enforcement diagnostics deniedCodes =
  buildReport
    WorkspaceReport
    subject
    (Just (workspaceLanguageValue contract))
    enforcement
    (map (workspaceEntry subject deniedCodes) diagnostics)
    (map memberValue ((.members) workspace))

-- | The report for a workspace refused during composition, before any service
-- graph exists. Composition refusals are coded diagnostics, so they belong in
-- the same machine contract as every other refusal; the single-spec path has
-- always written one for the equivalent failure. There is no composed language
-- contract and no member inventory to report, so both are omitted.
workspaceRefusalReport ::
  FilePath ->
  CheckReportEnforcement ->
  NE.NonEmpty WorkspaceDiagnostic ->
  Set DiagnosticCode ->
  CheckReport
workspaceRefusalReport subject enforcement diagnostics deniedCodes =
  buildReport
    WorkspaceReport
    subject
    Nothing
    enforcement
    (map (workspaceEntry subject deniedCodes) (NE.toList diagnostics))
    []

buildReport ::
  CheckReportKind ->
  FilePath ->
  Maybe CheckReportLanguage ->
  CheckReportEnforcement ->
  [CheckReportEntry] ->
  [CheckReportMember] ->
  CheckReport
buildReport kind subject language enforcement entries members =
  CheckReport
    { kind = kind,
      subject = subject,
      language = language,
      enforcement = enforcement,
      diagnostics = entries,
      summary = summary,
      ok = (.errors) summary == 0 && (.deniedWarnings) summary == 0,
      members = members
    }
  where
    summary =
      CheckReportSummary
        { errors = length [() | entry <- entries, (.severity) entry == Error],
          warnings = length [() | entry <- entries, (.severity) entry == Warning],
          deniedWarnings = length [() | entry <- entries, (.denied) entry]
        }

sourceLanguageValue :: SourceLanguage -> EffectiveLanguageContract -> CheckReportLanguage
sourceLanguageValue sourceLanguage contract =
  languageValue
    (sourceFormText sourceLanguage)
    (declaredLanguageVersionMaybe sourceLanguage)
    contract

workspaceLanguageValue :: EffectiveLanguageContract -> CheckReportLanguage
workspaceLanguageValue = languageValue "workspace-composed" Nothing

languageValue :: Text -> Maybe LanguageVersion -> EffectiveLanguageContract -> CheckReportLanguage
languageValue sourceForm declared contract =
  CheckReportLanguage
    { sourceForm = sourceForm,
      declaredLanguageVersion = declared,
      effectiveLanguageVersion = (.contractLanguageVersion) contract,
      runtimeSemantics = effectiveRuntimeSemantics contract,
      languageSupport = support,
      stable = support == Stable
    }
  where
    support = effectiveLanguageSupport contract

memberValue :: WorkspaceMember -> CheckReportMember
memberValue member =
  CheckReportMember
    { path = (.path) member,
      sourceForm = sourceFormText ((.sourceLanguage) member),
      declaredLanguageVersion = declaredLanguageVersionMaybe ((.sourceLanguage) member)
    }

sourceEntry :: FilePath -> Set DiagnosticCode -> Diagnostic -> CheckReportEntry
sourceEntry subject deniedCodes diagnostic =
  CheckReportEntry
    { code = (.code) diagnostic,
      severity = (.severity) diagnostic,
      file = subject,
      line = (.line) diagnostic,
      message = (.message) diagnostic,
      denied = warningDenied deniedCodes ((.severity) diagnostic) ((.code) diagnostic),
      related =
        [ CheckReportRelated subject relatedLineNumber note
        | (relatedLineNumber, note) <- (.relatedLocations) diagnostic
        ]
    }

workspaceEntry :: FilePath -> Set DiagnosticCode -> WorkspaceDiagnostic -> CheckReportEntry
workspaceEntry subject deniedCodes diagnostic =
  CheckReportEntry
    { code = (.code) diagnostic,
      severity = (.severity) diagnostic,
      file = workspaceDisplayPath subject ((.file) primary),
      line = (.line) primary,
      message = (.message) diagnostic,
      denied = warningDenied deniedCodes ((.severity) diagnostic) ((.code) diagnostic),
      related =
        [ CheckReportRelated
            (workspaceDisplayPath subject ((.file) location))
            ((.line) location)
            ((.role) location)
        | location <- NE.tail ((.locations) diagnostic)
        ]
    }
  where
    primary = NE.head ((.locations) diagnostic)

warningDenied :: Set DiagnosticCode -> Severity -> DiagnosticCode -> Bool
warningDenied deniedCodes severityValue diagnosticCode =
  severityValue == Warning && diagnosticCode `Set.member` deniedCodes

instance ToJSON CheckReport where
  toJSON report =
    object
      ( [ "schema" .= ("keiro-dsl/check-report/1" :: Text),
          "kind" .= kindText ((.kind) report),
          "subject" .= (.subject) report,
          "language" .= fmap languageJson ((.language) report),
          "enforcement" .= enforcementJson ((.enforcement) report),
          "diagnostics" .= map entryJson ((.diagnostics) report),
          "summary" .= summaryJson ((.summary) report),
          "ok" .= (.ok) report
        ]
          <> ["members" .= map memberJson ((.members) report) | (.kind) report == WorkspaceReport]
      )

kindText :: CheckReportKind -> Text
kindText SourceReport = "source"
kindText WorkspaceReport = "workspace"

languageJson :: CheckReportLanguage -> Value
languageJson language =
  object
    [ "sourceForm" .= (.sourceForm) language,
      "declaredLanguageVersion" .= (.declaredLanguageVersion) language,
      "effectiveLanguageVersion" .= (.effectiveLanguageVersion) language,
      "runtimeSemantics" .= (.runtimeSemantics) language,
      "languageSupport" .= languageSupportText ((.languageSupport) language),
      "stable" .= (.stable) language
    ]

enforcementJson :: CheckReportEnforcement -> Value
enforcementJson enforcement =
  object
    [ "minLanguage" .= (.minLanguage) enforcement,
      "denyWarnings" .= (.denyWarnings) enforcement,
      "denyCodes" .= map diagnosticCodeText (Set.toAscList (Set.fromList ((.denyCodes) enforcement)))
    ]

entryJson :: CheckReportEntry -> Value
entryJson entry =
  object
    [ "code" .= diagnosticCodeText ((.code) entry),
      "severity" .= severityText ((.severity) entry),
      "file" .= (.file) entry,
      "line" .= (.line) entry,
      "message" .= (.message) entry,
      "denied" .= (.denied) entry,
      "related" .= map relatedJson ((.related) entry)
    ]

relatedJson :: CheckReportRelated -> Value
relatedJson related =
  object
    [ "file" .= (.file) related,
      "line" .= (.line) related,
      "note" .= (.note) related
    ]

summaryJson :: CheckReportSummary -> Value
summaryJson summary =
  object
    [ "errors" .= (.errors) summary,
      "warnings" .= (.warnings) summary,
      "deniedWarnings" .= (.deniedWarnings) summary
    ]

memberJson :: CheckReportMember -> Value
memberJson member =
  object
    [ "path" .= (.path) member,
      "sourceForm" .= (.sourceForm) member,
      "declaredLanguageVersion" .= (.declaredLanguageVersion) member
    ]

severityText :: Severity -> Text
severityText Error = "error"
severityText Warning = "warning"
