{-# LANGUAGE MultilineStrings #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module TransferRouting.HospitalLoad.ReadModelHoles
  ( hospitalLoadQuery
  ) where

import Generated.TransferRouting.HospitalLoad.ReadModelTable (hospitalLoadQualifiedTable)
import Generated.TransferRouting.HospitalLoad.QueryContract (HospitalLoadQueryInput, HospitalLoadQueryResult)
import Conformance.DeclarativeRouter.Domain (HospitalLoadRow (..), TransferRouteInput (..))
import Data.Text (Text)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx

hospitalLoadQuery :: HospitalLoadQueryInput -> Tx.Transaction HospitalLoadQueryResult
hospitalLoadQuery (TransferRouteInput _transferNeedId inputRegion) =
  hospitalLoadQualifiedTable `seq` Tx.statement inputRegion hospitalLoadQueryStatement

hospitalLoadQueryStatement :: Statement Text [HospitalLoadRow]
hospitalLoadQueryStatement =
  preparable
    """
    SELECT hospital_id, region, available_beds
    FROM public.hospital_load
    WHERE region = $1
      AND available_beds > 0
    ORDER BY query_order
    """
    (E.param (E.nonNullable E.text))
    ( D.rowList
        ( HospitalLoadRow
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> (fromIntegral <$> D.column (D.nonNullable D.int4))
        )
    )
