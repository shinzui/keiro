module Keiro.Ops.Env
  ( OutputMode (..),
  )
where

data OutputMode
  = HumanTable
  | Json
  deriving stock (Eq, Show)
