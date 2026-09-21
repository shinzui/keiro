{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import Control.Monad (unless)
import Data.Proxy (Proxy (..))
import Data.Time (UTCTime (..), fromGregorian)
import Keiki.Core
import Keiki.Symbolic (checkTransitionDeterminismSym)

-- Feasibility evidence for ExecPlan 267, not generated DSL acceptance.
-- Dependency source: mori://shinzui/keiki/packages/keiki
-- Run from the repository root with cabal exec -- runghc -XOverloadedLabels <this-file>.
data DormantFlag

instance FieldProjection DormantFlag where
  type FieldName DormantFlag = "value"
  type FieldOwner DormantFlag = Bool
  type FieldResult DormantFlag = Bool
  fieldShapeId _ = "plan267.bool.v1"
  projectFieldValue _ = id

type Rs = '[ '("dormant", Bool), '("since", Maybe UTCTime)]

type Fields = '[ '("at", UTCTime)]

data Vertex = Active deriving (Eq, Ord, Show, Enum, Bounded)

inC :: InCtor UTCTime Fields
inC = unavailableInCtor "Mark" (\t -> Just (RCons (Proxy @"at") t RNil)) (\(RCons _ t RNil) -> t)

wire :: WireCtor UTCTime (UTCTime, ())
wire = unavailableWireCtor "Marked" (\t -> Just (t, ())) fst

input :: Term Rs UTCTime Fields UTCTime
input = TInpCtorField inC ZIdx

machine :: Bool -> SymTransducer (HsPred Rs UTCTime) Rs Vertex UTCTime UTCTime
machine hidden =
  SymTransducer
    { initial = Active,
      initialRegs = RCons (Proxy @"dormant") False (RCons (Proxy @"since") Nothing RNil),
      isFinal = const False,
      edgesOut = const [edge False (TApp1 Just input), edge True (opaqueLit Nothing)]
    }
  where
    edge :: Bool -> Term Rs UTCTime Fields (Maybe UTCTime) -> Edge (HsPred Rs UTCTime) Rs UTCTime UTCTime Vertex
    edge before value =
      Edge
        { guard = PAnd (PInCtor inC) (PEq (TReg ZIdx) (lit before)),
          update = UCombine (USet (#dormant :: IndexN "dormant" Rs Bool) (lit (not before))) (USet (#since :: IndexN "since" Rs (Maybe UTCTime)) value),
          output = [pack inC wire (OFCons (if hidden then lit stamp else input) OFNil)],
          target = Active,
          mode = Live
        }

stamp :: UTCTime
stamp = UTCTime (fromGregorian 2026 9 21) 0

observed :: (Vertex, RegFile Rs) -> (Vertex, Bool, Maybe UTCTime)
observed (v, r) = (v, r ! ZIdx, r ! SIdx ZIdx)

assert :: String -> Bool -> IO ()
assert label ok = do
  putStrLn ((if ok then "PASS " else "FAIL ") <> label)
  unless ok (fail label)

projectedMachine :: SymTransducer (HsPred Rs UTCTime) Rs Vertex UTCTime UTCTime
projectedMachine = (machine False) {edgesOut = \v -> map replaceUpdate (edgesOut (machine False) v)}
  where
    replaceUpdate (Edge g _ o targetVertex edgeMode) =
      Edge
        g
        ( USet
            (#since :: IndexN "since" Rs (Maybe UTCTime))
            (TApp1 (\_ -> Just stamp) (regProj (fieldWitness @DormantFlag) ZIdx))
        )
        o
        targetVertex
        edgeMode

projectionWarning :: TransducerValidationWarning Vertex -> Bool
projectionWarning ProjectionOutsideGuard {} = True
projectionWarning _ = False

main :: IO ()
main = do
  let t = machine False
  assert "default validation accepts lifted and initial updates" (null (validateTransducer defaultValidationOptions t))
  assert "symbolic complementary siblings are disjoint" (null (checkTransitionDeterminismSym t))
  assert "missing head recovery remains rejected" (not (null (validateTransducer defaultValidationOptions (machine True))))
  assert "projection beneath lift remains rejected" (any projectionWarning (validateTransducer defaultValidationOptions projectedMachine))
  case step t (initial t, initialRegs t) stamp of
    Nothing -> fail "first step"
    Just (v, r, es) -> do
      assert "lift stores exact timestamp" (observed (v, r) == (Active, True, Just stamp))
      assert "full replay of lifted write agrees" (fmap observed (reconstitute t es) == Just (observed (v, r)))
      case step t (v, r) stamp of
        Nothing -> fail "second step"
        Just (v2, r2, es2) -> do
          assert "initial clears timestamp" (observed (v2, r2) == (Active, False, Nothing))
          assert "full replay of both siblings agrees" (fmap observed (reconstitute t (es <> es2)) == Just (observed (v2, r2)))
