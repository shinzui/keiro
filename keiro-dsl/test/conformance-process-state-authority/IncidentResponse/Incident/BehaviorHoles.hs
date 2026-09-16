-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module IncidentResponse.Incident.BehaviorHoles (behaviorWitnesses) where

import Generated.IncidentResponse.Incident.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-0aad69728dee8fec") -- IncidentOpen x EscalateIncident: live transition
  , Pending (BehaviorKey "behavior-v1-36c541281e30554e") -- IncidentOpen x AcknowledgeIncident: live transition
  ]