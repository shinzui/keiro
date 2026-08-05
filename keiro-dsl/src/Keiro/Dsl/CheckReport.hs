-- | Pure construction and JSON encoding for @check@ reports.
--
-- The JSON schema identifier is @keiro-dsl/check-report/1@. Object keys and
-- array element keys are append-only, and consumers must ignore unknown keys.
-- Source and workspace checks share the schema; workspace inputs add a
-- top-level @members@ array. The report's @ok@ field covers parse-successful
-- semantic validation, minimum-language enforcement, and denied warnings. It
-- deliberately excludes structural/opaque coverage, which has its own report.
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
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.List.NonEmpty qualified as NE
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Keiro.Dsl.LanguageVersion (LanguageSupport (..), LanguageVersion, SourceLanguage, declaredLanguageVersionMaybe, languageSupportText, sourceFormText)
import Keiro.Dsl.SemanticContract (EffectiveLanguageContract, effectiveContractLanguageVersion, effectiveLanguageSupport, effectiveRuntimeSemantics)
import Keiro.Dsl.Validate (Diagnostic (..), DiagnosticCode, Severity (..), diagnosticCodeText)
import Keiro.Dsl.Workspace (WorkspaceDiagnostic (..), WorkspaceLocation (..), WorkspaceMember (..), WorkspaceSpec (..), workspaceDisplayPath)

data CheckReportLanguage = CheckReportLanguage
  { reportSourceForm :: !Text,
    reportDeclaredLanguageVersion :: !(Maybe LanguageVersion),
    reportEffectiveLanguageVersion :: !LanguageVersion,
    reportRuntimeSemantics :: !Text,
    reportLanguageSupport :: !LanguageSupport,
    reportStable :: !Bool
  }
  deriving stock (Eq, Show)

data CheckReportEnforcement = CheckReportEnforcement
  { reportMinLanguage :: !(Maybe LanguageVersion),
    reportDenyWarnings :: !Bool,
    reportDenyCodes :: ![DiagnosticCode]
  }
  deriving stock (Eq, Show)

data CheckReportRelated = CheckReportRelated
  { relatedFile :: !FilePath,
    relatedLine :: !Int,
    relatedNote :: !Text
  }
  deriving stock (Eq, Show)

data CheckReportEntry = CheckReportEntry
  { entryCode :: !DiagnosticCode,
    entrySeverity :: !Severity,
    entryFile :: !FilePath,
    entryLine :: !Int,
    entryMessage :: !Text,
    entryDenied :: !Bool,
    entryRelated :: ![CheckReportRelated]
  }
  deriving stock (Eq, Show)

data CheckReportSummary = CheckReportSummary
  { summaryErrors :: !Int,
    summaryWarnings :: !Int,
    summaryDeniedWarnings :: !Int
  }
  deriving stock (Eq, Show)

data CheckReportMember = CheckReportMember
  { memberPath :: !FilePath,
    memberSourceForm :: !Text,
    memberDeclaredLanguageVersion :: !(Maybe LanguageVersion)
  }
  deriving stock (Eq, Show)

data CheckReportKind = SourceReport | WorkspaceReport
  deriving stock (Eq, Show)

data CheckReport = CheckReport
  { reportKind :: !CheckReportKind,
    reportSubject :: !FilePath,
    reportLanguage :: !CheckReportLanguage,
    reportEnforcement :: !CheckReportEnforcement,
    reportDiagnostics :: ![CheckReportEntry],
    reportSummary :: !CheckReportSummary,
    reportOk :: !Bool,
    reportMembers :: ![CheckReportMember]
  }
  deriving stock (Eq, Show)

-- | Expand one invocation's warning policy to the actual stable-code set used
-- by report entries. @--deny-warnings@ is the union with every registered code.
effectiveDenyCodes :: CheckReportEnforcement -> Set DiagnosticCode
effectiveDenyCodes enforcement
  | reportDenyWarnings enforcement = Set.fromList [minBound .. maxBound]
  | otherwise = Set.fromList (reportDenyCodes enforcement)

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
    (sourceLanguageValue sourceLanguage contract)
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
    (workspaceLanguageValue contract)
    enforcement
    (map (workspaceEntry subject deniedCodes) diagnostics)
    (map memberValue (wsMembers workspace))

buildReport ::
  CheckReportKind ->
  FilePath ->
  CheckReportLanguage ->
  CheckReportEnforcement ->
  [CheckReportEntry] ->
  [CheckReportMember] ->
  CheckReport
buildReport kind subject language enforcement entries members =
  CheckReport
    { reportKind = kind,
      reportSubject = subject,
      reportLanguage = language,
      reportEnforcement = enforcement,
      reportDiagnostics = entries,
      reportSummary = summary,
      reportOk = summaryErrors summary == 0 && summaryDeniedWarnings summary == 0,
      reportMembers = members
    }
  where
    summary =
      CheckReportSummary
        { summaryErrors = length [() | entry <- entries, entrySeverity entry == Error],
          summaryWarnings = length [() | entry <- entries, entrySeverity entry == Warning],
          summaryDeniedWarnings = length [() | entry <- entries, entryDenied entry]
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
    { reportSourceForm = sourceForm,
      reportDeclaredLanguageVersion = declared,
      reportEffectiveLanguageVersion = effectiveContractLanguageVersion contract,
      reportRuntimeSemantics = effectiveRuntimeSemantics contract,
      reportLanguageSupport = support,
      reportStable = support == Stable
    }
  where
    support = effectiveLanguageSupport contract

memberValue :: WorkspaceMember -> CheckReportMember
memberValue member =
  CheckReportMember
    { memberPath = wmPath member,
      memberSourceForm = sourceFormText (wmSourceLanguage member),
      memberDeclaredLanguageVersion = declaredLanguageVersionMaybe (wmSourceLanguage member)
    }

sourceEntry :: FilePath -> Set DiagnosticCode -> Diagnostic -> CheckReportEntry
sourceEntry subject deniedCodes diagnostic =
  CheckReportEntry
    { entryCode = code diagnostic,
      entrySeverity = severity diagnostic,
      entryFile = subject,
      entryLine = line diagnostic,
      entryMessage = message diagnostic,
      entryDenied = warningDenied deniedCodes (severity diagnostic) (code diagnostic),
      entryRelated =
        [ CheckReportRelated subject relatedLineNumber note
        | (relatedLineNumber, note) <- relatedLocations diagnostic
        ]
    }

workspaceEntry :: FilePath -> Set DiagnosticCode -> WorkspaceDiagnostic -> CheckReportEntry
workspaceEntry subject deniedCodes diagnostic =
  CheckReportEntry
    { entryCode = wdCode diagnostic,
      entrySeverity = wdSeverity diagnostic,
      entryFile = workspaceDisplayPath subject (wlFile primary),
      entryLine = wlLine primary,
      entryMessage = wdMessage diagnostic,
      entryDenied = warningDenied deniedCodes (wdSeverity diagnostic) (wdCode diagnostic),
      entryRelated =
        [ CheckReportRelated
            (workspaceDisplayPath subject (wlFile location))
            (wlLine location)
            (wlRole location)
        | location <- NE.tail (wdLocations diagnostic)
        ]
    }
  where
    primary = NE.head (wdLocations diagnostic)

warningDenied :: Set DiagnosticCode -> Severity -> DiagnosticCode -> Bool
warningDenied deniedCodes severityValue diagnosticCode =
  severityValue == Warning && diagnosticCode `Set.member` deniedCodes

instance ToJSON CheckReport where
  toJSON report =
    object
      ( [ "schema" .= ("keiro-dsl/check-report/1" :: Text),
          "kind" .= kindText (reportKind report),
          "subject" .= reportSubject report,
          "language" .= languageJson (reportLanguage report),
          "enforcement" .= enforcementJson (reportEnforcement report),
          "diagnostics" .= map entryJson (reportDiagnostics report),
          "summary" .= summaryJson (reportSummary report),
          "ok" .= reportOk report
        ]
          <> ["members" .= map memberJson (reportMembers report) | reportKind report == WorkspaceReport]
      )

kindText :: CheckReportKind -> Text
kindText SourceReport = "source"
kindText WorkspaceReport = "workspace"

languageJson :: CheckReportLanguage -> Value
languageJson language =
  object
    [ "sourceForm" .= reportSourceForm language,
      "declaredLanguageVersion" .= reportDeclaredLanguageVersion language,
      "effectiveLanguageVersion" .= reportEffectiveLanguageVersion language,
      "runtimeSemantics" .= reportRuntimeSemantics language,
      "languageSupport" .= languageSupportText (reportLanguageSupport language),
      "stable" .= reportStable language
    ]

enforcementJson :: CheckReportEnforcement -> Value
enforcementJson enforcement =
  object
    [ "minLanguage" .= reportMinLanguage enforcement,
      "denyWarnings" .= reportDenyWarnings enforcement,
      "denyCodes" .= map diagnosticCodeText (Set.toAscList (Set.fromList (reportDenyCodes enforcement)))
    ]

entryJson :: CheckReportEntry -> Value
entryJson entry =
  object
    [ "code" .= diagnosticCodeText (entryCode entry),
      "severity" .= severityText (entrySeverity entry),
      "file" .= entryFile entry,
      "line" .= entryLine entry,
      "message" .= entryMessage entry,
      "denied" .= entryDenied entry,
      "related" .= map relatedJson (entryRelated entry)
    ]

relatedJson :: CheckReportRelated -> Value
relatedJson related =
  object
    [ "file" .= relatedFile related,
      "line" .= relatedLine related,
      "note" .= relatedNote related
    ]

summaryJson :: CheckReportSummary -> Value
summaryJson summary =
  object
    [ "errors" .= summaryErrors summary,
      "warnings" .= summaryWarnings summary,
      "deniedWarnings" .= summaryDeniedWarnings summary
    ]

memberJson :: CheckReportMember -> Value
memberJson member =
  object
    [ "path" .= memberPath member,
      "sourceForm" .= memberSourceForm member,
      "declaredLanguageVersion" .= memberDeclaredLanguageVersion member
    ]

severityText :: Severity -> Text
severityText Error = "error"
severityText Warning = "warning"
