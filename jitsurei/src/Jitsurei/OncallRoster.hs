{- | The on-call roster read model for the escalation worked example.

Maps a service to the responders currently on call for it, ordered by tier. The
'pagingRouter' in "Jitsurei.Paging" queries this to discover *who to page* for an
incident — a data-dependent recipient set that is not derivable from the
@IncidentRaised@ event alone, which is exactly why paging is a router (effectful
target resolution) rather than a process manager.
-}
module Jitsurei.OncallRoster (
    ResponderId (..),
    responderIdText,
    Responder (..),
    serviceOncallReadModel,
    initializeOncallRosterTable,
    insertOncallStmt,
    selectOncallStmt,
)
where

import Contravariant.Extras (contrazip3)
import Data.Int (Int32)
import Data.Text (Text)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Jitsurei.Incident (Service (..))
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), StrongScope (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

newtype ResponderId = ResponderId Text
    deriving stock (Generic, Eq, Ord, Show)

responderIdText :: ResponderId -> Text
responderIdText (ResponderId value) = value

data Responder = Responder
    { responderId :: !ResponderId
    , tier :: !Int
    }
    deriving stock (Generic, Eq, Ord, Show)

serviceOncallReadModel :: ReadModel Service [Responder]
serviceOncallReadModel =
    ReadModel
        { name = "jitsurei-service-oncall"
        , tableName = "jitsurei_service_oncall"
        , -- This paging demo keeps its unqualified DDL/DML, so its table resolves
          -- in the store search_path's first schema (kiroku). Only the order-summary
          -- read model is migrated to a user-configured schema (EP-4 / MasterPlan 12).
          schema = "kiroku"
        , subscriptionName = "jitsurei-service-oncall-sub"
        , version = 1
        , shapeHash = "jitsurei-service-oncall-v1"
        , defaultConsistency = Eventual
        , strongScope = EntireLog
        , query = \(Service service) -> Tx.statement service selectOncallStmt
        }

initializeOncallRosterTable :: Tx.Transaction ()
initializeOncallRosterTable =
    Tx.sql
        """
        CREATE TABLE IF NOT EXISTS jitsurei_service_oncall (
          service TEXT NOT NULL,
          responder_id TEXT NOT NULL,
          tier INT NOT NULL
        )
        """

insertOncallStmt :: Statement (Text, Text, Int32) ()
insertOncallStmt =
    preparable
        """
        INSERT INTO jitsurei_service_oncall (service, responder_id, tier)
        VALUES ($1, $2, $3)
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
        )
        D.noResult

selectOncallStmt :: Statement Text [Responder]
selectOncallStmt =
    preparable
        """
        SELECT responder_id, tier
        FROM jitsurei_service_oncall
        WHERE service = $1
        ORDER BY tier, responder_id
        """
        (E.param (E.nonNullable E.text))
        ( D.rowList
            ( Responder
                <$> (ResponderId <$> D.column (D.nonNullable D.text))
                <*> (fromIntegral <$> D.column (D.nonNullable D.int4))
            )
        )
