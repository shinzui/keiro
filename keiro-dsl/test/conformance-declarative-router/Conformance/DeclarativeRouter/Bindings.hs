module Conformance.DeclarativeRouter.Bindings
  ( transferRouteInputCases,
    transferRouteInputBinding,
    hospitalLoadRowCases,
    hospitalLoadRowBinding,
  )
where

import Conformance.DeclarativeRouter.Domain qualified as Domain
import Data.List.NonEmpty (NonEmpty (..))
import Generated.TransferRouting.Structural.Shape.HospitalLoadRow qualified as ShapeHospitalLoadRow
import Generated.TransferRouting.Structural.Shape.TransferRouteInput qualified as ShapeTransferRouteInput
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

transferRouteInputCases :: FixtureCases Domain.TransferRouteInput
transferRouteInputCases =
  FixtureCases
    ( ("west", Domain.TransferRouteInput "transfer-7" "west")
        :| [("east", Domain.TransferRouteInput "transfer-8" "east")]
    )

transferRouteInputBinding :: StructuralBinding Domain.TransferRouteInput ShapeTransferRouteInput.TransferRouteInputShape
transferRouteInputBinding =
  StructuralBinding
    { bindingToShape = \(Domain.TransferRouteInput transferNeedId region) ->
        ShapeTransferRouteInput.TransferRouteInput transferNeedId region,
      bindingFromShape = \(ShapeTransferRouteInput.TransferRouteInput transferNeedId region) ->
        Domain.TransferRouteInput transferNeedId region
    }

hospitalLoadRowCases :: FixtureCases Domain.HospitalLoadRow
hospitalLoadRowCases =
  FixtureCases
    ( ("eligible", Domain.HospitalLoadRow "hospital-a" "west" 2)
        :| [("ineligible", Domain.HospitalLoadRow "hospital-z" "east" 0)]
    )

hospitalLoadRowBinding :: StructuralBinding Domain.HospitalLoadRow ShapeHospitalLoadRow.HospitalLoadRowShape
hospitalLoadRowBinding =
  StructuralBinding
    { bindingToShape = \(Domain.HospitalLoadRow hospitalId region availableBeds) ->
        ShapeHospitalLoadRow.HospitalLoadRow hospitalId region availableBeds,
      bindingFromShape = \(ShapeHospitalLoadRow.HospitalLoadRow hospitalId region availableBeds) ->
        Domain.HospitalLoadRow hospitalId region availableBeds
    }
