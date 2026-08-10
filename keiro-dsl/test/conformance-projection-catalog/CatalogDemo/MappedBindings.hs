{-# LANGUAGE OverloadedStrings #-}

module CatalogDemo.MappedBindings
  ( orderPayloadCases,
    sharedReferenceCases,
  )
where

import CatalogDemo.MappedDomain
import Data.List.NonEmpty (NonEmpty (..))
import Keiro.Codec.Structural (FixtureCases (..))

orderPayloadCases :: FixtureCases OrderPayload
orderPayloadCases =
  FixtureCases
    ( ("primary", OrderPayload "order-primary")
        :| [("secondary", OrderPayload "order-secondary")]
    )

sharedReferenceCases :: FixtureCases SharedReference
sharedReferenceCases =
  FixtureCases
    ( ("shared-a", SharedReference "shared-a")
        :| [("shared-b", SharedReference "shared-b")]
    )
