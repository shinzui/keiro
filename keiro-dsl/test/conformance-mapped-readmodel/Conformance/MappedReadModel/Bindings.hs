module Conformance.MappedReadModel.Bindings
  ( accountLookupBinding,
    accountLookupCases,
    accountProfileBinding,
    accountProfileCases,
    accountSummaryBinding,
    accountSummaryCases,
    tenantKeyBinding,
    tenantKeyCases,
    unusedFilterBinding,
    unusedFilterCases,
  )
where

import Conformance.MappedReadModel.Domain qualified as Domain
import Data.List.NonEmpty (NonEmpty (..))
import Generated.MappedReadmodel.Structural.Shape.AccountLookup qualified as LookupShape
import Generated.MappedReadmodel.Structural.Shape.AccountProfile qualified as ProfileShape
import Generated.MappedReadmodel.Structural.Shape.AccountSummary qualified as SummaryShape
import Generated.MappedReadmodel.Structural.Shape.TenantKey qualified as TenantShape
import Generated.MappedReadmodel.Structural.Shape.UnusedFilter qualified as FilterShape
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

tenantKeyBinding :: StructuralBinding Domain.TenantKey TenantShape.TenantKeyShape
tenantKeyBinding =
  StructuralBinding
    { bindingToShape = \(Domain.TenantKey tenantId) -> TenantShape.TenantKey tenantId,
      bindingFromShape = \(TenantShape.TenantKey tenantId) -> Domain.TenantKey tenantId
    }

accountLookupBinding :: StructuralBinding Domain.AccountLookup LookupShape.AccountLookupShape
accountLookupBinding =
  StructuralBinding
    { bindingToShape = \(Domain.AccountLookup accountId tenant) ->
        LookupShape.AccountLookup accountId (bindingToShape tenantKeyBinding tenant),
      bindingFromShape = \(LookupShape.AccountLookup accountId tenant) ->
        Domain.AccountLookup accountId (bindingFromShape tenantKeyBinding tenant)
    }

accountProfileBinding :: StructuralBinding Domain.AccountProfile ProfileShape.AccountProfileShape
accountProfileBinding =
  StructuralBinding
    { bindingToShape = \(Domain.AccountProfile displayName) -> ProfileShape.AccountProfile displayName,
      bindingFromShape = \(ProfileShape.AccountProfile displayName) -> Domain.AccountProfile displayName
    }

accountSummaryBinding :: StructuralBinding Domain.AccountSummary SummaryShape.AccountSummaryShape
accountSummaryBinding =
  StructuralBinding
    { bindingToShape = \(Domain.AccountSummary accountId tenant profile) ->
        SummaryShape.AccountSummary
          accountId
          (bindingToShape tenantKeyBinding tenant)
          (bindingToShape accountProfileBinding <$> profile),
      bindingFromShape = \(SummaryShape.AccountSummary accountId tenant profile) ->
        Domain.AccountSummary
          accountId
          (bindingFromShape tenantKeyBinding tenant)
          (bindingFromShape accountProfileBinding <$> profile)
    }

unusedFilterBinding :: StructuralBinding Domain.UnusedFilter FilterShape.UnusedFilterShape
unusedFilterBinding =
  StructuralBinding
    { bindingToShape = \(Domain.UnusedFilter prefix) -> FilterShape.UnusedFilter prefix,
      bindingFromShape = \(FilterShape.UnusedFilter prefix) -> Domain.UnusedFilter prefix
    }

tenantKeyCases :: FixtureCases Domain.TenantKey
tenantKeyCases = FixtureCases (("main", Domain.TenantKey "tenant-main") :| [])

accountLookupCases :: FixtureCases Domain.AccountLookup
accountLookupCases = FixtureCases (("known", Domain.fixtureAccountLookup) :| [])

accountProfileCases :: FixtureCases Domain.AccountProfile
accountProfileCases = FixtureCases (("named", Domain.AccountProfile "Ada") :| [])

accountSummaryCases :: FixtureCases Domain.AccountSummary
accountSummaryCases =
  FixtureCases
    ( ("without-profile", Domain.AccountSummary "account-6" (Domain.TenantKey "tenant-main") Nothing)
        :| [("with-profile", Domain.fixtureAccountSummary)]
    )

unusedFilterCases :: FixtureCases Domain.UnusedFilter
unusedFilterCases = FixtureCases (("unused", Domain.UnusedFilter "acct-") :| [])
