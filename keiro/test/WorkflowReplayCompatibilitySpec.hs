{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module WorkflowReplayCompatibilitySpec
  ( spec,
  )
where

import Control.Exception (Exception, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Prelude (liftIO)
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Keiro.Workflow
import Kiroku.Store qualified as Store
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = describe "cross-version workflow replay compatibility" $ around (withFreshStore fixture) do
  it "continues a captured prefix under a source-only refactor without repeating its effect" $ \store -> do
    baselineEffects <- newIORef (0 :: Int)
    candidateEffects <- newIORef (0 :: Int)
    let name = WorkflowName "compatibleRefactor"
        wid = WorkflowId "instance-1"
    captureCrashedPrefix store name wid (stableBaseline baselineEffects)
    candidate <- Store.runStoreIO store $ runWorkflow name wid (stableCandidate candidateEffects)
    candidate `shouldBe` Right (Completed 1)
    readIORef baselineEffects `shouldReturn` 1
    readIORef candidateEffects `shouldReturn` 0

  it "fails closed when candidate code cannot decode a captured result" $ \store -> do
    baselineEffects <- newIORef (0 :: Int)
    candidateEffects <- newIORef (0 :: Int)
    let name = WorkflowName "decoderBreak"
        wid = WorkflowId "instance-1"
    captureCrashedPrefix store name wid (stableBaseline baselineEffects)
    candidate <-
      try (Store.runStoreIO store $ runWorkflow name wid (incompatibleCandidate candidateEffects)) ::
        IO (Either WorkflowError (Either Store.StoreError (WorkflowOutcome Bool)))
    candidate `shouldSatisfy` \case
      Left (WorkflowStepDecodeError "stable-result" _) -> True
      _ -> False
    readIORef candidateEffects `shouldReturn` 0

  it "exposes a decoder that succeeds with changed meaning at the first stable key" $ \store -> do
    baselineEffects <- newIORef (0 :: Int)
    candidateEffects <- newIORef (0 :: Int)
    let name = WorkflowName "semanticDrift"
        wid = WorkflowId "instance-1"
    captureCrashedPrefix store name wid (semanticBaseline baselineEffects)
    candidate <- Store.runStoreIO store $ runWorkflow name wid (semanticCandidate candidateEffects)
    candidate `shouldBe` Right (Completed (CandidateAmount 6))
    CandidateAmount 6 `shouldNotBe` CandidateAmount 5
    readIORef candidateEffects `shouldReturn` 0

  it "treats a renamed step as new work and therefore rejects it as a pure refactor" $ \store -> do
    baselineEffects <- newIORef (0 :: Int)
    candidateEffects <- newIORef (0 :: Int)
    let name = WorkflowName "renamedStep"
        wid = WorkflowId "instance-1"
    captureCrashedPrefix store name wid (stableBaseline baselineEffects)
    candidate <- Store.runStoreIO store $ runWorkflow name wid (renamedCandidate candidateEffects)
    candidate `shouldBe` Right (Completed 1)
    readIORef candidateEffects `shouldReturn` 1

  it "keeps an in-flight instance on its recorded patch branch" $ \store -> do
    baselineEffects <- newIORef (0 :: Int)
    candidateEffects <- newIORef (0 :: Int)
    let name = WorkflowName "patchedContinuation"
        wid = WorkflowId "instance-1"
        options = defaultWorkflowRunOptions {activePatches = Set.singleton compatibilityPatch}
    baseline <- Store.runStoreIO store $ runWorkflow name wid (prePatchWorkflow baselineEffects)
    baseline `shouldBe` Right Suspended
    candidate <- Store.runStoreIO store $ runWorkflowWith options name wid (postPatchWorkflow candidateEffects)
    candidate `shouldBe` Right (Completed "old-branch")
    readIORef baselineEffects `shouldReturn` 1
    readIORef candidateEffects `shouldReturn` 0

  it "reuses an indexed await result without rearming under candidate code" $ \store -> do
    baselineArms <- newIORef (0 :: Int)
    candidateArms <- newIORef (0 :: Int)
    let name = WorkflowName "awaitContinuation"
        wid = WorkflowId "instance-1"
    baseline <- Store.runStoreIO store $ runWorkflow name wid (awaitingWorkflow baselineArms)
    baseline `shouldBe` Right Suspended
    now <- getCurrentTime
    Right () <-
      Store.runStoreIO store $
        appendJournalEntry name wid (StepRecorded "stable-await" (Aeson.toJSON (7 :: Int)) now)
    candidate <- Store.runStoreIO store $ runWorkflow name wid (awaitingWorkflow candidateArms)
    candidate `shouldBe` Right (Completed 7)
    readIORef baselineArms `shouldReturn` 1
    readIORef candidateArms `shouldReturn` 0

  it "continues from a baseline-carried seed after continueAsNew" $ \store -> do
    let name = WorkflowName "rotatedContinuation"
        wid = WorkflowId "instance-1"
    baseline <- Store.runStoreIO store $ runWorkflow name wid baselineRotation
    baseline `shouldBe` Right ContinuedAsNew
    candidate <- Store.runStoreIO store $ runWorkflow name wid candidateRotation
    candidate `shouldBe` Right (Completed 41)

data CapturedPrefix = CapturedPrefix
  deriving stock (Show)

instance Exception CapturedPrefix

captureCrashedPrefix ::
  Store.KirokuStore ->
  WorkflowName ->
  WorkflowId ->
  Eff '[Workflow, Store.Store, Error Store.StoreError, IOE] value ->
  IO ()
captureCrashedPrefix store name wid body = do
  captured <- try @CapturedPrefix (Store.runStoreIO store $ runWorkflow name wid body)
  case captured of
    Left CapturedPrefix -> pure ()
    Right _ -> expectationFailure "baseline workflow completed instead of leaving a captured prefix"

incrementAndRead :: IORef Int -> IO Int
incrementAndRead ref = atomicModifyIORef' ref (\value -> (value + 1, value + 1))

stableBaseline :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Int
stableBaseline effects = do
  result <- step (StepName "stable-result") (liftIO (incrementAndRead effects))
  liftIO (failWithCapturedPrefix result)

stableCandidate :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Int
stableCandidate effects = step (StepName "stable-result") (liftIO (incrementAndRead effects))

incompatibleCandidate :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Bool
incompatibleCandidate effects = step (StepName "stable-result") (liftIO (incrementAndRead effects) >> pure True)

renamedCandidate :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Int
renamedCandidate effects = step (StepName "renamed-result") (liftIO (incrementAndRead effects))

newtype BaselineAmount = BaselineAmount Int
  deriving stock (Eq, Show)

instance Aeson.ToJSON BaselineAmount where
  toJSON (BaselineAmount amount) = Aeson.toJSON amount

instance Aeson.FromJSON BaselineAmount where
  parseJSON value = BaselineAmount <$> Aeson.parseJSON value

newtype CandidateAmount = CandidateAmount Int
  deriving stock (Eq, Show)

instance Aeson.ToJSON CandidateAmount where
  toJSON (CandidateAmount amount) = Aeson.toJSON amount

instance Aeson.FromJSON CandidateAmount where
  parseJSON value = CandidateAmount . (+ 1) <$> Aeson.parseJSON value

semanticBaseline :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es BaselineAmount
semanticBaseline effects = do
  result <- step (StepName "stable-result") (BaselineAmount <$> liftIO (incrementAndRead effects >> pure 5))
  liftIO (failWithCapturedPrefix result)

semanticCandidate :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es CandidateAmount
semanticCandidate effects =
  step (StepName "stable-result") (CandidateAmount <$> liftIO (incrementAndRead effects >> pure 5))

failWithCapturedPrefix :: value -> IO value
failWithCapturedPrefix _ = throwIO CapturedPrefix

compatibilityPatch :: PatchId
compatibilityPatch = PatchId "compatibility-v2"

prePatchWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es String
prePatchWorkflow effects = do
  _ <- step (StepName "stable-result") (liftIO (incrementAndRead effects))
  (_ :: ()) <- awaitStep (StepName "never-resolved") (pure ())
  pure "baseline"

postPatchWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es String
postPatchWorkflow effects = do
  _ <- step (StepName "stable-result") (liftIO (incrementAndRead effects))
  useNew <- patch compatibilityPatch
  if useNew then pure "new-branch" else pure "old-branch"

awaitingWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Int
awaitingWorkflow arms = awaitStep (StepName "stable-await") (liftIO (incrementAndRead arms) >> pure ())

baselineRotation :: (Workflow :> es) => Eff es Int
baselineRotation = continueAsNew (41 :: Int)

candidateRotation :: (Workflow :> es) => Eff es Int
candidateRotation = restoreSeed (0 :: Int)
