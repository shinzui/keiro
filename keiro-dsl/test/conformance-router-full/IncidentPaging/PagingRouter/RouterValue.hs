{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

module IncidentPaging.PagingRouter.RouterValue (
    IncidentRaised (..),
    pagingRouter,
    resolveTargets,
) where

import Data.Text (Text)
import Effectful (Eff)
import Generated.IncidentPaging.Page.Domain qualified as Page
import Generated.IncidentPaging.Page.EventStream (pageCategory, pageEventStream)
import Generated.IncidentPaging.PagingRouter.Router (pagingRouterName)
import Keiki.Core (HsPred)
import Keiro.ProcessManager (PMCommand (..))
import Keiro.Router (Router (..))
import Keiro.Stream (entityStream)

data IncidentRaised = IncidentRaised
    { incidentId :: !Text
    , service :: !Text
    }
    deriving stock (Eq, Show)

resolveTargets :: IncidentRaised -> Eff '[] [PMCommand Page.PageCommand]
resolveTargets input =
    pure
        [ PMCommand
            { target = entityStream pageCategory (input.incidentId <> "-responder-a")
            , command = Page.SendPage (Page.SendPageData input.incidentId "responder-a")
            }
        , PMCommand
            { target = entityStream pageCategory (input.incidentId <> "-responder-b")
            , command = Page.SendPage (Page.SendPageData input.incidentId "responder-b")
            }
        ]

pagingRouter ::
    Router
        IncidentRaised
        (HsPred Page.PageRegs Page.PageCommand)
        Page.PageRegs
        Page.PageVertex
        Page.PageCommand
        Page.PageEvent
        '[]
pagingRouter =
    Router
        { name = pagingRouterName
        , key = \input -> input.incidentId
        , resolve = resolveTargets
        , targetEventStream = pageEventStream
        , targetProjections = const []
        }
