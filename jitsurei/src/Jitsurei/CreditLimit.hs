module Jitsurei.CreditLimit
  ( CreditLimitState (..),
    CreditLimitCommand (..),
    AdjustCreditData (..),
    CreditLimitEvent (..),
    CreditAdjustedData (..),
    CreditLimitRegs,
    creditLimitTransducer,
  )
where

import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer, (.&&), (.+), (.==), (.>=))
import Keiki.Core qualified as K
import Keiki.Generics.TH (deriveAggregate)

-- | A deliberately small scalar aggregate whose generated diagram is the
-- documentation proof for readable guards, assignments, and literal values.
data CreditLimitState
  = CreditOpen
  | CreditReviewed
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data CreditLimitCommand = AdjustCredit !AdjustCreditData
  deriving stock (Generic, Eq, Show)

data AdjustCreditData = AdjustCreditData
  { delta :: !Int
  }
  deriving stock (Generic, Eq, Show)

data CreditLimitEvent = CreditAdjusted !CreditAdjustedData
  deriving stock (Generic, Eq, Show)

data CreditAdjustedData = CreditAdjustedData
  { delta :: !Int
  }
  deriving stock (Generic, Eq, Show)

type CreditLimitRegs =
  '[ '("balance", Int),
     '("active", Bool)
   ]

$(deriveAggregate ''CreditLimitCommand ''CreditLimitRegs ''CreditLimitEvent)

creditLimitTransducer ::
  SymTransducer
    (HsPred CreditLimitRegs CreditLimitCommand)
    CreditLimitRegs
    CreditLimitState
    CreditLimitCommand
    CreditLimitEvent
creditLimitTransducer =
  B.buildTransducer CreditOpen initialCreditLimitRegs (== CreditReviewed) do
    B.from CreditOpen do
      B.onCmd inCtorAdjustCredit $ \d -> B.do
        B.requireGuard $
          d.delta
            .>= K.lit (-100 :: Int)
            .&& B.reg @"active"
            .== K.lit True
        B.slot @"balance" =: (B.reg @"balance" .+ d.delta)
        B.slot @"active" =: K.lit False
        B.emit
          wireCreditAdjusted
          CreditAdjustedTermFields
            { delta = d.delta
            }
        B.goto CreditReviewed
  where
    initialCreditLimitRegs =
      RCons (Proxy @"balance") (0 :: Int) $
        RCons (Proxy @"active") True RNil
