{-# LANGUAGE MultilineStrings #-}

-- | Managed, versioned PostgreSQL functions for out-of-process read-model
-- consumers. Callers receive execute-only functions in @keiro_read@; target
-- tables and the private binding views remain inaccessible.
module Keiro.ReadModel.External
  ( ExternalReadReconciliationError (..),
    ExternalReadRetirementError (..),
    ExternalReadRetirementPreview (..),
    reconcileExternalReadContracts,
    reconcileExternalReadContractsTx,
    reconcileExternalReadContractsForGroupsTx,
    previewExternalReadContractRetirement,
    retireExternalReadContract,
  )
where

import Contravariant.Extras (contrazip18, contrazip2, contrazip4, contrazip9)
import Control.Monad (join)
import Data.Foldable (toList)
import Data.Functor (($>))
import Data.Int (Int32)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Connection (qualifyTable, quoteIdentifier)
import Keiro.Prelude
import Keiro.Projection.Catalog
  ( ExternalReadContractId,
    ExternalReadContractKind (..),
    ExternalReadContractVersion,
    QualifiedFunction (..),
    QualifiedSqlType (..),
    RebuildGroupId,
    ValidatedProjectionCatalog,
    catalogInventory,
    externalReadContractIdText,
    externalReadContractVersionValue,
    projectionRevisionIdText,
    queryModelIdText,
    rebuildGroupIdText,
  )
import Keiro.Projection.Catalog qualified as Catalog
import Keiro.Projection.Catalog.Preimage (Preimage (..), hashPreimage)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude (fromIntegral, map, maximum, not, zip, (&&))
import Prelude qualified

data ExternalReadReconciliationError
  = ExternalReadAllRowsRequiresSingleTarget !ExternalReadContractId !ExternalReadContractVersion
  | ExternalReadResultTypeMissing !QualifiedSqlType
  | ExternalReadResultTypeNotComposite !QualifiedSqlType
  | ExternalReadPrivateImplementationMissing !QualifiedFunction
  | ExternalReadPrivateImplementationResultMismatch !QualifiedFunction !QualifiedSqlType
  | ExternalReadImmutableSignatureConflict !ExternalReadContractId !ExternalReadContractVersion
  | ExternalReadDefinitionGenerationConflict !ExternalReadContractId !ExternalReadContractVersion !Int
  | ExternalReadSurfaceDowngrade !ExternalReadContractId !ExternalReadContractVersion !Int !Int
  | ExternalReadRetiredContractCannotReactivate !ExternalReadContractId !ExternalReadContractVersion
  | ExternalReadUnmanagedObjectCollision !Text !Text !Text
  | ExternalReadManagedObjectOwnershipConflict !Text !Text !Text
  deriving stock (Eq, Show, Generic)

data ExternalReadRetirementError
  = ExternalReadRetirementUnknown !ExternalReadContractId !ExternalReadContractVersion
  | ExternalReadRetirementAlreadyRetired !ExternalReadContractId !ExternalReadContractVersion
  deriving stock (Eq, Show, Generic)

data ExternalReadRetirementPreview = ExternalReadRetirementPreview
  { contractId :: !ExternalReadContractId,
    contractVersion :: !ExternalReadContractVersion,
    publicFunction :: !Text,
    currentState :: !Text,
    surfaceGeneration :: !Int,
    dependentObjects :: ![Text],
    executeGrants :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

data ExternalReadSpec = ExternalReadSpec
  { contractId :: !ExternalReadContractId,
    contractVersion :: !ExternalReadContractVersion,
    queryModelId :: !Catalog.QueryModelId,
    groupId :: !RebuildGroupId,
    functionName :: !Text,
    contractKind :: !ExternalReadContractKind,
    argumentNames :: ![Text],
    argumentTypes :: ![QualifiedSqlType],
    resultType :: !QualifiedSqlType,
    resultShapeHash :: !Text,
    compatibleRevisions :: ![Catalog.ProjectionRevisionId],
    privateImplementation :: !(Maybe QualifiedFunction),
    privateImplementationVersion :: !(Maybe Int),
    surfaceGeneration :: !Int,
    bindingTable :: !(Maybe Catalog.QualifiedTable)
  }
  deriving stock (Eq, Show, Generic)

data PersistedContract = PersistedContract
  { immutableSignatureHash :: !Text,
    definitionHash :: !Text,
    surfaceGeneration :: !Int,
    state :: !Text
  }
  deriving stock (Eq, Show, Generic)

data PersistedContractKey = PersistedContractKey
  { contractIdText :: !Text,
    contractVersionValue :: !Int,
    groupIdText :: !Text,
    surfaceGeneration :: !Int,
    state :: !Text
  }
  deriving stock (Eq, Show, Generic)

data ManagedObject = ManagedObject
  { managedBy :: !Text,
    definitionHash :: !Text,
    surfaceGeneration :: !Int
  }
  deriving stock (Eq, Show, Generic)

data ContractState = ContractState
  { stateName :: !Text,
    servingShapeHash :: !(Maybe Text)
  }
  deriving stock (Generic)

reconcileExternalReadContracts ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  Eff es (Either ExternalReadReconciliationError ())
reconcileExternalReadContracts catalog =
  runTransaction (reconcileExternalReadContractsTx catalog)

-- | Reconcile the complete catalog. Any refusal condemns the transaction, so
-- partially-created functions, views, metadata, and revokes never escape.
reconcileExternalReadContractsTx ::
  ValidatedProjectionCatalog ->
  Tx.Transaction (Either ExternalReadReconciliationError ())
reconcileExternalReadContractsTx catalog =
  reconcileExternalReadContractsForGroupsTx catalog Nothing

-- | Reconcile only contracts owned by the selected groups. @Nothing@ means
-- the complete catalog and also marks superseded absent contracts pending
-- retirement. A selected adoption never mutates another group's surface.
reconcileExternalReadContractsForGroupsTx ::
  ValidatedProjectionCatalog ->
  Maybe (Set RebuildGroupId) ->
  Tx.Transaction (Either ExternalReadReconciliationError ())
reconcileExternalReadContractsForGroupsTx catalog selectedGroups =
  case externalReadSpecs catalog selectedGroups of
    Left err -> Tx.condemn $> Left err
    Right specs -> do
      result <- reconcileSpecs specs
      case result of
        Left err -> Tx.condemn $> Left err
        Right () -> do
          markAbsentPending specs
          pure (Right ())
  where
    reconcileSpecs = \case
      [] -> pure (Right ())
      spec : rest -> do
        result <- reconcileOne spec
        case result of
          Left err -> pure (Left err)
          Right () -> reconcileSpecs rest

    reconcileOne spec = do
      let signatureHash = immutableSignature spec
          requestedDefinitionHash = definitionIdentity spec
          requestedGeneration = spec ^. #surfaceGeneration
      existing <-
        Tx.statement
          (externalReadKey spec)
          lookupContractStmt
      case existing of
        Just persisted
          | persisted ^. #immutableSignatureHash /= signatureHash ->
              pure (Left (ExternalReadImmutableSignatureConflict (spec ^. #contractId) (spec ^. #contractVersion)))
          | persisted ^. #surfaceGeneration > requestedGeneration ->
              pure
                ( Left
                    ( ExternalReadSurfaceDowngrade
                        (spec ^. #contractId)
                        (spec ^. #contractVersion)
                        (persisted ^. #surfaceGeneration)
                        requestedGeneration
                    )
                )
          | persisted ^. #state == "retired" ->
              pure (Left (ExternalReadRetiredContractCannotReactivate (spec ^. #contractId) (spec ^. #contractVersion)))
          | persisted ^. #surfaceGeneration == requestedGeneration,
            persisted ^. #definitionHash /= requestedDefinitionHash ->
              pure
                ( Left
                    ( ExternalReadDefinitionGenerationConflict
                        (spec ^. #contractId)
                        (spec ^. #contractVersion)
                        requestedGeneration
                    )
                )
        _ -> do
          typeExists <- Tx.statement (renderSqlType (spec ^. #resultType)) typeExistsStmt
          if not typeExists
            then pure (Left (ExternalReadResultTypeMissing (spec ^. #resultType)))
            else do
              resultColumns <- Tx.statement (renderSqlType (spec ^. #resultType)) compositeTypeColumnsStmt
              if Prelude.null resultColumns
                then pure (Left (ExternalReadResultTypeNotComposite (spec ^. #resultType)))
                else do
                  implementationResult <- verifyPrivateImplementation spec
                  case implementationResult of
                    Left err -> pure (Left err)
                    Right () -> do
                      contractState <- resolveContractState spec
                      persisted <-
                        Tx.statement
                          (contractParams spec signatureHash requestedDefinitionHash contractState)
                          upsertContractStmt
                      if not persisted
                        then
                          pure
                            ( Left
                                ( ExternalReadDefinitionGenerationConflict
                                    (spec ^. #contractId)
                                    (spec ^. #contractVersion)
                                    requestedGeneration
                                )
                            )
                        else do
                          if contractState ^. #stateName == "active"
                            then reconcileObjects spec resultColumns requestedDefinitionHash
                            else pure (Right ())

    verifyPrivateImplementation spec =
      case spec ^. #privateImplementation of
        Nothing -> pure (Right ())
        Just implementation -> do
          resultMatches <-
            Tx.statement
              (privateRegprocedure spec implementation, renderSqlType (spec ^. #resultType))
              privateImplementationResultStmt
          case resultMatches of
            Nothing -> pure (Left (ExternalReadPrivateImplementationMissing implementation))
            Just False ->
              pure
                ( Left
                    ( ExternalReadPrivateImplementationResultMismatch
                        implementation
                        (spec ^. #resultType)
                    )
                )
            Just True -> do
              Tx.sql
                ( Text.Encoding.encodeUtf8
                    ( "REVOKE ALL ON FUNCTION "
                        <> qualifyFunction implementation
                        <> "("
                        <> Text.intercalate ", " (map qualifySqlType (spec ^. #argumentTypes))
                        <> ") FROM PUBLIC"
                    )
                )
              pure (Right ())

    reconcileObjects spec resultColumns requestedDefinitionHash = do
      typeRecorded <-
        upsertManagedObject
          spec
          (spec ^. #resultType . #typeSchema)
          (spec ^. #resultType . #typeName)
          "contract-type"
          (externalReadObjectKey spec)
          "consumer"
          requestedDefinitionHash
      if not typeRecorded
        then pure (Left (ExternalReadManagedObjectOwnershipConflict (spec ^. #resultType . #typeSchema) (spec ^. #resultType . #typeName) "contract-type"))
        else do
          bindingResult <- reconcileBinding spec resultColumns requestedDefinitionHash
          case bindingResult of
            Left err -> pure (Left err)
            Right () -> reconcileWrapper spec requestedDefinitionHash

    reconcileBinding spec resultColumns requestedDefinitionHash =
      case bindingViewSql spec resultColumns of
        Nothing -> pure (Right ())
        Just sql -> do
          let objectName = bindingViewName spec
          ownership <- managedObjectAuthority "keiro" objectName "binding-view" "" (Left (qualifyTable "keiro" objectName))
          case ownership of
            Left err -> pure (Left err)
            Right () -> do
              Tx.sql (Text.Encoding.encodeUtf8 sql)
              Tx.sql (Text.Encoding.encodeUtf8 ("REVOKE ALL ON " <> qualifyTable "keiro" objectName <> " FROM PUBLIC"))
              recorded <- upsertManagedObject spec "keiro" objectName "binding-view" "" "keiro" requestedDefinitionHash
              pure
                $ if recorded
                  then Right ()
                  else Left (ExternalReadManagedObjectOwnershipConflict "keiro" objectName "binding-view")

    reconcileWrapper spec requestedDefinitionHash = do
      let objectName = spec ^. #functionName
          signature = Text.intercalate "," (map renderSqlType (spec ^. #argumentTypes))
          regprocedure = publicRegprocedure spec
      ownership <- managedObjectAuthority "keiro_read" objectName "wrapper-function" signature (Right regprocedure)
      case ownership of
        Left err -> pure (Left err)
        Right () -> do
          Tx.sql (Text.Encoding.encodeUtf8 (wrapperSql spec))
          Tx.sql
            ( Text.Encoding.encodeUtf8
                ( "REVOKE ALL ON FUNCTION "
                    <> qualifyTable "keiro_read" objectName
                    <> "("
                    <> Text.intercalate ", " (map qualifySqlType (spec ^. #argumentTypes))
                    <> ") FROM PUBLIC"
                )
            )
          recorded <- upsertManagedObject spec "keiro_read" objectName "wrapper-function" signature "keiro" requestedDefinitionHash
          pure
            $ if recorded
              then Right ()
              else Left (ExternalReadManagedObjectOwnershipConflict "keiro_read" objectName "wrapper-function")

    managedObjectAuthority schema objectName kind signature existenceProbe = do
      managed <- Tx.statement (schema, objectName, kind, signature) lookupManagedObjectStmt
      exists <-
        case existenceProbe of
          Left relation -> Tx.statement relation relationExistsStmt
          Right procedure -> Tx.statement procedure functionExistsStmt
      pure $ case managed of
        Nothing
          | exists -> Left (ExternalReadUnmanagedObjectCollision schema objectName kind)
        Just object
          | object ^. #managedBy /= "keiro" -> Left (ExternalReadManagedObjectOwnershipConflict schema objectName kind)
        _ -> Right ()

    upsertManagedObject spec schema objectName kind signature managedBy definitionHash =
      Tx.statement
        ( schema,
          objectName,
          kind,
          signature,
          externalReadContractIdText (spec ^. #contractId),
          fromIntegral (externalReadContractVersionValue (spec ^. #contractVersion)),
          managedBy,
          definitionHash,
          fromIntegral (spec ^. #surfaceGeneration)
        )
        upsertManagedObjectStmt

    resolveContractState spec = do
      servingRevision <- Tx.statement (rebuildGroupIdText (spec ^. #groupId)) servingRevisionStmt
      pure
        $ case servingRevision of
          Just revision
            | revision `List.elem` map projectionRevisionIdText (spec ^. #compatibleRevisions) ->
                ContractState "active" (Just (spec ^. #resultShapeHash))
          _ -> ContractState "candidate" Nothing

    markAbsentPending specs = do
      persisted <- Tx.statement () listPersistedContractsStmt
      let selected groupId = maybe True (Set.member groupId) selectedGroups
          specKeys = Set.fromList (map externalReadKey specs)
          maximumGeneration = maximumMaybe (map (^. #surfaceGeneration) specs)
      for_ persisted $ \row ->
        case Catalog.mkRebuildGroupId (row ^. #groupIdText) of
          Left _ -> pure ()
          Right groupId ->
            when
              ( selected groupId
                  && (row ^. #contractIdText, fromIntegral (row ^. #contractVersionValue)) `Set.notMember` specKeys
                  && row ^. #state /= "retired"
                  && maybe False (row ^. #surfaceGeneration <) maximumGeneration
              )
              ( Tx.statement
                  (row ^. #contractIdText, fromIntegral (row ^. #contractVersionValue))
                  markContractPendingRetirementStmt
              )

externalReadSpecs ::
  ValidatedProjectionCatalog ->
  Maybe (Set RebuildGroupId) ->
  Either ExternalReadReconciliationError [ExternalReadSpec]
externalReadSpecs catalog selectedGroups =
  traverse toSpec selectedContracts
  where
    inventory = catalogInventory catalog
    queriesById =
      Map.fromList
        [ (query ^. #queryModelId, query)
        | query <- inventory ^. #inventoryQueryModels
        ]
    targetsById =
      Map.fromList
        [ (target ^. #targetId, target)
        | target <- inventory ^. #inventoryTargets
        ]
    selectedContracts =
      [ contract
      | contract <- inventory ^. #inventoryExternalReadContracts,
        maybe True (Set.member (contract ^. #rebuildGroupId)) selectedGroups
      ]

    toSpec contract = do
      binding <-
        case contract ^. #contractKind of
          InventoryKeyedExternalRead -> Right Nothing
          InventoryAllRowsExternalRead ->
            case Map.lookup (contract ^. #queryModelId) queriesById >>= singleton . (^. #observedTargets) of
              Just targetId -> Right ((^. #qualifiedTable) <$> Map.lookup targetId targetsById)
              Nothing -> Left (ExternalReadAllRowsRequiresSingleTarget (contract ^. #readContractId) (contract ^. #contractVersion))
      pure
        ExternalReadSpec
          { contractId = contract ^. #readContractId,
            contractVersion = contract ^. #contractVersion,
            queryModelId = contract ^. #queryModelId,
            groupId = contract ^. #rebuildGroupId,
            functionName = contract ^. #functionName,
            contractKind = contract ^. #contractKind,
            argumentNames = map (^. #argumentName) (contract ^. #arguments),
            argumentTypes = map (^. #argumentType) (contract ^. #arguments),
            resultType = contract ^. #resultContractType,
            resultShapeHash = contract ^. #resultShapeHash,
            compatibleRevisions = List.sort (toList (contract ^. #compatibleRevisions)),
            privateImplementation = contract ^. #privateImplementation,
            privateImplementationVersion = contract ^. #privateImplementationVersion,
            surfaceGeneration = contract ^. #surfaceGeneration,
            bindingTable = binding
          }

    singleton = \case
      [value] -> Just value
      _ -> Nothing

immutableSignature :: ExternalReadSpec -> Text
immutableSignature spec =
  hashPreimage "external-read-signature-v1"
    $ PRecord
      "external-read-signature"
      [ PText (externalReadContractIdText (spec ^. #contractId)),
        PText (Text.pack (show (externalReadContractVersionValue (spec ^. #contractVersion)))),
        PText (queryModelIdText (spec ^. #queryModelId)),
        PText (spec ^. #functionName),
        PText (contractKindText (spec ^. #contractKind)),
        PList (map PText (spec ^. #argumentNames)),
        PList (map (PText . renderSqlType) (spec ^. #argumentTypes)),
        PText (renderSqlType (spec ^. #resultType)),
        PText (maybe "" renderFunction (spec ^. #privateImplementation))
      ]

definitionIdentity :: ExternalReadSpec -> Text
definitionIdentity spec =
  hashPreimage "external-read-definition-v1"
    $ PRecord
      "external-read-definition"
      [ PText (immutableSignature spec),
        PText (spec ^. #resultShapeHash),
        PList (map (PText . projectionRevisionIdText) (spec ^. #compatibleRevisions)),
        PText (maybe "" (Text.pack . show) (spec ^. #privateImplementationVersion)),
        PText (Text.pack (show (spec ^. #surfaceGeneration))),
        PText (maybe "" renderTable (spec ^. #bindingTable))
      ]

bindingViewName :: ExternalReadSpec -> Text
bindingViewName spec = "external_read_" <> spec ^. #functionName <> "_binding"

bindingViewSql :: ExternalReadSpec -> [Text] -> Maybe Text
bindingViewSql spec resultColumns = do
  table <- spec ^. #bindingTable
  pure
    ( "CREATE OR REPLACE VIEW "
        <> qualifyTable "keiro" (bindingViewName spec)
        <> " WITH (security_barrier = true, security_invoker = false) AS SELECT "
        <> Text.intercalate ", " (map (qualifyColumn "source") resultColumns)
        <> " FROM "
        <> qualifyTable (table ^. #schemaName) (table ^. #tableName)
        <> " AS "
        <> quoteIdentifier "source"
    )
  where
    qualifyColumn alias column = quoteIdentifier alias <> "." <> quoteIdentifier column

wrapperSql :: ExternalReadSpec -> Text
wrapperSql spec =
  Text.unlines
    [ "CREATE OR REPLACE FUNCTION " <> qualifyTable "keiro_read" (spec ^. #functionName) <> "(" <> argumentDeclarations <> ")",
      "RETURNS SETOF " <> qualifySqlType (spec ^. #resultType),
      "LANGUAGE plpgsql",
      "SECURITY DEFINER",
      "SET search_path = pg_catalog",
      "AS $keiro_external_read$",
      body,
      "$keiro_external_read$"
    ]
  where
    argumentDeclarations =
      Text.intercalate
        ", "
        [ quoteIdentifier name <> " " <> qualifySqlType sqlType
        | (name, sqlType) <- zip (spec ^. #argumentNames) (spec ^. #argumentTypes)
        ]
    arguments = Text.intercalate ", " (map quoteIdentifier (spec ^. #argumentNames))
    source =
      case spec ^. #privateImplementation of
        Nothing -> qualifyTable "keiro" (bindingViewName spec)
        Just implementation -> qualifyFunction implementation <> "(" <> arguments <> ")"
    guardSql =
      "  PERFORM "
        <> qualifyTable "keiro_read" "guard_external_read_v1"
        <> "("
        <> quoteLiteral (externalReadContractIdText (spec ^. #contractId))
        <> ", "
        <> Text.pack (show (externalReadContractVersionValue (spec ^. #contractVersion)))
        <> ");"
    body =
      case spec ^. #contractKind of
        InventoryAllRowsExternalRead ->
          Text.unlines
            [ "DECLARE",
              "  returned_rows bigint;",
              "BEGIN",
              guardSql,
              "  RETURN QUERY SELECT * FROM " <> source <> " LIMIT " <> Text.pack (show allRowsExternalReadFetchLimit) <> ";",
              "  GET DIAGNOSTICS returned_rows = ROW_COUNT;",
              "  IF returned_rows > " <> Text.pack (show allRowsExternalReadLimit) <> " THEN",
              "    RAISE EXCEPTION USING",
              "      ERRCODE = 'KR004',",
              "      MESSAGE = 'all-row external read exceeds its bounded result limit',",
              "      DETAIL = " <> quoteLiteral allRowsLimitDetail <> ";",
              "  END IF;",
              "END"
            ]
        InventoryKeyedExternalRead ->
          Text.unlines
            [ "BEGIN",
              guardSql,
              "  RETURN QUERY SELECT * FROM " <> source <> ";",
              "END"
            ]
    allRowsLimitDetail =
      "contract="
        <> externalReadContractIdText (spec ^. #contractId)
        <> " version="
        <> Text.pack (show (externalReadContractVersionValue (spec ^. #contractVersion)))
        <> " row_limit="
        <> Text.pack (show allRowsExternalReadLimit)

allRowsExternalReadLimit :: Int
allRowsExternalReadLimit = 100

allRowsExternalReadFetchLimit :: Int
allRowsExternalReadFetchLimit = 101

contractParams ::
  ExternalReadSpec ->
  Text ->
  Text ->
  ContractState ->
  ( Text,
    Int32,
    Text,
    Text,
    Text,
    Text,
    [Text],
    [Text],
    Text,
    Text,
    Maybe Text,
    [Text],
    Maybe Text,
    Maybe Int32,
    Text,
    Text,
    Int32,
    Text
  )
contractParams spec signatureHash definitionHash contractState =
  ( externalReadContractIdText (spec ^. #contractId),
    fromIntegral (externalReadContractVersionValue (spec ^. #contractVersion)),
    queryModelIdText (spec ^. #queryModelId),
    rebuildGroupIdText (spec ^. #groupId),
    spec ^. #functionName,
    contractKindText (spec ^. #contractKind),
    spec ^. #argumentNames,
    map renderSqlType (spec ^. #argumentTypes),
    renderSqlType (spec ^. #resultType),
    spec ^. #resultShapeHash,
    contractState ^. #servingShapeHash,
    map projectionRevisionIdText (spec ^. #compatibleRevisions),
    renderFunction <$> spec ^. #privateImplementation,
    fromIntegral <$> spec ^. #privateImplementationVersion,
    signatureHash,
    definitionHash,
    fromIntegral (spec ^. #surfaceGeneration),
    contractState ^. #stateName
  )

contractKindText :: ExternalReadContractKind -> Text
contractKindText InventoryAllRowsExternalRead = "all-rows"
contractKindText InventoryKeyedExternalRead = "keyed"

externalReadKey :: ExternalReadSpec -> (Text, Int32)
externalReadKey spec =
  ( externalReadContractIdText (spec ^. #contractId),
    fromIntegral (externalReadContractVersionValue (spec ^. #contractVersion))
  )

renderSqlType :: QualifiedSqlType -> Text
renderSqlType sqlType = sqlType ^. #typeSchema <> "." <> sqlType ^. #typeName

qualifySqlType :: QualifiedSqlType -> Text
qualifySqlType sqlType = qualifyTable (sqlType ^. #typeSchema) (sqlType ^. #typeName)

renderFunction :: QualifiedFunction -> Text
renderFunction function = function ^. #functionSchema <> "." <> function ^. #functionName

qualifyFunction :: QualifiedFunction -> Text
qualifyFunction function = qualifyTable (function ^. #functionSchema) (function ^. #functionName)

renderTable :: Catalog.QualifiedTable -> Text
renderTable table = table ^. #schemaName <> "." <> table ^. #tableName

quoteLiteral :: Text -> Text
quoteLiteral value = "'" <> Text.replace "'" "''" value <> "'"

publicRegprocedure :: ExternalReadSpec -> Text
publicRegprocedure spec =
  "keiro_read."
    <> spec
    ^. #functionName
    <> "("
    <> Text.intercalate "," (map renderSqlType (spec ^. #argumentTypes))
    <> ")"

privateRegprocedure :: ExternalReadSpec -> QualifiedFunction -> Text
privateRegprocedure spec implementation =
  renderFunction implementation
    <> "("
    <> Text.intercalate "," (map renderSqlType (spec ^. #argumentTypes))
    <> ")"

externalReadObjectKey :: ExternalReadSpec -> Text
externalReadObjectKey spec =
  externalReadContractIdText (spec ^. #contractId)
    <> "/v"
    <> Text.pack (show (externalReadContractVersionValue (spec ^. #contractVersion)))

maximumMaybe :: [Int] -> Maybe Int
maximumMaybe = \case
  [] -> Nothing
  values -> Just (maximum values)

previewExternalReadContractRetirement ::
  (Store :> es) =>
  ExternalReadContractId ->
  ExternalReadContractVersion ->
  Eff es (Either ExternalReadRetirementError ExternalReadRetirementPreview)
previewExternalReadContractRetirement contractId contractVersion =
  runTransaction (previewRetirementTx contractId contractVersion)

retireExternalReadContract ::
  (Store :> es) =>
  ExternalReadContractId ->
  ExternalReadContractVersion ->
  Eff es (Either ExternalReadRetirementError ExternalReadRetirementPreview)
retireExternalReadContract contractId contractVersion =
  runTransaction $ do
    retirementPreview <- previewRetirementTx contractId contractVersion
    case retirementPreview of
      Left err -> Tx.condemn $> Left err
      Right value
        | value ^. #currentState == "retired" ->
            Tx.condemn $> Left (ExternalReadRetirementAlreadyRetired contractId contractVersion)
        | otherwise -> do
            Tx.statement (retirementKey contractId contractVersion) retireContractStmt
            pure (Right (value & #currentState .~ "retired"))

previewRetirementTx ::
  ExternalReadContractId ->
  ExternalReadContractVersion ->
  Tx.Transaction (Either ExternalReadRetirementError ExternalReadRetirementPreview)
previewRetirementTx contractId contractVersion = do
  summary <- Tx.statement (retirementKey contractId contractVersion) retirementSummaryStmt
  case summary of
    Nothing -> pure (Left (ExternalReadRetirementUnknown contractId contractVersion))
    Just (functionName, state, generation) -> do
      dependencies <- Tx.statement (retirementKey contractId contractVersion) retirementDependenciesStmt
      grants <- Tx.statement (retirementKey contractId contractVersion) retirementGrantsStmt
      pure
        ( Right
            ExternalReadRetirementPreview
              { contractId,
                contractVersion,
                publicFunction = "keiro_read." <> functionName,
                currentState = state,
                surfaceGeneration = fromIntegral generation,
                dependentObjects = dependencies,
                executeGrants = grants
              }
        )

retirementKey :: ExternalReadContractId -> ExternalReadContractVersion -> (Text, Int32)
retirementKey contractId contractVersion =
  ( externalReadContractIdText contractId,
    fromIntegral (externalReadContractVersionValue contractVersion)
  )

lookupContractStmt :: Statement (Text, Int32) (Maybe PersistedContract)
lookupContractStmt =
  preparable
    """
    SELECT immutable_signature_hash, definition_hash, surface_generation, state
    FROM keiro.keiro_external_read_contracts
    WHERE contract_id = $1 AND contract_version = $2
    FOR UPDATE
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    ( D.rowMaybe
        ( PersistedContract
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> (fromIntegral <$> D.column (D.nonNullable D.int4))
            <*> D.column (D.nonNullable D.text)
        )
    )

upsertContractStmt ::
  Statement
    ( Text,
      Int32,
      Text,
      Text,
      Text,
      Text,
      [Text],
      [Text],
      Text,
      Text,
      Maybe Text,
      [Text],
      Maybe Text,
      Maybe Int32,
      Text,
      Text,
      Int32,
      Text
    )
    Bool
upsertContractStmt =
  preparable
    """
    INSERT INTO keiro.keiro_external_read_contracts
      (contract_id, contract_version, query_model_id, group_id,
       public_function_name, contract_kind, argument_names, argument_types,
       result_type, result_shape_hash, serving_shape_hash,
       compatible_revision_ids, private_implementation,
       private_implementation_version, immutable_signature_hash,
       definition_hash, surface_generation, state)
    VALUES
      ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
       $13, $14, $15, $16, $17, $18)
    ON CONFLICT (contract_id, contract_version) DO UPDATE
    SET query_model_id = EXCLUDED.query_model_id,
        group_id = EXCLUDED.group_id,
        public_function_name = EXCLUDED.public_function_name,
        contract_kind = EXCLUDED.contract_kind,
        argument_names = EXCLUDED.argument_names,
        argument_types = EXCLUDED.argument_types,
        result_type = EXCLUDED.result_type,
        result_shape_hash = EXCLUDED.result_shape_hash,
        serving_shape_hash = EXCLUDED.serving_shape_hash,
        compatible_revision_ids = EXCLUDED.compatible_revision_ids,
        private_implementation = EXCLUDED.private_implementation,
        private_implementation_version = EXCLUDED.private_implementation_version,
        definition_hash = EXCLUDED.definition_hash,
        surface_generation = EXCLUDED.surface_generation,
        state = EXCLUDED.state,
        retired_at = NULL,
        updated_at = now()
    WHERE keiro.keiro_external_read_contracts.immutable_signature_hash = EXCLUDED.immutable_signature_hash
      AND keiro.keiro_external_read_contracts.surface_generation <= EXCLUDED.surface_generation
      AND keiro.keiro_external_read_contracts.state <> 'retired'
    RETURNING TRUE
    """
    ( contrazip18
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.int4))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.text))
    )
    (maybe False Prelude.id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

lookupManagedObjectStmt :: Statement (Text, Text, Text, Text) (Maybe ManagedObject)
lookupManagedObjectStmt =
  preparable
    """
    SELECT managed_by, definition_hash, surface_generation
    FROM keiro.keiro_managed_read_objects
    WHERE object_schema = $1 AND object_name = $2
      AND object_kind = $3 AND object_signature = $4
    FOR UPDATE
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    ( D.rowMaybe
        ( ManagedObject
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> (fromIntegral <$> D.column (D.nonNullable D.int4))
        )
    )

upsertManagedObjectStmt :: Statement (Text, Text, Text, Text, Text, Int32, Text, Text, Int32) Bool
upsertManagedObjectStmt =
  preparable
    """
    INSERT INTO keiro.keiro_managed_read_objects
      (object_schema, object_name, object_kind, object_signature,
       contract_id, contract_version, managed_by, definition_hash,
       surface_generation, state)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'active')
    ON CONFLICT (object_schema, object_name, object_kind, object_signature)
    DO UPDATE
    SET contract_id = EXCLUDED.contract_id,
        contract_version = EXCLUDED.contract_version,
        definition_hash = EXCLUDED.definition_hash,
        surface_generation = EXCLUDED.surface_generation,
        state = 'active',
        retired_at = NULL,
        updated_at = now()
    WHERE keiro.keiro_managed_read_objects.managed_by = EXCLUDED.managed_by
      AND keiro.keiro_managed_read_objects.surface_generation <= EXCLUDED.surface_generation
    RETURNING TRUE
    """
    ( contrazip9
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    (maybe False Prelude.id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

typeExistsStmt :: Statement Text Bool
typeExistsStmt =
  preparable
    "SELECT pg_catalog.to_regtype($1) IS NOT NULL"
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.bool)))

compositeTypeColumnsStmt :: Statement Text [Text]
compositeTypeColumnsStmt =
  preparable
    """
    SELECT attributes.attname::text
    FROM pg_catalog.pg_type AS types
    JOIN pg_catalog.pg_attribute AS attributes
      ON attributes.attrelid = types.typrelid
    WHERE types.oid = pg_catalog.to_regtype($1)
      AND types.typtype = 'c'
      AND attributes.attnum > 0
      AND NOT attributes.attisdropped
    ORDER BY attributes.attnum
    """
    (E.param (E.nonNullable E.text))
    (D.rowList (D.column (D.nonNullable D.text)))

relationExistsStmt :: Statement Text Bool
relationExistsStmt =
  preparable
    "SELECT pg_catalog.to_regclass($1) IS NOT NULL"
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.bool)))

privateImplementationResultStmt :: Statement (Text, Text) (Maybe Bool)
privateImplementationResultStmt =
  preparable
    """
    SELECT procedures.proretset
       AND procedures.prorettype = pg_catalog.to_regtype($2)
    FROM pg_catalog.pg_proc AS procedures
    WHERE procedures.oid = pg_catalog.to_regprocedure($1)
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.rowMaybe (D.column (D.nonNullable D.bool)))

functionExistsStmt :: Statement Text Bool
functionExistsStmt =
  preparable
    "SELECT pg_catalog.to_regprocedure($1) IS NOT NULL"
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.bool)))

servingRevisionStmt :: Statement Text (Maybe Text)
servingRevisionStmt =
  preparable
    "SELECT serving_revision_id FROM keiro.keiro_projection_rebuild_groups WHERE group_id = $1"
    (E.param (E.nonNullable E.text))
    (join <$> D.rowMaybe (D.column (D.nullable D.text)))

listPersistedContractsStmt :: Statement () [PersistedContractKey]
listPersistedContractsStmt =
  preparable
    """
    SELECT contract_id, contract_version, group_id, surface_generation, state
    FROM keiro.keiro_external_read_contracts
    ORDER BY contract_id, contract_version
    FOR UPDATE
    """
    E.noParams
    ( D.rowList
        ( PersistedContractKey
            <$> D.column (D.nonNullable D.text)
            <*> (fromIntegral <$> D.column (D.nonNullable D.int4))
            <*> D.column (D.nonNullable D.text)
            <*> (fromIntegral <$> D.column (D.nonNullable D.int4))
            <*> D.column (D.nonNullable D.text)
        )
    )

markContractPendingRetirementStmt :: Statement (Text, Int32) ()
markContractPendingRetirementStmt =
  preparable
    """
    WITH changed AS (
      UPDATE keiro.keiro_external_read_contracts
      SET state = 'pending-retirement', updated_at = now()
      WHERE contract_id = $1 AND contract_version = $2
        AND state <> 'retired'
      RETURNING contract_id, contract_version
    )
    UPDATE keiro.keiro_managed_read_objects AS objects
    SET state = 'pending-retirement', updated_at = now()
    FROM changed
    WHERE objects.contract_id = changed.contract_id
      AND objects.contract_version = changed.contract_version
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    D.noResult

retirementSummaryStmt :: Statement (Text, Int32) (Maybe (Text, Text, Int32))
retirementSummaryStmt =
  preparable
    """
    SELECT public_function_name, state, surface_generation
    FROM keiro.keiro_external_read_contracts
    WHERE contract_id = $1 AND contract_version = $2
    FOR UPDATE
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    ( D.rowMaybe
        ( (,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.int4)
        )
    )

retirementDependenciesStmt :: Statement (Text, Int32) [Text]
retirementDependenciesStmt =
  preparable
    """
    WITH owned_objects AS (
      SELECT 'pg_catalog.pg_class'::pg_catalog.regclass::oid AS class_id,
             classes.oid AS object_id
      FROM keiro.keiro_managed_read_objects AS objects
      JOIN pg_catalog.pg_class AS classes
        ON classes.relnamespace = pg_catalog.to_regnamespace(objects.object_schema)
       AND classes.relname = objects.object_name
      WHERE objects.contract_id = $1 AND objects.contract_version = $2
        AND objects.object_kind = 'binding-view'
      UNION
      SELECT 'pg_catalog.pg_proc'::pg_catalog.regclass::oid AS class_id,
             pg_catalog.to_regprocedure(
               pg_catalog.format(
                 '%I.%I(%s)',
                 objects.object_schema,
                 objects.object_name,
                 objects.object_signature
               )
             )::oid AS object_id
      FROM keiro.keiro_managed_read_objects AS objects
      WHERE objects.contract_id = $1 AND objects.contract_version = $2
        AND objects.object_kind = 'wrapper-function'
    )
    SELECT DISTINCT pg_catalog.pg_describe_object(
      dependencies.classid,
      dependencies.objid,
      dependencies.objsubid
    )
    FROM pg_catalog.pg_depend AS dependencies
    JOIN owned_objects
      ON owned_objects.class_id = dependencies.refclassid
     AND owned_objects.object_id = dependencies.refobjid
    WHERE dependencies.deptype NOT IN ('i', 'e')
      AND dependencies.objid <> dependencies.refobjid
    ORDER BY 1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    (D.rowList (D.column (D.nonNullable D.text)))

retirementGrantsStmt :: Statement (Text, Int32) [Text]
retirementGrantsStmt =
  preparable
    """
    SELECT DISTINCT
      coalesce(grantees.rolname, 'PUBLIC') || ':' || privileges.privilege_type
    FROM keiro.keiro_external_read_contracts AS contracts
    JOIN pg_catalog.pg_proc AS procedures
      ON procedures.oid = pg_catalog.to_regprocedure(
        pg_catalog.format(
          '%I.%I(%s)',
          'keiro_read',
          contracts.public_function_name,
          pg_catalog.array_to_string(contracts.argument_types, ',')
        )
      )
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      coalesce(
        procedures.proacl,
        pg_catalog.acldefault('f', procedures.proowner)
      )
    ) AS privileges
    LEFT JOIN pg_catalog.pg_roles AS grantees
      ON grantees.oid = privileges.grantee
    WHERE contracts.contract_id = $1 AND contracts.contract_version = $2
      AND privileges.privilege_type = 'EXECUTE'
    ORDER BY 1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    (D.rowList (D.column (D.nonNullable D.text)))

retireContractStmt :: Statement (Text, Int32) ()
retireContractStmt =
  preparable
    """
    WITH changed AS (
      UPDATE keiro.keiro_external_read_contracts
      SET state = 'retired', retired_at = now(), updated_at = now()
      WHERE contract_id = $1 AND contract_version = $2
      RETURNING contract_id, contract_version
    )
    UPDATE keiro.keiro_managed_read_objects AS objects
    SET state = 'retired', retired_at = now(), updated_at = now()
    FROM changed
    WHERE objects.contract_id = changed.contract_id
      AND objects.contract_version = changed.contract_version
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    D.noResult
