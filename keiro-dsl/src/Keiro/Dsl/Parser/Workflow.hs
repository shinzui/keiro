{-# LANGUAGE ImportQualifiedPost #-}

-- | Durable workflow and operation syntax.
module Keiro.Dsl.Parser.Workflow
  ( pWorkflow,
    pOperation,
  )
where

import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.Parser.Core
import Text.Megaparsec

pWorkflow :: P WorkflowNode
pWorkflow = do
  loc <- getLoc
  keyword "workflow"
  wid <- ident
  keyword "name"
  nm <- stringLit
  keyword "in"
  inTy <- ident
  inFields <- option [] (braces (many pField))
  keyword "out"
  outTy <- ident
  keyword "id"
  keyword "from"
  keyword "input"
  idField <- optional (symbol "." *> ident)
  keyword "via"
  idVia <- ident
  keyword "body"
  body <- many pWfBodyItem
  pure
    WorkflowNode
      { wfId = wid,
        wfStable = nm,
        wfInput = inTy,
        wfInputFields = inFields,
        wfOutput = outTy,
        wfIdField = idField,
        wfIdVia = idVia,
        wfBody = body,
        wfLoc = loc
      }
  where
    pWfBodyItem =
      choice
        [ do
            loc <- getLoc
            WfStep <$> (keyword "step" *> wireWord) <*> (symbol "->" *> ident) <*> pure loc,
          do
            loc <- getLoc
            WfAwait <$> (keyword "await" *> wireWord) <*> (symbol "->" *> ident) <*> pure loc,
          do
            loc <- getLoc
            WfSleep <$> (keyword "sleep" *> wireWord) <*> (keyword "after" *> ident) <*> pure loc,
          do
            loc <- getLoc
            WfChild
              <$> (keyword "child" *> wireWord)
              <*> (keyword "id" *> keyword "input" *> keyword "via" *> ident)
              <*> (symbol "->" *> ident)
              <*> pure loc,
          do
            loc <- getLoc
            WfPatch
              <$> (keyword "patch" *> patchIdWord)
              <*> braces (many pWfBodyItem)
              <*> pure loc,
          do
            loc <- getLoc
            WfContinueAsNew <$> (keyword "continueAsNew" *> ident) <*> pure loc
        ]

pOperation :: P OperationNode
pOperation = do
  loc <- getLoc
  keyword "operation"
  nm <- ident
  shape <-
    choice
      [ pCommandOp,
        pQueryOp,
        pSignalOp,
        pRunOp
      ]
  pure OperationNode {opName = nm, opShape = shape, opLoc = loc}
  where
    pCommandOp = do
      keyword "command"
      keyword "on"
      agg <- ident
      _ <- keyword "stream" *> keyword "from"
      sf <- ident
      keyword "via"
      sv <- ident
      proj <- option [] (keyword "project" *> brackets (many ident))
      pure (CommandOp agg sf sv proj)
    pQueryOp = do
      keyword "query"
      rm <- ident
      keyword "input"
      inp <- ident
      keyword "result"
      res <- pTypeExpr
      cons <- option "Strong" (keyword "consistency" *> ident)
      pure (QueryOp rm inp res cons)
    pSignalOp = do
      keyword "signal"
      lbl <- wireWord
      keyword "of"
      wf <- ident
      _ <- keyword "key" *> keyword "from"
      kf <- ident
      keyword "via"
      kv <- ident
      keyword "value"
      val <- ident
      pure (SignalOp lbl wf kf kv val)
    pRunOp = do
      keyword "run"
      wf <- ident
      keyword "input"
      inp <- ident
      _ <- keyword "outcome" *> symbol "->"
      oc <- ident
      pure (RunOp wf inp oc)
    -- A result type expression, possibly multi-word like @Maybe TransferDecision@.
    pTypeExpr = do
      ws <- some ident
      pure (T.unwords ws)

--------------------------------------------------------------------------------
