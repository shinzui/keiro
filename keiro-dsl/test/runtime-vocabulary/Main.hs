-- | Cross-package guard for vocabularies keiro-dsl must know but cannot import.
--
-- keiro-dsl validates specs without depending on the @keiro@ runtime package, so
-- a handful of runtime vocabularies are restated in
-- "Keiro.Dsl.Validate". A restatement can drift; this suite is the thing that
-- stops it, by depending on both packages and comparing them directly.
--
-- Vocabularies keiro-dsl imports rather than restates (the integration envelope
-- header names, which live in @keiro-core@) need no guard and have none.
module Main (main) where

import Data.Text qualified as T
import Keiro.Dsl.Validate (runtimeTimerStatuses)
import Keiro.Timer.Schema (TimerStatus)
import Shibuya
import System.Exit (exitFailure)

main :: IO ()
main = do
  let actual = map (T.pack . show) [minBound .. maxBound :: TimerStatus]
  if actual == runtimeTimerStatuses
    then
      putStrLn
        ( "runtime vocabulary: timer statuses agree ("
            <> show (length actual)
            <> " constructors)"
        )
    else do
      putStrLn "runtime vocabulary: timer statuses DIVERGED"
      putStrLn ("  Keiro.Timer.Schema.TimerStatus: " <> show actual)
      putStrLn ("  Keiro.Dsl.Validate.runtimeTimerStatuses: " <> show runtimeTimerStatuses)
      putStrLn "  Update runtimeTimerStatuses to match the runtime, then rerun."
      exitFailure
  mapM_ verifySelectionReason selectionReasonCodes
  putStrLn
    ( "runtime vocabulary: router selection dead-letter codes agree ("
        <> show (length selectionReasonCodes)
        <> " codes)"
    )

selectionReasonCodes :: [T.Text]
selectionReasonCodes =
  [ "keiro.router.selection.empty",
    "keiro.router.selection.query_failed",
    "keiro.router.selection.evaluation_failed",
    "keiro.router.selection.target_conflict",
    "keiro.router.selection.recipient_overflow"
  ]

verifySelectionReason :: T.Text -> IO ()
verifySelectionReason expectedCode =
  case mkDeadLetterCode expectedCode of
    Left err -> do
      putStrLn ("runtime vocabulary: valid router selection code was rejected: " <> show err)
      exitFailure
    Right code -> do
      let detail = "bounded public API proof"
          reason = ApplicationFailure code detail
          expectedRendering = expectedCode <> ": " <> detail
          actualCode = deadLetterCodeText (deadLetterReasonCode reason)
          actualDetail = deadLetterReasonDetail reason
          actualRendering = renderDeadLetterReason reason
      ensureEqual "code" expectedCode actualCode
      ensureEqual "detail" (Just detail) actualDetail
      ensureEqual "rendering" expectedRendering actualRendering

ensureEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
ensureEqual field expected actual =
  if expected == actual
    then pure ()
    else mismatch field expected actual

mismatch :: (Show a) => String -> a -> a -> IO ()
mismatch field expected actual = do
  putStrLn ("runtime vocabulary: router selection " <> field <> " DIVERGED")
  putStrLn ("  expected: " <> show expected)
  putStrLn ("  actual:   " <> show actual)
  exitFailure
