-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module TransferRouting.Hospital_load.ReadModelHoles (
    HospitalLoadQueryInput,
    HospitalLoadQueryResult,
    hospitalLoadQuery,
    applyHospitalLoad,
) where

import Data.Text.Encoding qualified as Text
import Generated.TransferRouting.Hospital_load.ReadModelTable (hospitalLoadQualifiedTable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent)

-- HOLE: replace these aliases with the real query input and result types.
type HospitalLoadQueryInput = ()
type HospitalLoadQueryResult = ()

-- HOLE: query "hospital_transfer"."hospital_load" via hospitalLoadQualifiedTable; never rely on search_path.
-- Declared columns:
--   hospital_id text NOT NULL
--   region text NOT NULL
--   available_beds int NOT NULL
hospitalLoadQuery :: HospitalLoadQueryInput -> Tx.Transaction HospitalLoadQueryResult
hospitalLoadQuery _input =
    Tx.sql
        ( Text.encodeUtf8
            ( "SELECT hospital_id FROM "
                <> hospitalLoadQualifiedTable
                <> " WHERE available_beds > 0 ORDER BY available_beds DESC, hospital_id LIMIT 1"
            )
        )

-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.
applyHospitalLoad :: RecordedEvent -> Tx.Transaction ()
applyHospitalLoad _recorded = pure ()
