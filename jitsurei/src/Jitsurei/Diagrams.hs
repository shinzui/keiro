module Jitsurei.Diagrams
  ( creditLimitMermaid,
    fulfillmentStreamMermaid,
    orderStreamMermaid,
    incidentStreamMermaid,
    pageStreamMermaid,
    escalationStreamMermaid,
  )
where

import Data.Text (Text)
import Jitsurei.CreditLimit (creditLimitTransducer)
import Jitsurei.EscalationProcess (escalationTransducer)
import Jitsurei.FulfillmentProcess (fulfillmentTransducer)
import Jitsurei.Incident (incidentTransducer)
import Jitsurei.OrderStream (orderTransducer)
import Jitsurei.Paging (pageTransducer)
import Keiki.Render.Mermaid (toMermaid)

creditLimitMermaid :: Text
creditLimitMermaid = toMermaid creditLimitTransducer

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
