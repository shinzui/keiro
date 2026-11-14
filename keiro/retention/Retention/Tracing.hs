{-# LANGUAGE OverloadedStrings #-}

module Retention.Tracing (withRecordingTracer) where

import Control.Exception (bracket)
import Control.Monad (unless)
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Processor.Span (SpanProcessor (..))
import OpenTelemetry.Trace.Core

-- Benchmark SDK work without exporting I/O or accumulating completed spans.
-- Check recording explicitly: processor-free providers can be non-recording.
withRecordingTracer :: (Tracer -> IO a) -> IO a
withRecordingTracer action = bracket acquire (\(provider, _) -> shutdownTracerProvider provider Nothing) (action . snd)
  where
    acquire = do
      (processor, _) <- inMemoryListExporter
      -- Keep the SDK's recording path but discard completed spans immediately.
      let discard = processor {spanProcessorOnEnd = const (pure ())}
      provider <- createTracerProvider [discard] emptyTracerProviderOptions
      let tracer = makeTracer provider "keiro-bench" tracerOptions
      inSpan' tracer "recording-check" defaultSpanArguments $ \span -> do
        recording <- isRecording span
        unless recording (fail "benchmark tracer is not recording")
      pure (provider, tracer)
