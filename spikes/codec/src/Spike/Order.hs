{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | The spike's sample domain. An @Order@ aggregate with two
-- events: 'OrderPlaced' (with a deliberate v1 → v2 schema
-- evolution) and 'OrderCancelled' (single-version, demonstrates
-- that codec composes over multiple constructors).
--
-- v1 vs v2 of OrderPlaced (the schema-migration drama):
--
--   * v1 wire shape: @{"orderId":"ord-1","orderTotal":10}@
--     where @orderTotal@ is an integer dollar amount.
--   * v2 wire shape: @{"orderId":"ord-1","orderTotalCents":1000,"orderCurrency":"USD"}@
--     where the dollar amount is multiplied into cents and a
--     currency tag is added (defaulting to USD on upcast).
--
-- The latest typed shape is 'OrderEvent', which always speaks
-- cents and currency. Decoding a v1-shaped JSON record produces an
-- 'OrderEvent' indistinguishable from a freshly-issued v2 with the
-- same business meaning.
module Spike.Order
  ( -- * Domain types (current schema)
    OrderEvent (..)
  , OrderPlacedData (..)
  , OrderCancelledData (..)
    -- * Codec for the current schema
  , orderCodec
    -- * Schema-evolution helpers (exposed for tests / examples)
  , upcastV1ToV2
  , v1OrderPlaced
  ) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson (FromJSON, ToJSON, Value (..), (.:), (.:?))
import Data.Aeson.Types qualified as Aeson
import Data.Text (Text)
import GHC.Generics (Generic)

import Spike.Codec (Codec (..))


-- * Domain (current schema, V2) -----------------------------------------

data OrderPlacedData = OrderPlacedData
  { orderId         :: Text
  , orderTotalCents :: Int
  , orderCurrency   :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


data OrderCancelledData = OrderCancelledData
  { orderId      :: Text
  , cancelReason :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


-- | The aggregate's event sum at its current (latest) schema.
-- Codecs serialize each constructor as a top-level @{ tag,
-- contents }@ envelope; the codec's typeTag function uses 'tag'
-- without the contents.
data OrderEvent
  = OrderPlaced    OrderPlacedData
  | OrderCancelled OrderCancelledData
  deriving stock (Eq, Show, Generic)


-- | Hand-rolled JSON codec keyed by an explicit @tag@ field. We
-- avoid Aeson's default @Generic@ encoding because the latter
-- carries an opaque @sum-of-products@ shape that's awkward to
-- evolve; the explicit envelope makes upcasters and round-trip
-- tests legible.
instance ToJSON OrderEvent where
  toJSON = \case
    OrderPlaced    d -> Object $ KM.fromList
      [ ("tag",      String "OrderPlaced")
      , ("contents", Aeson.toJSON d)
      ]
    OrderCancelled d -> Object $ KM.fromList
      [ ("tag",      String "OrderCancelled")
      , ("contents", Aeson.toJSON d)
      ]


instance FromJSON OrderEvent where
  parseJSON = Aeson.withObject "OrderEvent" $ \obj -> do
    tag <- obj .: "tag"
    case tag :: Text of
      "OrderPlaced"    -> OrderPlaced    <$> obj .: "contents"
      "OrderCancelled" -> OrderCancelled <$> obj .: "contents"
      other            -> fail ("Unknown OrderEvent tag: " <> show other)


-- * Codec ---------------------------------------------------------------

-- | The current-schema codec for 'OrderEvent'. v2-shaped JSON
-- decodes directly; v1-shaped JSON is migrated through
-- 'upcastV1ToV2' first. Ordering of upcasters: ascending source
-- version, contiguous, no gaps.
orderCodec :: Codec OrderEvent
orderCodec = Codec
  { codecEncode    = Aeson.toJSON
  , codecDecode    = decodeCurrent
  , codecTypeTag   = orderEventTag
  , codecVersion   = 2
  , codecUpcasters = [ (1, upcastV1ToV2) ]
  }
  where
    decodeCurrent :: Value -> Either String OrderEvent
    decodeCurrent v = case Aeson.fromJSON v of
      Aeson.Success x -> Right x
      Aeson.Error   e -> Left e


-- | Stable per-constructor wire tag. Independent of schema
-- version — projections subscribed by @event_type@ keep working
-- across the v1→v2 upcast.
orderEventTag :: OrderEvent -> Text
orderEventTag = \case
  OrderPlaced    {} -> "OrderPlaced"
  OrderCancelled {} -> "OrderCancelled"


-- * Schema evolution: v1 → v2 -------------------------------------------

-- | Upcast a v1-shaped @OrderPlaced@ envelope into the v2 shape.
-- Other constructors (e.g. @OrderCancelled@) are passed through —
-- they never had a v1.
--
-- v1 envelope: @{"tag":"OrderPlaced","contents":{"orderId":"…","orderTotal":<dollars>}}@
-- v2 envelope: @{"tag":"OrderPlaced","contents":{"orderId":"…","orderTotalCents":<cents>,"orderCurrency":"USD"}}@
upcastV1ToV2 :: Value -> Either String Value
upcastV1ToV2 v = case Aeson.parseEither parser v of
  Right v' -> Right v'
  Left  e  -> Left ("upcastV1ToV2: " <> e)
  where
    parser :: Value -> Aeson.Parser Value
    parser = Aeson.withObject "OrderEvent envelope" $ \obj -> do
      tag <- obj .: "tag" :: Aeson.Parser Text
      case tag of
        "OrderPlaced" -> do
          contents <- obj .: "contents"
          contents' <- Aeson.withObject "v1 OrderPlaced contents" upcastContents contents
          pure $ Object $ KM.fromList
            [ ("tag",      String "OrderPlaced")
            , ("contents", contents')
            ]
        _ -> pure v   -- pass through; not an OrderPlaced

    upcastContents :: Aeson.Object -> Aeson.Parser Value
    upcastContents obj = do
      orderId      <- obj .: "orderId" :: Aeson.Parser Text
      orderTotal   <- obj .: "orderTotal" :: Aeson.Parser Int
      mCurrency    <- obj .:? "orderCurrency" :: Aeson.Parser (Maybe Text)
      let currency = case mCurrency of
            Just t  -> t
            Nothing -> "USD"
      pure $ Object $ KM.fromList
        [ (K.fromText "orderId",         String orderId)
        , (K.fromText "orderTotalCents", Number (fromIntegral (orderTotal * 100)))
        , (K.fromText "orderCurrency",   String currency)
        ]


-- | Construct a v1-shaped JSON envelope for the spike's driver.
-- Used to mimic an event recorded by an earlier deploy that still
-- speaks dollars.
v1OrderPlaced :: Text -> Int -> Value
v1OrderPlaced oid dollars = Object $ KM.fromList
  [ ("tag", String "OrderPlaced")
  , ("contents", Object $ KM.fromList
      [ ("orderId",    String oid)
      , ("orderTotal", Number (fromIntegral dollars))
      ])
  ]
