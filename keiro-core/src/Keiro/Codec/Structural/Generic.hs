{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Exact, opt-in nominal derivation for structural bindings.
--
-- The derivation supplies only nominal construction and destruction; wire keys,
-- union tags, presence, nullability, and defaults remain exclusively in the
-- @.keiro@ spec and the generated codec. Exact representation mismatches fail at
-- compile time; both binding laws and finite codec cases remain required evidence
-- against implementation defects and semantic mistakes.
module Keiro.Codec.Structural.Generic
  ( GNominalBinding,
    genericStructuralBinding,
  )
where

import Data.Kind (Constraint, Type)
import GHC.Generics
import GHC.TypeLits (ErrorMessage (..), TypeError)
import Keiro.Codec.Structural (StructuralBinding (..))

-- | Generic representations with identical constructor names, selector names,
-- field order, arity, and field types. There are deliberately no coercion,
-- prefix-stripping, or positional-only options.
class GNominalBinding (domain :: Type -> Type) (shape :: Type -> Type) where
  gNominalToShape :: domain parameter -> shape parameter
  gNominalFromShape :: shape parameter -> domain parameter

instance {-# OVERLAPPING #-} (GNominalBinding domain shape) => GNominalBinding (M1 D domainMeta domain) (M1 D shapeMeta shape) where
  gNominalToShape (M1 value) = M1 (gNominalToShape value)
  gNominalFromShape (M1 value) = M1 (gNominalFromShape value)

instance {-# OVERLAPPING #-} (SameConstructor domainMeta shapeMeta, GNominalBinding domain shape) => GNominalBinding (M1 C domainMeta domain) (M1 C shapeMeta shape) where
  gNominalToShape (M1 value) = M1 (gNominalToShape value)
  gNominalFromShape (M1 value) = M1 (gNominalFromShape value)

instance {-# OVERLAPPING #-} (SameSelector domainMeta shapeMeta, GNominalBinding domain shape) => GNominalBinding (M1 S domainMeta domain) (M1 S shapeMeta shape) where
  gNominalToShape (M1 value) = M1 (gNominalToShape value)
  gNominalFromShape (M1 value) = M1 (gNominalFromShape value)

instance {-# OVERLAPPING #-} (GNominalBinding domainLeft shapeLeft, GNominalBinding domainRight shapeRight) => GNominalBinding (domainLeft :*: domainRight) (shapeLeft :*: shapeRight) where
  gNominalToShape (left :*: right) = gNominalToShape left :*: gNominalToShape right
  gNominalFromShape (left :*: right) = gNominalFromShape left :*: gNominalFromShape right

instance {-# OVERLAPPING #-} (GNominalBinding domainLeft shapeLeft, GNominalBinding domainRight shapeRight) => GNominalBinding (domainLeft :+: domainRight) (shapeLeft :+: shapeRight) where
  gNominalToShape (L1 value) = L1 (gNominalToShape value)
  gNominalToShape (R1 value) = R1 (gNominalToShape value)
  gNominalFromShape (L1 value) = L1 (gNominalFromShape value)
  gNominalFromShape (R1 value) = R1 (gNominalFromShape value)

instance {-# OVERLAPPING #-} GNominalBinding (K1 domainIndex value) (K1 shapeIndex value) where
  gNominalToShape (K1 value) = K1 value
  gNominalFromShape (K1 value) = K1 value

instance {-# OVERLAPPING #-} GNominalBinding U1 U1 where
  gNominalToShape U1 = U1
  gNominalFromShape U1 = U1

instance {-# OVERLAPPING #-} GNominalBinding V1 V1 where
  gNominalToShape value = case value of {}
  gNominalFromShape value = case value of {}

instance
  {-# OVERLAPPABLE #-}
  ( TypeError
      ( 'Text "keiro structural binding has no exact nominal correspondence between "
          ':<>: 'ShowType domain
          ':<>: 'Text " and "
          ':<>: 'ShowType shape
          ':$$: 'Text "Run keiro-dsl scaffold and fill the binding by hand at this error location in the scaffolded module."
      )
  ) =>
  GNominalBinding domain shape
  where
  gNominalToShape _ = error "unreachable: TypeError prevents generic structural binding construction"
  gNominalFromShape _ = error "unreachable: TypeError prevents generic structural binding construction"

type family SameConstructor (domainMeta :: Meta) (shapeMeta :: Meta) :: Constraint where
  SameConstructor ('MetaCons name domainFixity domainRecord) ('MetaCons name shapeFixity shapeRecord) = ()
  SameConstructor ('MetaCons domainName domainFixity domainRecord) ('MetaCons shapeName shapeFixity shapeRecord) =
    TypeError
      ( 'Text "keiro structural binding constructor mismatch: "
          ':<>: 'ShowType domainName
          ':<>: 'Text " versus "
          ':<>: 'ShowType shapeName
          ':$$: 'Text "Run keiro-dsl scaffold and fill the binding by hand at this error location in the scaffolded module."
      )

type family SameSelector (domainMeta :: Meta) (shapeMeta :: Meta) :: Constraint where
  SameSelector ('MetaSel name domainUnpack domainStrict domainDecided) ('MetaSel name shapeUnpack shapeStrict shapeDecided) = ()
  SameSelector ('MetaSel domainName domainUnpack domainStrict domainDecided) ('MetaSel shapeName shapeUnpack shapeStrict shapeDecided) =
    TypeError
      ( 'Text "keiro structural binding selector mismatch: "
          ':<>: 'ShowType domainName
          ':<>: 'Text " versus "
          ':<>: 'ShowType shapeName
          ':$$: 'Text "Run keiro-dsl scaffold and fill the binding by hand at this error location in the scaffolded module."
      )

-- | Derive a total binding when both generic representations correspond exactly.
genericStructuralBinding ::
  ( Generic domain,
    Generic shape,
    GNominalBinding (Rep domain) (Rep shape)
  ) =>
  StructuralBinding domain shape
genericStructuralBinding =
  StructuralBinding
    { bindingToShape = to . gNominalToShape . from,
      bindingFromShape = to . gNominalFromShape . from
    }
