{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once
-- and never overwrites it. Fill each HOLE and run the generated harness.
module ImportPlanning.Bindings (
    orderStatusFixtures
  , orderStatusBinding
  , localCollisionFixtures
  , localCollisionBinding
  , invoiceStatusFixtures
  , invoiceStatusBinding
  , detailsFixtures
  , detailsBinding
) where

import Data.Aeson (Value (String))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Generated.ImportPlanningCollisions.Structural.Shape.Details qualified as ShapeDetails
import ImportPlanning.Consumer.Domain (CollisionLedgerCommand (..))
import ImportPlanning.Consumer.Invoice.Types qualified as InvoiceTypes
import ImportPlanning.Consumer.Order.Types qualified as OrderTypes
import ImportPlanning.Consumer.Shared.Types (Details)
import ImportPlanning.Consumer.Shared.Types qualified as SharedTypes
import Keiro.Codec.Nominal (NominalBinding (..), NominalFixture (..), NominalFixtureCases (..))
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

-- HOLE: provide deterministic labelled expected-wire fixtures for OrderStatus
orderStatusFixtures :: NominalFixtureCases OrderTypes.Status
orderStatusFixtures = NominalFixtureCases (NominalFixture "order-pending" (String "order-pending") OrderTypes.OrderPending :| [])

-- HOLE: complete both total directions; the generated codec remains wire authority.
orderStatusBinding :: NominalBinding OrderTypes.Status Text
orderStatusBinding =
  NominalBinding
    { nominalToRepresentation = \case OrderTypes.OrderPending -> "order-pending"
    , nominalFromRepresentation = \case "order-pending" -> OrderTypes.OrderPending; value -> error ("unexpected order status: " <> show value)
    }

-- HOLE: provide deterministic labelled expected-wire fixtures for LocalCollision
localCollisionFixtures :: NominalFixtureCases CollisionLedgerCommand
localCollisionFixtures = NominalFixtureCases (NominalFixture "record" (String "record") (CollisionLedgerCommand "record") :| [])

-- HOLE: complete both total directions; the generated codec remains wire authority.
localCollisionBinding :: NominalBinding CollisionLedgerCommand Text
localCollisionBinding =
  NominalBinding
    { nominalToRepresentation = \case CollisionLedgerCommand value -> value
    , nominalFromRepresentation = CollisionLedgerCommand
    }

-- HOLE: provide deterministic labelled expected-wire fixtures for InvoiceStatus
invoiceStatusFixtures :: NominalFixtureCases InvoiceTypes.Status
invoiceStatusFixtures = NominalFixtureCases (NominalFixture "invoice-open" (String "invoice-open") InvoiceTypes.InvoiceOpen :| [])

-- HOLE: complete both total directions; the generated codec remains wire authority.
invoiceStatusBinding :: NominalBinding InvoiceTypes.Status Text
invoiceStatusBinding =
  NominalBinding
    { nominalToRepresentation = \case InvoiceTypes.InvoiceOpen -> "invoice-open"
    , nominalFromRepresentation = \case "invoice-open" -> InvoiceTypes.InvoiceOpen; value -> error ("unexpected invoice status: " <> show value)
    }

-- HOLE: provide deterministic labelled conformance fixtures for Details
detailsFixtures :: FixtureCases Details
detailsFixtures = FixtureCases (("details", SharedTypes.Details "details") :| [])

-- HOLE: complete both total directions; wire policy remains in the generated codec.
detailsBinding :: StructuralBinding Details ShapeDetails.DetailsShape
detailsBinding =
  StructuralBinding
    { bindingToShape = \case
      SharedTypes.Details labelValue -> ShapeDetails.Details labelValue
    , bindingFromShape = \case
      ShapeDetails.Details labelValue -> SharedTypes.Details labelValue
    }
