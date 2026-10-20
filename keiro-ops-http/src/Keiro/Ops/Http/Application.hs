module Keiro.Ops.Http.Application
  ( opsApplication,
    opsApplicationWithBudget,
    OpsHttpError (..),
    errorResponse,
    OpsHttpOperations (..),
    opsApplicationWithOperations,
  )
where

import Control.Exception (SomeAsyncException, SomeException, displayException, evaluate, fromException, throwIO, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Hasql.Pool qualified as Pool
import Keiro.Migrations.SchemaCheck (renderSchemaDrift, verifyExpectedSchemaSession)
import Keiro.Ops (AppHooks, Command, commandParser, isMutation, runCommandWithHeaderCache, validateCommand)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (Json))
import Keiro.Ops.Http.Budget
import Keiro.Ops.Http.Config
import Keiro.Ops.Http.Cors
import Keiro.Ops.Http.Route
import Keiro.Ops.Render
import Keiro.Ops.WorkflowHeaderCache (newWorkflowHeaderCache)
import Kiroku.Store.Connection (KirokuStore (..))
import Network.HTTP.Types
import Network.Wai
import System.Exit (ExitCode (..))

data ResponsePlan = Immediate Response | Inspected Bool (IO Response)

data OpsHttpError = OpsHttpError
  { status :: !Status,
    code :: !Text,
    message :: !Text,
    details :: !(Maybe Value)
  }

jsonHeaders :: ResponseHeaders
jsonHeaders = [(hContentType, "application/json; charset=utf-8")]

errorResponse :: OpsHttpError -> Response
errorResponse err = responseLBS err.status jsonHeaders (Aeson.encode (errorValue err))

errorValue :: OpsHttpError -> Value
errorValue err = object ["error" .= object (["code" .= err.code, "message" .= err.message] <> maybe [] (\value -> ["details" .= value]) err.details)]

failure :: Status -> Text -> Text -> Response
failure status code message = errorResponse (OpsHttpError status code message Nothing)

-- | A host/test seam for supported verification and execution, never a route
-- registry. Production mounting uses 'opsApplication'.
data OpsHttpOperations = OpsHttpOperations
  { verifySchema :: IO (Either Text [Text]),
    executeCommand :: OpsEnv -> Command -> IO OpsOutcome
  }

-- | Allocate once per mount. The supplied store must have statement_timeout
-- configured on EVERY connection, at or below inspectionLimits. Use a dedicated
-- pool; changing a borrowed connection here cannot constrain another handler's
-- borrow and would change writer policy on a shared pool.
opsApplication :: OpsHttpConfig -> AppHooks -> KirokuStore -> IO Application
opsApplication config hooks store = do
  budget <- newInspectionBudget config.inspectionLimits
  opsApplicationWithBudget config budget hooks store

-- | Internal feed integration: HTTP and refresh work consume the same budget.
opsApplicationWithBudget :: OpsHttpConfig -> InspectionBudget -> AppHooks -> KirokuStore -> IO Application
opsApplicationWithBudget config budget hooks store = do
  cache <- newWorkflowHeaderCache config.inspectionLimits.maxResponseBytes $ \value ->
    fmap LazyByteString.toStrict <$> encodeBounded config.inspectionLimits.maxResponseBytes value
  let verify = do
        result <- Pool.use store.pool verifyExpectedSchemaSession
        pure $ case result of
          Left err -> Left (Text.pack (show err))
          Right (Left err) -> Left (Text.pack (show err))
          Right (Right drifts) -> Right (map renderSchemaDrift drifts)
  opsApplicationPrepared config budget hooks store verify (runCommandWithHeaderCache cache hooks)

opsApplicationWithOperations :: OpsHttpConfig -> InspectionBudget -> AppHooks -> KirokuStore -> OpsHttpOperations -> IO Application
opsApplicationWithOperations config budget hooks store operations =
  opsApplicationPrepared config budget hooks store operations.verifySchema $ \env command -> do
    outcome <- operations.executeCommand env command
    pure (outcome, Nothing)

-- The prepared bytes are paired with the exact successful read outcome by the
-- owning runner. They never change the public OpsResult or mutation protocol.
opsApplicationPrepared :: OpsHttpConfig -> InspectionBudget -> AppHooks -> KirokuStore -> IO (Either Text [Text]) -> (OpsEnv -> Command -> IO (OpsOutcome, Maybe ByteString.ByteString)) -> IO Application
opsApplicationPrepared config budget hooks store verify execute = do
  parsedReads <- newIORef (Map.empty, Seq.empty)
  let parser = commandParser hooks
      flags = flagNames parser
      parse arguments = do
        (known, _) <- readIORef parsedReads
        case Map.lookup arguments known of
          Just command -> pure (Parsed command)
          Nothing -> case parseArgumentsWithParser parser arguments of
            Parsed command
              | not (isMutation command),
                Right () <- validateCommand command -> do
                  -- Cache only pure parsing, never observations or authorization.
                  -- FIFO capacity and the request-byte cap bound retained inputs.
                  atomicModifyIORef' parsedReads $ \(commands, order) ->
                    if Map.member arguments commands
                      then ((commands, order), ())
                      else
                        let (kept, queue) = case Seq.viewl order of
                              oldest Seq.:< rest | Map.size commands >= 64 -> (Map.delete oldest commands, rest)
                              _ -> (commands, order)
                         in ((Map.insert arguments command kept, queue Seq.|> arguments), ())
                  pure (Parsed command)
            outcome -> pure outcome
  -- Initialize static command metadata during mounting, before requests arrive.
  _ <- evaluate (flags [])
  pure $ corsMiddleware config.allowedOrigins $ \request respond -> do
    result <- trySync (dispatch parse flags request)
    case result of
      Left _ -> respond internalError
      Right (Immediate response) -> respond response
      Right (Inspected mutation action) -> do
        let deadline = if mutation then limits.mutationDeadlineSeconds else limits.readDeadlineSeconds
        delivered <- withInspectionAdmission budget $ do
          computed <- withInspectionDeadline deadline (trySync action)
          -- Network exceptions must propagate; never attempt a second response.
          respond $ case computed of
            Left problem -> budgetFailure mutation problem
            Right (Left _) -> internalError
            Right (Right response) -> response
        case delivered of
          Left problem -> respond (budgetFailure mutation problem)
          Right sent -> pure sent
  where
    limits = config.inspectionLimits
    dispatch parse flags request
      | inputBytes request > limits.maxRequestBytes = immediate (failure status413 "inspection_request_too_large" "request path and query exceed the host limit")
      | pathInfo request == [] = immediate (failure status404 "not_found" "no inspection command at this path")
      | pathInfo request == ["health"] =
          if requestMethod request == methodGet
            then pure (Inspected False health)
            else immediate (methodFailure methodGet)
      | otherwise = case translate flags request of
          Left message -> immediate (failure status400 "invalid_request" message)
          Right arguments -> do
            parsed <- parse arguments
            case parsed of
              Rejected message -> immediate (errorResponse (OpsHttpError status400 "invalid_request" message (Just (object ["arguments" .= arguments]))))
              Parsed command | Left (code, message) <- validateCommand command -> immediate (failure status400 code message)
              Parsed command -> do
                let mutation = isMutation command
                    method = if mutation then methodPost else methodGet
                if requestMethod request /= method
                  then immediate (methodFailure method)
                  else
                    if mutation && config.mutations == MutationsDisabled
                      then immediate (failure status403 "mutations_disabled" "this surface was mounted without mutations")
                      else budgetedCommand request command mutation
    translate flags request = do
      query <- either (Left . Text.pack . displayException) Right (traverse decodeQuery (queryString request))
      either (Left . renderRouteError) Right (translateRequest (flags (pathInfo request)) (pathInfo request) query)
    decodeQuery (key, value) = (,) <$> Text.decodeUtf8' key <*> traverse Text.decodeUtf8' value
    inputBytes request = ByteString.length (rawPathInfo request) + ByteString.length (rawQueryString request)
    methodFailure method = mapResponseHeaders ((hAllow, method) :) (failure status405 "method_not_allowed" "method does not match the command classification")
    budgetedCommand request command mutation =
      pure $ Inspected mutation $ do
        confirmation <- if mutation then readConfirmation request else pure (Right False)
        case confirmation of
          Left err -> pure err
          Right confirmed -> do
            verified <- verify
            case verified of
              Left message -> pure (failure status500 "schema_verification_failed" message)
              Right drift
                | not (null drift) && config.schemaDrift == RefuseOnDrift ->
                    boundedJson status409 [] (errorValue (OpsHttpError status409 "schema_drift" "the live schema differs from this binary; refusing to serve until they agree" (Just (object ["drift" .= drift]))))
                | otherwise -> do
                    let env = OpsEnv store Json (mutation && confirmed) drift (config.schemaDrift == AllowDrift)
                    (outcome, prepared) <- execute env command
                    renderOutcome mutation drift prepared outcome
    immediate = pure . Immediate
    internalError = failure status500 "internal_error" "inspection failed"
    budgetFailure mutation = \case
      InspectionBusy -> failure status503 "inspection_busy" "all inspection slots are in use; retry later"
      InspectionTimedOut
        | mutation -> failure status504 "mutation_outcome_unknown" "deadline exceeded; the mutation may have committed; inspect state before deciding whether to retry"
        | otherwise -> failure status504 "inspection_timeout" "inspection exceeded the host deadline"
    health = do
      result <- verify
      case result of
        Left message -> boundedJson status503 [] (object ["status" .= ("unavailable" :: Text), "message" .= message])
        Right drift ->
          boundedJson
            (if null drift || config.schemaDrift == AllowDrift then status200 else status503)
            (driftHeaders drift)
            (object ["status" .= (if null drift then "ok" else "schema_drift" :: Text), "schema_drift" .= drift, "mutations_enabled" .= (config.mutations == MutationsEnabled)])
    driftHeaders drift = [("Keiro-Ops-Schema-Drift", Char8.pack (show (length drift))) | not (null drift) && config.schemaDrift == AllowDrift]
    boundedJson status headers value = do
      encoded <- encodeBounded limits.maxResponseBytes value
      pure $ case encoded of
        Nothing -> failure status413 "inspection_result_too_large" "encoded result exceeds the host limit; narrow the read"
        Just body -> responseLBS status (jsonHeaders <> headers) body
    renderOutcome mutation drift prepared = \case
      InspectionFailed code message ->
        let status
              | code == "cursor_generation_mismatch" = status409
              | code == "inspection_result_too_large" = status413
              | otherwise = status400
         in boundedJson status [] (errorValue (OpsHttpError status code message Nothing))
      Failed message -> boundedJson status422 [] (errorValue (OpsHttpError status422 "command_failed" message Nothing))
      PreviewRequired result invocation -> boundedJson status200 (driftHeaders drift) (object ["outcome" .= ("preview" :: Text), "result" .= result.jsonValue, "cli_reinvocation" .= invocation])
      Succeeded result -> success result ExitSuccess
      SucceededWithExit result exitCode -> success result exitCode
      where
        success result exitCode =
          let exitFields = case exitCode of ExitSuccess -> []; ExitFailure n -> ["exit_code" .= n]
              exitHeaders = case exitCode of ExitSuccess -> []; ExitFailure n -> [("Keiro-Ops-Exit-Code", Char8.pack (show n))]
              value = if mutation then object (["outcome" .= ("executed" :: Text), "result" .= result.jsonValue] <> exitFields) else result.jsonValue
           in case (mutation, prepared) of
                (False, Just body)
                  | ByteString.length body <= limits.maxResponseBytes ->
                      pure (responseLBS status200 (jsonHeaders <> driftHeaders drift <> exitHeaders) (LazyByteString.fromStrict body))
                  | otherwise ->
                      pure (failure status413 "inspection_result_too_large" "encoded result exceeds the host limit; narrow the read")
                _ -> boundedJson status200 (driftHeaders drift <> if mutation then [] else exitHeaders) value

readConfirmation :: Request -> IO (Either Response Bool)
readConfirmation request = go 0 []
  where
    go size chunks = do
      chunk <- getRequestBodyChunk request
      let nextSize = size + ByteString.length chunk
      if nextSize > 1024
        then pure (Left (failure status413 "inspection_request_too_large" "confirmation body exceeds 1 KiB"))
        else
          if ByteString.null chunk
            then pure (parse (LazyByteString.fromChunks (reverse chunks)))
            else go nextSize (chunk : chunks)
    parse body
      | LazyByteString.null body = Right False
      | Aeson.decode body == Just (object ["confirm" .= ("execute" :: Text)]) = Right True
      | otherwise = Left (failure status400 "invalid_confirmation" "expected an empty body or exactly {\"confirm\":\"execute\"}")

trySync :: IO a -> IO (Either SomeException a)
trySync action = do
  result <- try action
  case result of
    Left exception | Just (_ :: SomeAsyncException) <- fromException exception -> throwIO exception
    _ -> pure result
