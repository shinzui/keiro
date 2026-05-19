# Hindsight Library Evaluation for Keiro EP-2 Codec Layer

**Date:** 2025-05-05  
**Scope:** Should keiro's codec layer (EP-2) adopt, selectively borrow from, or reject hindsight's type-level event versioning approach?

---

## What Hindsight Is

Hindsight is a type-safe event sourcing library that separates event identity (a type-level `Symbol`, e.g., `"user_created"`) from payload schemas that evolve over time. Key properties:

- **Compile-time versioning**: Event versions and upcasters are expressed as type-level declarations (`MaxVersion`, `Versions :: [Type]`, `Upcast n` instances). The type system enforces that all versions are handled and migrations compose correctly.
- **Automatic migration composition**: Declare consecutive upcasts (V0→V1, V1→V2); the system automatically derives compositions (V0→V2). No manual chain-building required.
- **Self-contained, minimal dependencies**: BSD-3-licensed; core depends only on base, aeson, containers, text, time, uuid (all lightweight, no transitive complexity). GHC ≥4.20.1 (GHC 9.10+). Test toolkit uses QuickCheck and tasty-golden for deterministic roundtrip and snapshot testing.

---

## Concrete Code Sketches

### 1. Declare Event V1 (from `Test.Hindsight.Examples`, lines 34–54)

```haskell
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}

import Hindsight.Events
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- Event name at type level
type UserCreated = "user_created"

-- Single version: V0
data UserInfo0 = UserInfo0
  { userId :: Int
  , userName :: Text
  } deriving (Show, Eq, Generic, FromJSON, ToJSON)

-- Declare max version = 0, versions list
type instance MaxVersion UserCreated = 0
type instance Versions UserCreated = '[UserInfo0]

-- Instances required
instance Event UserCreated
instance MigrateVersion 0 UserCreated  -- Identity for single version
```

**Total lines for V1 event:** ~20 lines (type + data + 3 instance declarations).

---

### 2. Add V2 with Upcaster (derived from Examples, lines 36–54)

```haskell
-- Add V1 payload with new field
data UserInfo1 = UserInfo1
  { userId :: Int
  , userName :: Text
  , userEmail :: Maybe Text          -- New field
  } deriving (Show, Eq, Generic, FromJSON, ToJSON)

-- Add V2 payload with additional field
data UserInfo2 = UserInfo2
  { userId :: Int
  , userName :: Text
  , userEmail :: Maybe Text
  , likeability :: Int               -- Another new field
  } deriving (Show, Eq, Generic, FromJSON, ToJSON)

-- Update type family declarations
type instance MaxVersion UserCreated = 2
type instance Versions UserCreated = '[UserInfo0, UserInfo1, UserInfo2]

-- Define consecutive upcasts
instance Upcast 0 UserCreated where
  upcast UserInfo0{..} = UserInfo1{userEmail = Nothing, ..}

instance Upcast 1 UserCreated where
  upcast UserInfo1{..} = UserInfo2{likeability = 0, ..}

-- Declare migration instances (use default automatic composition)
instance MigrateVersion 0 UserCreated  -- Auto: V0 → V1 → V2
instance MigrateVersion 1 UserCreated  -- Auto: V1 → V2
instance MigrateVersion 2 UserCreated  -- Auto: V2 → V2 (identity)
```

**Cost of adding V2:** ~30 lines (two new data types + two `Upcast` instances + three `MigrateVersion` declarations).  
**Total event definition:** ~50 lines.

---

### 3. Decode Old V0 Record at Latest Version (from Events.hs, lines 717–732)

```haskell
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Map (Map)
import Hindsight.Events (parseMap, CurrentPayloadType)

-- parseMap generates a version-indexed parser map
userCreatedParsers :: Map Int (Value -> A.Parser (CurrentPayloadType UserCreated))
userCreatedParsers = parseMap @UserCreated

-- Usage: given a version number and JSON value from storage
decodeEventAtLatest :: Int -> Value -> Either String (CurrentPayloadType UserCreated)
decodeEventAtLatest version jsonValue =
  case parseMap @UserCreated Map.!? version of
    Nothing -> Left $ "Unknown version: " <> show version
    Just parser -> case A.fromJSON jsonValue of
      A.Success v -> Right v
      A.Error err -> Left err

-- This automatically:
-- 1. Parses JSON into old PayloadVersion
-- 2. Runs MigrateVersion chain (V0 → V1 → V2)
-- 3. Returns CurrentPayloadType (UserInfo2)
```

**Usage overhead:** 3–5 lines per event at call site; version handling is automatic via `parseMap`.

---

## Strengths: What the Type-Level Approach Buys

### 1. **Exhaustiveness at Compile Time** (Events.hs:494–528)
Missing an `Upcast` instance produces a concrete compile-time error with the exact instance stub needed:
```
Missing Upcast instance for version 2 of event "user_created"
  You need to define:
    instance Upcast 2 "user_created" where
        upcast v2 = ...
```
A value-level `[(Int, Aeson.Value -> Either String Aeson.Value)]` cannot catch this; you discover gaps at runtime.

### 2. **Automatic Composition Without Manual Glue** (Events.hs:561–601)
The `ConsecutiveUpcast` class (implemented via pattern matching on `IsLatest`) automatically chains migrations. No builder pattern, no fold operations. For an event with V0→V1, V1→V2, V2→V3, reading a V0 record invokes the chain automatically without boilerplate composition logic.

### 3. **Constraint Coherence** (Events.hs:614–624, Versioning.hs:199–220)
Every version is provably constrained (`ValidPayloadForVersion`): FromJSON, ToJSON, Eq, Show, Typeable, and MigrateVersion. The `VersionConstraints` GADT walks the version vector inductively. A value-level codec record cannot enforce that all versions have these constraints; you might forget JSON instances for V2.

### 4. **Test Generation for Free** (Test.Hindsight.Generate, lines 393–481)
`createRoundtripTests` and `createGoldenTests` walk the type-level version vector and auto-generate tests for every version. No manual repetition. For a 3-version event, you get 6 tests (3 roundtrip + 3 golden) from two function calls.

### 5. **Version Number Safety** (Events.hs:255–276)
Type families `MaxVersion` and `Versions` are paired with compile-time validation (`AssertVersionCountMatches`). Declaring `MaxVersion = 2` but `Versions = '[V0, V1]` (length mismatch) fails at compile time, not at runtime during deserialization.

---

## Concerns: Costs and Integration Challenges

### 1. **GHC Version Lock** (hindsight-core.cabal, lines 34, 41)
Requires GHC ≥4.20.1 (GHC 9.10+). This is recent and may conflict with older production systems or conservative toolchain policies.  
**Impact on keiro:** Keiro likely targets GHC 9.x; verify compatibility before committing.

### 2. **Type-Level Syntax Tax** (Examples.hs, lines 36–54)
Every event requires explicit `type instance` declarations for `MaxVersion` and `Versions`. For a heterogeneous sum of 20 domain events, that's 20+ instance declarations. The value-level alternative (`Codec e`) needs ~6 lines per event (encode/decode/typeTag/version/upcasters); hindsight's boilerplate is heavier per event but shifts bugs to compile time.

### 3. **Coexistence with Kiroku's Runtime Type Registry** (Your constraint #1)
Hindsight's event identity is type-level (`Symbol`). Kiroku keys events by `eventType :: Text` (runtime JSONB-indexed column). These don't conflict—you still store runtime Text tags—but you must manually map between type-level Symbol and runtime Text. Example:
```haskell
-- Hindsight: type-level
instance Event "user_created" where ...

-- Kiroku needs:
encodeEventForKiroku :: SomeLatestEvent -> (Text, Aeson.Value)
encodeEventForKiroku (SomeLatestEvent (Proxy @event) payload) =
  (getEventName @event, toJSON payload)  -- getEventName extracts "user_created" as Text
```
No fundamental incompatibility, but requires glue code (~10 lines per integration point).

### 4. **SymTransducer `co` Compatibility** (Your constraint #2)
Keiki's `SymTransducer phi rs s ci co` uses `co` as a sum type of domain event constructors. Hindsight wraps events in `SomeLatestEvent`, which is *another* sum (existential). Double-wrapping is semantically fine but inelegant:
```haskell
-- Keiki domain output:
data MyEvents = UserCreated UserInfo | OrderPlaced OrderInfo

-- Hindsight wraps into SomeLatestEvent
-- Codec must translate between them
domainToHindsight :: MyEvents -> SomeLatestEvent
domainToHindsight (UserCreated info) = SomeLatestEvent (Proxy @"user_created") info
domainToHindsight (OrderPlaced info) = SomeLatestEvent (Proxy @"order_placed") info
```
The approach is sound but adds a conversion layer (~20–30 lines for a medium event set).

### 5. **Snapshot Serialization for RegFile** (Your constraint #4)
Snapshotting a heterogeneous `RegFile rs` is not addressed by hindsight; the library focuses on event codec. Snapshot codec remains independent. You'll need custom machinery for `RegFile rs -> Aeson.Value` and vice versa, which hindsight doesn't help with.

### 6. **Learning Curve** (Type-level programming)
Peano numbers, type families, and GADT manipulation are non-standard in business Haskell. The library's documentation is strong, but team onboarding may require education on advanced type-level concepts. The value-level alternative requires zero advanced type theory.

---

## Verdict: **SELECTIVELY BORROW**

### Recommendation

**Do not adopt hindsight wholesale.** Keiro is Postgres-only (not a general event store), already has a working event type registry in kiroku, and must integrate with keiki's SymTransducer model. The full library carries unnecessary coupling and GHC version constraints.

Instead, **extract and adapt hindsight's core patterns** into a value-level codec layer that coexists with kiroku's runtime Text keying.

### Justification

1. **Exhaustiveness guarantees are real:** Hindsight's type-level machinery *does* catch versioning bugs at compile time. A pure value-level approach is error-prone for multi-version evolution.
2. **Full adoption is overkill:** You don't need hindsight's event store (kiroku-store is your store), subscription system, or cross-stream transactions. Those features add boilerplate.
3. **Type-level machinery is optional:** Hindsight's core insight—separate event identity from payload versions—works at the value level too, with slightly less safety but much simpler syntax.
4. **Postgres-only context:** Since keiro is Postgres-only, you can use hindsight-specific patterns (type-level Symbols) without lock-in. But kiroku already owns the event type registry, so hindsight's Symbol-to-Text translation is redundant.

---

## Selective Borrowing: Concrete Mapping

Adopt these patterns from hindsight, express them as value-level types that coexist with kiroku:

### 1. **Version Vector as a Value-Level Record**

Instead of type families, use:

```haskell
{-# LANGUAGE DuplicateRecordFields #-}

data Codec e = Codec
  { codecName        :: Text                        -- Event type name
  , codecMaxVersion  :: Int                         -- Latest version number
  , codecEncode      :: e -> (Int, Aeson.Value)     -- Encode payload + version tag
  , codecDecode      :: Int -> Aeson.Value -> Either String e  -- Decode any version
  , codecVersions    :: Map Int (Aeson.Value -> Either String e)  -- Per-version parsers with migration
  }
```

vs. hindsight's type-level `MaxVersion`, `Versions`, `parseMap` (Events.hs:717–732).

**Benefit:** Drop-in to kiroku; no Symbol-to-Text glue.  
**Trade-off:** No compile-time exhaustiveness, but gain clarity for a small closed set of events.

### 2. **Upcaster Chain as a Value-Level List**

Hindsight uses `Upcast n` instances + automatic composition. Use instead:

```haskell
-- Record event schemas explicitly
data VersionSchema e
  = V0 (Aeson.Value -> Either String e)
  | V1 (Aeson.Value -> Either String e)
  | V2 (Aeson.Value -> Either String e)

-- List of upcasters
type Upcaster = (Int, Aeson.Value -> Either String Aeson.Value)

-- Example: for UserCreated V0 -> V1 -> V2
userCreatedUpcasters :: [Upcaster]
userCreatedUpcasters =
  [ (0, upcastV0ToV1)  -- V0 -> V1
  , (1, upcastV1ToV2)  -- V1 -> V2
  ]

upcastV0ToV1 :: Aeson.Value -> Either String Aeson.Value
upcastV0ToV1 old = do
  v0 :: UserInfo0 <- Aeson.fromJSON old
  pure $ toJSON (UserInfo1 (userId v0) (userName v0) Nothing)
```

vs. hindsight's `instance Upcast 0 event` + `ConsecutiveUpcast` (Events.hs:575–601).

**Benefit:** Explicit, testable, no type machinery.  
**Trade-off:** You must manually compose chains; if you forget V1→V2, deserialization breaks, not compilation.

### 3. **Test Generation as a Helper Function**

Instead of using hindsight's `createRoundtripTests` and `createGoldenTests` (Test.Hindsight.Generate), write a thin wrapper:

```haskell
-- Codec-aware test generator
generateCodecTests :: (Show e, Eq e, FromJSON e, ToJSON e, Arbitrary e)
                   => Codec e
                   -> TestTree
generateCodecTests codec =
  testGroup (T.unpack codec.codecName)
    [ testProperty "roundtrip" $ \payload ->
        let (ver, encoded) = codec.codecEncode payload
        in case codec.codecDecode ver encoded of
             Right decoded -> decoded === payload
             Left err -> property False
    ]
```

vs. hindsight's constraint-walking `createRoundtripTests` (lines 393–406).

**Benefit:** Works with value-level codecs; no type-level walkers needed.  
**Trade-off:** You manually list test cases per event rather than auto-deriving from `Versions` list.

### 4. **Migration as a Composition Function**

Instead of hindsight's `ConsecutiveUpcast` (Events.hs:575–601), use a simple fold:

```haskell
-- Apply upcasters sequentially
migrateToLatest :: Codec e -> Int -> Aeson.Value -> Either String e
migrateToLatest codec startVer payload = do
  -- Apply all upcasters from startVer to codecMaxVersion
  let upcasters = [(v, f) | (v, f) <- codec.codecUpcasters, v >= startVer, v < codec.codecMaxVersion]
  migrated <- foldl (\acc (_, upcast) -> acc >>= upcast) (Right payload) upcasters
  -- Decode final version
  case codec.codecVersions Map.!? codec.codecMaxVersion of
    Nothing -> Left "No parser for latest version"
    Just parser -> parser migrated
```

vs. hindsight's recursive pattern match on `ConsecutiveUpcast` (lines 575–601).

**Benefit:** Straightforward, debuggable, no type-level dispatch.  
**Trade-off:** Manual composition is error-prone; relies on runtime ordering of upcasters.

### 5. **Event Type Tag Handling**

Hindsight uses `getEventName` (Events.hs:240–245) to extract Symbol as string. Keiro already has this in kiroku. Reuse kiroku's registry directly:

```haskell
-- Kiroku already provides:
eventTypeFromRecord :: EventData -> Text

-- Your Codec stores:
Codec { codecName :: Text, ... }

-- No mapping layer needed; use codecName as the kiroku key.
```

vs. hindsight's type-level `Symbol` → runtime `Text` bridge (Events.hs:240–245).

---

## Which Pieces to Borrow

**Adopt:**
- **Upcaster pattern:** Consecutive V0→V1, V1→V2 transitions (simpler than bi-directional migrations)
- **Version vector concept:** Explicit list of payload types per version
- **Test structure:** Roundtrip tests per version + golden snapshots (use tasty-golden independently)
- **Error messages for migration:** Hindsight's `TypeError` messages for missing instances translate to runtime checks in value-level code

**Do NOT adopt:**
- Type families (`MaxVersion`, `Versions`)
- Peano numbers and type-level arithmetic
- `SomeLatestEvent` wrapper (use keiki's domain sum directly)
- Hindsight's EventStore interface (kiroku-store is your store)

---

## File References

**Hindsight sources cited:**
- `hindsight-core/src/Hindsight/Events.hs` (lines 240–245: `getEventName`; 261–278: `MaxVersion`/`Versions`; 489–528: `Upcast` + error messages; 550–601: `MigrateVersion` + `ConsecutiveUpcast`)
- `hindsight-core/src/Hindsight/Events/Internal/Versioning.hs` (lines 96–101: `EventVersions` GADT; 180–220: `HasEvidenceList` constraint machinery)
- `hindsight-core/event-test-lib/Test/Hindsight/Generate.hs` (lines 393–481: `createRoundtripTests`, `createGoldenTests`)
- `hindsight-core/hindsight-core.cabal` (lines 34–40: GHC constraint, dependencies)
- `hindsight-core/event-examples-lib/Test/Hindsight/Examples.hs` (lines 34–54: full 3-version event example)

**Key insight:** Hindsight's type-level design *is* sound for catching schema evolution bugs. But the machinery is denser than necessary for keiro's narrower scope (single Postgres backend, pre-existing event registry in kiroku, smaller event domain). Extract the concepts (versioning patterns, upcaster chains, test discipline) and express them as simple records and functions.

---

## Next Steps (for EP-2 M0.2)

1. **Draft value-level `Codec e` record** based on Section "Selective Borrowing" above
2. **Sketch integration with kiroku-store:** How does `Codec e` read/write through kiroku's existing Text type tagging?
3. **Implement one multi-version event spike** (e.g., UserCreated V0→V1→V2) using the value-level approach to validate the design
4. **Measure boilerplate:** Count lines per event, compare to pure value-level baseline
5. **Decide:** If boilerplate is acceptable and test generation is sufficient, proceed with value-level approach. If not, revisit type-level for future iteration.

