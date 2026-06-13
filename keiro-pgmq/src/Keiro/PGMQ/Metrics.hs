{-# LANGUAGE DataKinds #-}

{- | Typed, 'Job'-keyed queue metrics for @keiro-pgmq@.

PGMQ stores each queue as a table @pgmq.q_<name>@; its @metrics()@ function reports
depth and message age. These helpers fetch that 'QueueMetrics' for a job's MAIN
queue and its DEAD-LETTER queue without the caller deriving any physical name.

Use 'jobDlqMetrics' (its 'queueLength') for the depth alerting that
'Keiro.PGMQ.Dlq' recommends; pair it with 'Keiro.PGMQ.Dlq.archiveDlq' /
'Keiro.PGMQ.Dlq.purgeDlq' for retention.
-}
module Keiro.PGMQ.Metrics (
    QueueMetrics (..),
    jobQueueMetrics,
    jobDlqMetrics,
    queueDepth,
    allJobMetrics,
) where

import Keiro.PGMQ.Job (Job (..))
import Keiro.PGMQ.Runtime (QueueRef (..))
import "base" Data.Int (Int64)
import "effectful-core" Effectful (Eff, (:>))
import "pgmq-effectful" Pgmq.Effectful (Pgmq, QueueMetrics (..))
import "pgmq-effectful" Pgmq.Effectful qualified as Pgmq

-- | The metrics for a job's MAIN queue (depth, visible depth, oldest/newest age, throughput).
jobQueueMetrics :: (Pgmq :> es) => Job p -> Eff es QueueMetrics
jobQueueMetrics job = Pgmq.queueMetrics job.jobQueue.physicalName

-- | The metrics for a job's DEAD-LETTER queue. Use its 'queueLength' for depth alerting.
jobDlqMetrics :: (Pgmq :> es) => Job p -> Eff es QueueMetrics
jobDlqMetrics job = Pgmq.queueMetrics job.jobQueue.dlqName

-- | The main queue's immediately-readable depth (PGMQ 'queueVisibleLength'): "work waiting".
queueDepth :: (Pgmq :> es) => Job p -> Eff es Int64
queueDepth job = do
    metrics <- jobQueueMetrics job
    pure metrics.queueVisibleLength

-- | Every queue's metrics (passthrough over 'Pgmq.Effectful.allQueueMetrics'); not Job-keyed.
allJobMetrics :: (Pgmq :> es) => Eff es [QueueMetrics]
allJobMetrics = Pgmq.allQueueMetrics
