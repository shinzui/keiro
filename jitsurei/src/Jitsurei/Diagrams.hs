module Jitsurei.Diagrams
  ( fulfillmentStreamMermaid
  , orderStreamMermaid
  )
where

import Data.Text (Text)
import Keiki.Render.Mermaid (toMermaid)
import Jitsurei.FulfillmentProcess (fulfillmentTransducer)
import Jitsurei.OrderStream (orderTransducer)

orderStreamMermaid :: Text
orderStreamMermaid = toMermaid orderTransducer

fulfillmentStreamMermaid :: Text
fulfillmentStreamMermaid = toMermaid fulfillmentTransducer
