module Main (main) where

import Conformance.MappedQueue.Domain (Geometry (..), JobMetadata (..), JobPayload (..))
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Generated.MappedQueue.MappedJobs.Queue
import Generated.MappedQueue.MappedJobs.QueueCodec (mappedJobsJobCodec)
import Generated.MappedQueue.StructuralConformance (structuralConformanceAssertions)
import Keiro.PGMQ.Codec (JobCodec (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  let job = JobPayload "job-7" "priority-job" (Just (JobMetadata (Just "priority"))) (Geometry "POINT (1 2)")
      payload = MappedJob job Nothing (object ["trace_id" .= ("trace-7" :: Text)])
      encoded = encodeMappedJob payload
      expectedPayload =
        object
          [ "job"
              .= object
                [ "job_id" .= ("job-7" :: Text),
                  "label" .= ("priority-job" :: Text),
                  "metadata" .= object ["note" .= ("priority" :: Text)],
                  "geometry" .= ("POINT (1 2)" :: Text)
                ],
            "maybe_job" .= Null,
            "trace" .= object ["trace_id" .= ("trace-7" :: Text)]
          ]
      envelope =
        object
          [ "v" .= (1 :: Int),
            "t" .= ("MappedJob" :: Text),
            "data" .= expectedPayload
          ]
      missingRequired = case encoded of
        Object fields -> parseMappedJob (Object (KeyMap.delete "job" fields))
        _ -> error "mapped queue encoder did not produce an object"
      unknownNested = case encoded of
        Object fields -> case KeyMap.lookup "job" fields of
          Just (Object jobFields) ->
            parseMappedJob (Object (KeyMap.insert "job" (Object (KeyMap.insert "extra" Null jobFields)) fields))
          _ -> error "mapped queue job field was not an object"
        _ -> error "mapped queue encoder did not produce an object"
      assertions =
        [ ("payload bytes", encoded == expectedPayload),
          ("domain round-trip", parseMappedJob encoded == Right payload),
          ("required key rejects omission", isLeft missingRequired),
          ("present null admits Optional", (maybeJob <$> parseMappedJob encoded) == Right Nothing),
          ("nested reject-unknown policy", isLeft unknownNested),
          ("versioned {v,t,data} envelope", encodeJob mappedJobsJobCodec payload == envelope && decodeJob mappedJobsJobCodec envelope == Right payload),
          ("schema-v1 physical queue", queuePhysical == "mapped_jobs")
        ]
          <> [("structural/" <> label, passed) | (label, passed) <- structuralConformanceAssertions]
  forM_ assertions $ \(label, passed) ->
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd assertions) exitFailure

isLeft :: Either problem value -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
