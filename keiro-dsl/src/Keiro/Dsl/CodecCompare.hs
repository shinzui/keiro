{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Pure historical-codec comparison and migration-evidence reports.
--
-- The comparison is deliberately finite evidence over typed fixture cases and
-- historical JSON goldens. It never changes which codec owns the wire schema and
-- never upgrades an opaque declaration to a structural claim.
module Keiro.Dsl.CodecCompare
  ( FixtureOrigin (..),
    DecodeOutcome (..),
    JsonPointer (..),
    unJsonPointer,
    ComparisonDifference (..),
    HistoricalCodec (..),
    CompareObservation (..),
    FixtureVerdict (..),
    CompareInputIssue (..),
    BranchKind (..),
    DeclaredBranch (..),
    ObservedBranch (..),
    CoverageGap (..),
    BranchSchema (..),
    BranchField (..),
    BranchArm (..),
    CompareProvenance (..),
    ClassifiedObservation (..),
    CompareReport (..),
    ReportWriteError (..),
    authorityStatement,
    canonicalJsonBytes,
    classifyObservation,
    declaredBranchesFor,
    observedBranchesFor,
    compareReport,
    renderCompareReport,
    reportSucceeded,
    writeCompareReportAtomic,
  )
where

import Control.Exception (IOException, bracketOnError, displayException, try)
import Control.Monad (when)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, withText, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.RFC8785 qualified as RFC8785
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.TypeGraph (BindingVersion (..), CanonicalTypeId (..), QualifiedValueName (..))
import Keiro.Dsl.Validate (DiagnosticCode (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (Handle, hClose, openBinaryTempFile)

data FixtureOrigin = HistoricalGolden | FromBinding
  deriving stock (Eq, Ord, Show)

data DecodeOutcome
  = DecodedShape !Value
  | DecodeFailed !Text
  deriving stock (Eq, Show)

newtype JsonPointer = JsonPointer {unJsonPointer :: Text}
  deriving stock (Eq, Ord, Show)

unJsonPointer :: JsonPointer -> Text
unJsonPointer (JsonPointer value) = value

data ComparisonDifference
  = EncodedValueDifference !JsonPointer !Value !Value
  | DecodedValueDifference !JsonPointer !Value !Value
  | GeneratedDecodeRejected !Text
  deriving stock (Eq, Show)

-- | A historical codec is an explicit value supplied by consumer-owned test
-- code. Its identity and version are report provenance, not dispatch keys.
data HistoricalCodec a = HistoricalCodec
  { identity :: !Text,
    version :: !Text,
    encode :: !(a -> Value),
    decode :: !(Value -> Either Text a)
  }

data CompareObservation
  = EncodeObservation
      { caseName :: !Text,
        historicalValue :: !Value,
        generatedValue :: !Value
      }
  | DecodeObservation
      { fixturePath :: !FilePath,
        inputValue :: !Value,
        historicalDecode :: !DecodeOutcome,
        generatedDecode :: !DecodeOutcome
      }
  deriving stock (Eq, Show)

data FixtureVerdict
  = JsonParity
  | RequiresVersionWork !ComparisonDifference
  deriving stock (Eq, Show)

data CompareInputIssue
  = HistoricalGoldenUnreadable !FilePath !Text
  | HistoricalCodecRejected !FilePath !Text
  | HistoricalCodecProvenanceInvalid !Text
  deriving stock (Eq, Show)

data BranchKind
  = UnionArm !Text
  | OptionalPresent
  | OptionalMissing
  | ExplicitNull
  deriving stock (Eq, Ord, Show)

data DeclaredBranch = DeclaredBranch
  { origin :: !FixtureOrigin,
    pointer :: !JsonPointer,
    kind :: !BranchKind
  }
  deriving stock (Eq, Ord, Show)

data ObservedBranch = ObservedBranch
  { origin :: !FixtureOrigin,
    pointer :: !JsonPointer,
    kind :: !BranchKind
  }
  deriving stock (Eq, Ord, Show)

data CoverageGap = CoverageGap
  { origin :: !FixtureOrigin,
    pointer :: !JsonPointer,
    kind :: !BranchKind
  }
  deriving stock (Eq, Ord, Show)

-- | A codec-independent branch description embedded into generated
-- comparison runners. The generator constructs it through the checked type
-- graph's total algebras, so this module never has to interpret a consumer type.
data BranchSchema
  = BranchScalar
  | BranchOptional !BranchSchema
  | BranchList !BranchSchema
  | BranchMap !BranchSchema
  | BranchRecord ![BranchField]
  | BranchUnion !Text !Text ![BranchArm]
  deriving stock (Eq, Show)

data BranchField = BranchField
  { wireKey :: !Text,
    presenceOptional :: !Bool,
    schema :: !BranchSchema
  }
  deriving stock (Eq, Show)

data BranchArm = BranchArm
  { wireTag :: !Text,
    payloadSchema :: !(Maybe BranchSchema)
  }
  deriving stock (Eq, Show)

data CompareProvenance = CompareProvenance
  { historicalCodecIdentity :: !Text,
    historicalCodecVersion :: !Text,
    canonicalType :: !CanonicalTypeId,
    bindingSymbol :: !QualifiedValueName,
    bindingVersion :: !BindingVersion,
    wireFingerprint :: !Text
  }
  deriving stock (Eq, Show)

data ClassifiedObservation = ClassifiedObservation
  { origin :: !FixtureOrigin,
    name :: !Text,
    verdict :: !FixtureVerdict
  }
  deriving stock (Eq, Show)

data CompareReport = CompareReport
  { provenance :: !CompareProvenance,
    observations :: ![ClassifiedObservation],
    inputIssues :: ![CompareInputIssue],
    coverageGaps :: ![CoverageGap],
    authority :: !Text
  }
  deriving stock (Eq, Show)

data ReportWriteError = ReportWriteError
  { path :: !FilePath,
    message :: !Text
  }
  deriving stock (Eq, Show)

authorityStatement :: Text
authorityStatement =
  "This comparison is MIGRATION EVIDENCE ONLY. After cutover the generated structural codec is the sole wire authority. This runner is never a runtime fallback and never upgrades an opaque declaration to structural. Resolve each difference with an explicit version bump and upcaster, or correct the declaration to match the historical wire contract; \"close enough\" is not an outcome."

-- | Render a JSON value in RFC 8785 canonical form.
canonicalJsonBytes :: Value -> ByteString
canonicalJsonBytes = LazyByteString.toStrict . RFC8785.encodeCanonical

classifyObservation :: CompareObservation -> Either CompareInputIssue FixtureVerdict
classifyObservation observation = case observation of
  EncodeObservation _ historical generated ->
    Right (classifyValues EncodedValueDifference historical generated)
  DecodeObservation fixturePath _ historical generated -> case historical of
    DecodeFailed reason -> Left (HistoricalCodecRejected fixturePath reason)
    DecodedShape historicalValue -> case generated of
      DecodeFailed reason -> Right (RequiresVersionWork (GeneratedDecodeRejected reason))
      DecodedShape generatedValue ->
        Right (classifyValues DecodedValueDifference historicalValue generatedValue)

classifyValues :: (JsonPointer -> Value -> Value -> ComparisonDifference) -> Value -> Value -> FixtureVerdict
classifyValues difference historical generated
  | canonicalJsonBytes historical == canonicalJsonBytes generated = JsonParity
  | otherwise = RequiresVersionWork (difference (firstDivergentPointer historical generated) historical generated)

compareReport ::
  CompareProvenance ->
  [CompareInputIssue] ->
  [CompareObservation] ->
  [DeclaredBranch] ->
  [ObservedBranch] ->
  CompareReport
compareReport provenance suppliedIssues observations declaredBranches observedBranches =
  CompareReport
    { provenance = provenance,
      observations = classified,
      inputIssues = provenanceIssues provenance <> suppliedIssues <> classificationIssues,
      coverageGaps = coverageGaps declaredBranches observedBranches,
      authority = authorityStatement
    }
  where
    outcomes = map classify observations
    classified = [value | Right value <- outcomes]
    classificationIssues = [issue | Left issue <- outcomes]

    classify observation = case classifyObservation observation of
      Left issue -> Left issue
      Right verdict ->
        Right
          ClassifiedObservation
            { origin = observationOrigin observation,
              name = observationName observation,
              verdict = verdict
            }

observationOrigin :: CompareObservation -> FixtureOrigin
observationOrigin EncodeObservation {} = FromBinding
observationOrigin DecodeObservation {} = HistoricalGolden

observationName :: CompareObservation -> Text
observationName EncodeObservation {caseName = name} = name
observationName DecodeObservation {fixturePath = path} = T.pack path

provenanceIssues :: CompareProvenance -> [CompareInputIssue]
provenanceIssues provenance =
  [ HistoricalCodecProvenanceInvalid "historical codec identity must not be blank"
  | T.null (T.strip ((.historicalCodecIdentity) provenance))
  ]
    <> [ HistoricalCodecProvenanceInvalid "historical codec version must not be blank"
       | T.null (T.strip ((.historicalCodecVersion) provenance))
       ]

coverageGaps :: [DeclaredBranch] -> [ObservedBranch] -> [CoverageGap]
coverageGaps declared observed =
  [ CoverageGap ((.origin) branch) ((.pointer) branch) ((.kind) branch)
  | branch <- declared,
    branchKey branch `Set.notMember` observedKeys
  ]
  where
    observedKeys = Set.fromList (map observedBranchKey observed)
    branchKey branch = ((.origin) branch, (.pointer) branch, (.kind) branch)
    observedBranchKey branch = ((.origin) branch, (.pointer) branch, (.kind) branch)

declaredBranchesFor :: FixtureOrigin -> BranchSchema -> [DeclaredBranch]
declaredBranchesFor origin = Set.toAscList . go ""
  where
    declared pointer kind = Set.singleton (DeclaredBranch origin (JsonPointer pointer) kind)
    go pointer schema = case schema of
      BranchScalar -> Set.empty
      BranchOptional nested ->
        declared pointer OptionalPresent
          <> declared pointer ExplicitNull
          <> go pointer nested
      BranchList nested -> go (appendPointer pointer "*") nested
      BranchMap nested -> go (appendPointer pointer "*") nested
      BranchRecord fields ->
        Set.unions
          [ presenceBranches pointer field <> go (appendPointer pointer ((.wireKey) field)) ((.schema) field)
          | field <- fields
          ]
      BranchUnion _tagField contentsField arms ->
        Set.unions
          [ declared pointer (UnionArm ((.wireTag) arm))
              <> maybe Set.empty (go (appendPointer pointer contentsField)) ((.payloadSchema) arm)
          | arm <- arms
          ]
    presenceBranches pointer field
      | (.presenceOptional) field =
          let fieldPointer = appendPointer pointer ((.wireKey) field)
           in case origin of
                HistoricalGolden -> declared fieldPointer OptionalMissing <> declared fieldPointer OptionalPresent
                FromBinding -> declared fieldPointer OptionalPresent
      | otherwise = Set.empty

observedBranchesFor :: FixtureOrigin -> BranchSchema -> Value -> [ObservedBranch]
observedBranchesFor origin schema = Set.toAscList . go "" schema
  where
    observed pointer kind = Set.singleton (ObservedBranch origin (JsonPointer pointer) kind)
    go pointer branchSchema value = case branchSchema of
      BranchScalar -> Set.empty
      BranchOptional nested -> case value of
        Null -> observed pointer ExplicitNull
        _ -> observed pointer OptionalPresent <> go pointer nested value
      BranchList nested -> case value of
        Array values -> Set.unions [go (appendPointer pointer "*") nested item | item <- toList values]
        _ -> Set.empty
      BranchMap nested -> case value of
        Object values -> Set.unions [go (appendPointer pointer "*") nested item | item <- KeyMap.elems values]
        _ -> Set.empty
      BranchRecord fields -> case value of
        Object values -> Set.unions (map (observeField pointer values) fields)
        _ -> Set.empty
      BranchUnion tagField contentsField arms -> case value of
        Object values -> case KeyMap.lookup (Key.fromText tagField) values of
          Just (String tag) -> case filter ((== tag) . (.wireTag)) arms of
            arm : _ ->
              observed pointer (UnionArm tag)
                <> case ((.payloadSchema) arm, KeyMap.lookup (Key.fromText contentsField) values) of
                  (Just nested, Just payload) -> go (appendPointer pointer contentsField) nested payload
                  _ -> Set.empty
            [] -> Set.empty
          _ -> Set.empty
        _ -> Set.empty
    observeField pointer values field =
      let fieldPointer = appendPointer pointer ((.wireKey) field)
       in case KeyMap.lookup (Key.fromText ((.wireKey) field)) values of
            Nothing
              | (.presenceOptional) field -> observed fieldPointer OptionalMissing
              | otherwise -> Set.empty
            Just fieldValue ->
              (if (.presenceOptional) field then observed fieldPointer OptionalPresent else Set.empty)
                <> go fieldPointer ((.schema) field) fieldValue

reportSucceeded :: CompareReport -> Bool
reportSucceeded report =
  null ((.inputIssues) report)
    && null ((.coverageGaps) report)
    && all ((== JsonParity) . (.verdict)) ((.observations) report)

renderCompareReport :: CompareReport -> Text
renderCompareReport report =
  T.unlines
    ( [ "codec comparison: "
          <> (.unCanonicalTypeId) ((.canonicalType) provenance)
          <> " (binding-version \""
          <> (.unBindingVersion) ((.bindingVersion) provenance)
          <> "\")",
        "historical codec: \""
          <> (.historicalCodecIdentity) provenance
          <> "\" version \""
          <> (.historicalCodecVersion) provenance
          <> "\"",
        "observations: " <> tshow (length observations),
        "  encode parity: " <> ratio FromBinding,
        "  structural decode agreement: " <> ratio HistoricalGolden,
        "requires explicit version/upcaster work: " <> tshow (length differences) <> " observations  [" <> codeText CodecCompareDifference <> "]"
      ]
        <> concatMap renderDifference differences
        <> [ "input issues: " <> tshow (length ((.inputIssues) report)) <> "  [" <> codeText CodecCompareInvalidInput <> "]"
           ]
        <> map ("  " <>) (map renderInputIssue ((.inputIssues) report))
        <> [ "coverage gaps: " <> tshow (length ((.coverageGaps) report)) <> "  [" <> codeText CodecCompareCoverageGap <> "]"
           ]
        <> map ("  " <>) (map renderCoverageGap ((.coverageGaps) report))
        <> [ if reportSucceeded report
               then "result: PARITY"
               else "result: NOT PARITY — " <> tshow (length differences) <> " differences",
             (.authority) report
           ]
    )
  where
    provenance = (.provenance) report
    observations = (.observations) report
    differences = filter ((/= JsonParity) . (.verdict)) observations
    ratio origin =
      let matching = filter ((== origin) . (.origin)) observations
          parityCount = length (filter ((== JsonParity) . (.verdict)) matching)
       in tshow parityCount <> "/" <> tshow (length matching) <> suffix origin
    suffix FromBinding = " (RFC 8785 canonical form)"
    suffix HistoricalGolden = ""

renderDifference :: ClassifiedObservation -> [Text]
renderDifference observation = case (.verdict) observation of
  JsonParity -> []
  RequiresVersionWork difference ->
    [ "  " <> (.name) observation <> " [" <> direction <> "] at " <> pointerOf difference,
      "    " <> reasonOf difference
    ]
  where
    direction = case (.origin) observation of
      FromBinding -> "encode"
      HistoricalGolden -> "decode"

renderInputIssue :: CompareInputIssue -> Text
renderInputIssue issue = case issue of
  HistoricalGoldenUnreadable path reason -> T.pack path <> ": unreadable historical golden: " <> reason
  HistoricalCodecRejected path reason -> T.pack path <> ": historical codec rejected its alleged golden: " <> reason
  HistoricalCodecProvenanceInvalid reason -> reason

renderCoverageGap :: CoverageGap -> Text
renderCoverageGap gap =
  originName ((.origin) gap)
    <> " "
    <> renderPointer ((.pointer) gap)
    <> ": "
    <> branchKindName ((.kind) gap)

pointerOf :: ComparisonDifference -> Text
pointerOf difference = case difference of
  EncodedValueDifference pointer _ _ -> renderPointer pointer
  DecodedValueDifference pointer _ _ -> renderPointer pointer
  GeneratedDecodeRejected _ -> "<root>"

reasonOf :: ComparisonDifference -> Text
reasonOf difference = case difference of
  EncodedValueDifference _ historical generated ->
    "historical and generated encoders produced different JSON values: " <> valuePair historical generated
  DecodedValueDifference _ historical generated ->
    "historical and generated decoders normalized to different structural values: " <> valuePair historical generated
  GeneratedDecodeRejected reason -> "generated structural decoder rejected historical JSON: " <> reason

valuePair :: Value -> Value -> Text
valuePair historical generated = "historical=" <> tshow historical <> "; generated=" <> tshow generated

renderPointer :: JsonPointer -> Text
renderPointer (JsonPointer pointer)
  | T.null pointer = "<root>"
  | otherwise = pointer

writeCompareReportAtomic :: FilePath -> CompareReport -> IO (Either ReportWriteError ())
writeCompareReportAtomic path report = do
  let directory = takeDirectory path
      template = takeFileName path <> ".tmp"
  result <- try $ do
    createDirectoryIfMissing True directory
    bracketOnError
      (openBinaryTempFile directory template)
      cleanupTemporary
      ( \(temporary, handle) -> do
          LazyByteString.hPut handle (Aeson.encode report)
          hClose handle
          renameFile temporary path
      )
  pure $ case result of
    Left err -> Left (ReportWriteError path (T.pack (displayException (err :: IOException))))
    Right () -> Right ()

cleanupTemporary :: (FilePath, Handle) -> IO ()
cleanupTemporary (temporary, handle) = do
  _ <- try (hClose handle) :: IO (Either IOException ())
  exists <- doesFileExist temporary
  when exists (removeFile temporary)

firstDivergentPointer :: Value -> Value -> JsonPointer
firstDivergentPointer = go ""
  where
    go pointer (Object historical) (Object generated) =
      case firstDifferentKey historical generated of
        Nothing -> JsonPointer pointer
        Just key -> case (KeyMap.lookup (Key.fromText key) historical, KeyMap.lookup (Key.fromText key) generated) of
          (Just historicalValue, Just generatedValue) -> go (appendPointer pointer key) historicalValue generatedValue
          _ -> JsonPointer (appendPointer pointer key)
    go pointer (Array historical) (Array generated) =
      let historicalValues = toList historical
          generatedValues = toList generated
       in case firstDifferentIndex historicalValues generatedValues of
            Nothing -> JsonPointer pointer
            Just index -> case (indexMaybe index historicalValues, indexMaybe index generatedValues) of
              (Just historicalValue, Just generatedValue) -> go (appendPointer pointer (tshow index)) historicalValue generatedValue
              _ -> JsonPointer (appendPointer pointer (tshow index))
    go pointer _ _ = JsonPointer pointer

firstDifferentKey :: KeyMap.KeyMap Value -> KeyMap.KeyMap Value -> Maybe Text
firstDifferentKey historical generated =
  firstMatch differs allKeys
  where
    allKeys = sort (map Key.toText (KeyMap.keys historical <> KeyMap.keys generated))
    differs key = KeyMap.lookup (Key.fromText key) historical /= KeyMap.lookup (Key.fromText key) generated

firstDifferentIndex :: [Value] -> [Value] -> Maybe Int
firstDifferentIndex historical generated =
  firstMatch differs [0 .. max (length historical) (length generated) - 1]
  where
    differs index = indexMaybe index historical /= indexMaybe index generated

indexMaybe :: Int -> [a] -> Maybe a
indexMaybe index values = case drop index values of
  value : _ -> Just value
  [] -> Nothing

firstMatch :: (a -> Bool) -> [a] -> Maybe a
firstMatch predicate = \case
  [] -> Nothing
  value : rest
    | predicate value -> Just value
    | otherwise -> firstMatch predicate rest

appendPointer :: Text -> Text -> Text
appendPointer base segment = base <> "/" <> escapePointerSegment segment

escapePointerSegment :: Text -> Text
escapePointerSegment = T.replace "/" "~1" . T.replace "~" "~0"

tshow :: (Show a) => a -> Text
tshow = T.pack . show

codeText :: DiagnosticCode -> Text
codeText = T.pack . show

originName :: FixtureOrigin -> Text
originName HistoricalGolden = "historical-golden"
originName FromBinding = "typed-fixture"

parseOrigin :: Text -> Parser FixtureOrigin
parseOrigin "historical-golden" = pure HistoricalGolden
parseOrigin "typed-fixture" = pure FromBinding
parseOrigin value = fail ("unknown fixture origin: " <> T.unpack value)

branchKindName :: BranchKind -> Text
branchKindName kind = case kind of
  UnionArm arm -> "union-arm:" <> arm
  OptionalPresent -> "optional-present"
  OptionalMissing -> "optional-missing"
  ExplicitNull -> "explicit-null"

parseBranchKind :: Text -> Parser BranchKind
parseBranchKind value
  | Just arm <- T.stripPrefix "union-arm:" value = pure (UnionArm arm)
  | value == "optional-present" = pure OptionalPresent
  | value == "optional-missing" = pure OptionalMissing
  | value == "explicit-null" = pure ExplicitNull
  | otherwise = fail ("unknown branch kind: " <> T.unpack value)

instance ToJSON FixtureOrigin where
  toJSON = String . originName

instance FromJSON FixtureOrigin where
  parseJSON = withText "FixtureOrigin" parseOrigin

instance ToJSON JsonPointer where
  toJSON = String . unJsonPointer

instance FromJSON JsonPointer where
  parseJSON = withText "JsonPointer" (pure . JsonPointer)

instance ToJSON BranchKind where
  toJSON = String . branchKindName

instance FromJSON BranchKind where
  parseJSON = withText "BranchKind" parseBranchKind

instance ToJSON ComparisonDifference where
  toJSON difference = case difference of
    EncodedValueDifference pointer historical generated ->
      differenceObject "encoded-value-difference" pointer "encoder outputs differ" historical generated
    DecodedValueDifference pointer historical generated ->
      differenceObject "decoded-value-difference" pointer "normalized decoder outputs differ" historical generated
    GeneratedDecodeRejected reason ->
      object
        [ "kind" .= ("generated-decode-rejected" :: Text),
          "pointer" .= JsonPointer "",
          "reason" .= reason
        ]
    where
      differenceObject kind pointer reason historical generated =
        object
          [ "kind" .= (kind :: Text),
            "pointer" .= pointer,
            "reason" .= (reason :: Text),
            "historical" .= historical,
            "generated" .= generated
          ]

instance FromJSON ComparisonDifference where
  parseJSON = withObject "ComparisonDifference" $ \value -> do
    kind <- value .: "kind" :: Parser Text
    case kind of
      "encoded-value-difference" -> EncodedValueDifference <$> value .: "pointer" <*> value .: "historical" <*> value .: "generated"
      "decoded-value-difference" -> DecodedValueDifference <$> value .: "pointer" <*> value .: "historical" <*> value .: "generated"
      "generated-decode-rejected" -> GeneratedDecodeRejected <$> value .: "reason"
      _ -> fail ("unknown comparison difference: " <> T.unpack kind)

instance ToJSON FixtureVerdict where
  toJSON JsonParity = object ["verdict" .= ("json-parity" :: Text)]
  toJSON (RequiresVersionWork difference) =
    object
      [ "verdict" .= ("requires-version-work" :: Text),
        "code" .= codeText CodecCompareDifference,
        "difference" .= difference
      ]

instance FromJSON FixtureVerdict where
  parseJSON = withObject "FixtureVerdict" $ \value -> do
    verdict <- value .: "verdict" :: Parser Text
    case verdict of
      "json-parity" -> pure JsonParity
      "requires-version-work" -> RequiresVersionWork <$> value .: "difference"
      _ -> fail ("unknown fixture verdict: " <> T.unpack verdict)

instance ToJSON CompareInputIssue where
  toJSON issue = case issue of
    HistoricalGoldenUnreadable path reason -> issueObject "historical-golden-unreadable" path reason
    HistoricalCodecRejected path reason -> issueObject "historical-codec-rejected" path reason
    HistoricalCodecProvenanceInvalid reason ->
      object
        [ "code" .= codeText CodecCompareInvalidInput,
          "kind" .= ("historical-codec-provenance-invalid" :: Text),
          "reason" .= reason
        ]
    where
      issueObject kind path reason =
        object
          [ "code" .= codeText CodecCompareInvalidInput,
            "kind" .= (kind :: Text),
            "path" .= path,
            "reason" .= reason
          ]

instance FromJSON CompareInputIssue where
  parseJSON = withObject "CompareInputIssue" $ \value -> do
    kind <- value .: "kind" :: Parser Text
    case kind of
      "historical-golden-unreadable" -> HistoricalGoldenUnreadable <$> value .: "path" <*> value .: "reason"
      "historical-codec-rejected" -> HistoricalCodecRejected <$> value .: "path" <*> value .: "reason"
      "historical-codec-provenance-invalid" -> HistoricalCodecProvenanceInvalid <$> value .: "reason"
      _ -> fail ("unknown comparison input issue: " <> T.unpack kind)

instance ToJSON DeclaredBranch where
  toJSON branch =
    object
      [ "origin" .= (.origin) branch,
        "pointer" .= (.pointer) branch,
        "branch" .= (.kind) branch
      ]

instance FromJSON DeclaredBranch where
  parseJSON = withObject "DeclaredBranch" $ \value ->
    DeclaredBranch <$> value .: "origin" <*> value .: "pointer" <*> value .: "branch"

instance ToJSON ObservedBranch where
  toJSON branch =
    object
      [ "origin" .= (.origin) branch,
        "pointer" .= (.pointer) branch,
        "branch" .= (.kind) branch
      ]

instance FromJSON ObservedBranch where
  parseJSON = withObject "ObservedBranch" $ \value ->
    ObservedBranch <$> value .: "origin" <*> value .: "pointer" <*> value .: "branch"

instance ToJSON CoverageGap where
  toJSON gap =
    object
      [ "code" .= codeText CodecCompareCoverageGap,
        "origin" .= (.origin) gap,
        "pointer" .= (.pointer) gap,
        "branch" .= (.kind) gap
      ]

instance FromJSON CoverageGap where
  parseJSON = withObject "CoverageGap" $ \value ->
    CoverageGap <$> value .: "origin" <*> value .: "pointer" <*> value .: "branch"

instance ToJSON CompareProvenance where
  toJSON provenance =
    object
      [ "historicalCodecIdentity" .= (.historicalCodecIdentity) provenance,
        "historicalCodecVersion" .= (.historicalCodecVersion) provenance,
        "canonicalType" .= (.unCanonicalTypeId) ((.canonicalType) provenance),
        "bindingSymbol" .= (.unQualifiedValueName) ((.bindingSymbol) provenance),
        "bindingVersion" .= (.unBindingVersion) ((.bindingVersion) provenance),
        "wireFingerprint" .= (.wireFingerprint) provenance
      ]

instance FromJSON CompareProvenance where
  parseJSON = withObject "CompareProvenance" $ \value ->
    CompareProvenance
      <$> value .: "historicalCodecIdentity"
      <*> value .: "historicalCodecVersion"
      <*> (CanonicalTypeId <$> value .: "canonicalType")
      <*> (QualifiedValueName <$> value .: "bindingSymbol")
      <*> (BindingVersion <$> value .: "bindingVersion")
      <*> value .: "wireFingerprint"

instance ToJSON ClassifiedObservation where
  toJSON observation =
    object
      [ "origin" .= (.origin) observation,
        "name" .= (.name) observation,
        "result" .= (.verdict) observation
      ]

instance FromJSON ClassifiedObservation where
  parseJSON = withObject "ClassifiedObservation" $ \value ->
    ClassifiedObservation <$> value .: "origin" <*> value .: "name" <*> value .: "result"

instance ToJSON CompareReport where
  toJSON report =
    object
      [ "schema" .= ("keiro-dsl/codec-compare-report/1" :: Text),
        "authority" .= (.authority) report,
        "provenance" .= (.provenance) report,
        "success" .= reportSucceeded report,
        "summary"
          .= object
            [ "observations" .= length ((.observations) report),
              "parity" .= length (filter ((== JsonParity) . (.verdict)) ((.observations) report)),
              "differences" .= length (filter ((/= JsonParity) . (.verdict)) ((.observations) report)),
              "inputIssues" .= length ((.inputIssues) report),
              "coverageGaps" .= length ((.coverageGaps) report)
            ],
        "observations" .= (.observations) report,
        "inputIssues" .= (.inputIssues) report,
        "coverageGaps" .= (.coverageGaps) report
      ]

instance FromJSON CompareReport where
  parseJSON = withObject "CompareReport" $ \value ->
    CompareReport
      <$> value .: "provenance"
      <*> value .: "observations"
      <*> value .: "inputIssues"
      <*> value .: "coverageGaps"
      <*> value .: "authority"
