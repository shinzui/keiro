-- Created once by keiro-dsl. This module is application-owned; review and edit it to accept conformance changes.
module KeiroConformance.Expectations (expectedServiceConformanceFacts) where

expectedServiceConformanceFacts :: [(String, String)]
expectedServiceConformanceFacts =
  [ ("workflow/WorkspaceProofWorkflow/awaits", "[]")
  , ("workflow/WorkspaceProofWorkflow/body", "[\"step:summarize-proof\"]")
  , ("workflow/WorkspaceProofWorkflow/idField", "proofId")
  , ("workflow/WorkspaceProofWorkflow/idVia", "idText")
  , ("workflow/WorkspaceProofWorkflow/name", "workspace-proof-workflow")
  , ("workflow/WorkspaceProofWorkflow/patches", "[]")
  ]
