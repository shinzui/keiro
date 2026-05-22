module Jitsurei.Diagrams
  ( fulfillmentStreamMermaid
  , orderStreamMermaid
  , incidentStreamMermaid
  , pageStreamMermaid
  , escalationStreamMermaid
  )
where

import Data.Text (Text)
import Keiki.Render.Mermaid (toMermaid)
import Jitsurei.EscalationProcess (escalationTransducer)
import Jitsurei.FulfillmentProcess (fulfillmentTransducer)
import Jitsurei.Incident (incidentTransducer)
import Jitsurei.OrderStream (orderTransducer)
import Jitsurei.Paging (pageTransducer)

orderStreamMermaid :: Text
orderStreamMermaid = toMermaid orderTransducer

fulfillmentStreamMermaid :: Text
fulfillmentStreamMermaid = toMermaid fulfillmentTransducer

incidentStreamMermaid :: Text
incidentStreamMermaid = toMermaid incidentTransducer

pageStreamMermaid :: Text
pageStreamMermaid = toMermaid pageTransducer

escalationStreamMermaid :: Text
escalationStreamMermaid = toMermaid escalationTransducer
