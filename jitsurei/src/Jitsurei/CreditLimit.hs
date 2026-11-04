module Jitsurei.CreditLimit
  ( CreditLimitState (..),
    CreditLimitCommand (..),
    AdjustCreditData (..),
    CreditLimitEvent (..),
    CreditAdjustedData (..),
    CreditLimitRegs,
    initialCreditLimitRegs,
    creditLimitStateText,
    creditLimitTransducer,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer, (.&&), (.+), (.==), (.>=))
import Keiki.Core qualified as K
import Keiki.Generics.TH (deriveAggregate)
import Keiki.Shape (CanonicalStateShape)

-- | A deliberately small scalar aggregate whose generated diagram is the
-- documentation proof for readable guards, assignments, and literal values.
data CreditLimitState
  = CreditOpen
  | CreditReviewed
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

instance CanonicalStateShape CreditLimitState

creditLimitStateText :: CreditLimitState -> Text
creditLimitStateText CreditOpen = "credit_open"
creditLimitStateText CreditReviewed = "credit_reviewed"

instance ToJSON CreditLimitState where
  toJSON = toJSON . creditLimitStateText

instance FromJSON CreditLimitState where
  parseJSON = withText "CreditLimitState" $ \case
    "credit_open" -> pure CreditOpen
    "credit_reviewed" -> pure CreditReviewed
    _ -> fail "unknown credit-limit state"

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

initialCreditLimitRegs :: RegFile CreditLimitRegs
initialCreditLimitRegs =
  RCons (Proxy @"balance") (0 :: Int) $
    RCons (Proxy @"active") True RNil
