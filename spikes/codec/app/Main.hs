{-# LANGUAGE OverloadedStrings #-}

-- | Driver for the codec spike. Boots an ephemeral Postgres,
-- opens kiroku, appends a deliberately v1-shaped JSON record
-- (mimicking an event written by a previous deploy), appends a
-- v2 event via the live codec, reads both back, and asserts they
-- decode through the upcaster chain into the latest typed shape.
-- Then runs a QuickCheck stress test that round-trips 10 000
-- randomly-generated 'OrderEvent's through the codec.
--
-- The transcript ends in @[codec-spike] OK@ when every assertion
-- holds.
module Main (main) where

import Control.Exception (Exception, throwIO)
import Control.Monad (forM, replicateM, when)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson (Value (..))
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Text (Text)
import qualified Data.Vector as V
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static
  ( Error
  , runErrorNoCallStack
  )

import qualified EphemeralPg as Pg

import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Connection
  ( KirokuStore
  , defaultConnectionSettings
  , withStore
  )
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types
  ( EventData (..)
  , EventType (..)
  , ExpectedVersion (..)
  , RecordedEvent (..)
  , StreamName (..)
  , StreamVersion (..)
  )

import Test.QuickCheck
  ( Arbitrary (..)
  , Gen
  , elements
  , generate
  , listOf
  , vectorOf
  , choose
  , oneof
  )

import Spike.Codec
  ( DecodeError
  , decodeRecorded
  , encodeForAppend
  , metadataFor
  )
import Spike.Order
  ( OrderCancelledData (..)
  , OrderEvent (..)
  , OrderPlacedData (..)
  , orderCodec
  , v1OrderPlaced
  )


-- * Failures & helpers --------------------------------------------------

newtype SpikeFailure = SpikeFailure Text
  deriving stock (Show)
  deriving anyclass (Exception)


failIO :: Text -> IO a
failIO msg = throwIO (SpikeFailure msg)


orderStream :: StreamName
orderStream = StreamName "order-1"


-- | Stream-only effect helper: unwrap to 'IO (Either StoreError a)'.
runStore
  :: KirokuStore
  -> Eff '[ Store, Error StoreError, IOE ] a
  -> IO (Either StoreError a)
runStore store action =
      runEff
    . runErrorNoCallStack @StoreError
    . runStorePool store
    $ action


-- | Helper: run a store action that should succeed; failIO otherwise.
mustStore :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO a
mustStore store action = do
  r <- runStore store action
  case r of
    Right v  -> pure v
    Left err -> failIO ("store: " <> T.pack (show err))


-- * Driver -------------------------------------------------------------

main :: IO ()
main = do
  result <- Pg.with $ \db -> do
    let connStr  = Pg.connectionString db
        settings = defaultConnectionSettings connStr
    T.putStrLn $ "[codec-spike] starting ephemeral-pg, connection: " <> connStr
    withStore settings $ \store -> do
      T.putStrLn "[codec-spike] applied kiroku schema"
      scenarioRoundTrip store
      scenarioStressTest store
  case result of
    Left err -> do
      hPutStrLn stderr $ "[codec-spike] ephemeral-pg startup failed: " <> show err
      exitFailure
    Right () -> T.putStrLn "[codec-spike] OK"


-- * Scenario 1 — v1/v2 mixed-stream round-trip ------------------------

scenarioRoundTrip :: KirokuStore -> IO ()
scenarioRoundTrip store = do
  T.putStrLn "[codec-spike] --- scenario 1: v1/v2 round-trip ---"

  -- Step 1: append a v1-shaped event manually. This mimics a
  -- record written by a previous deploy whose schema put the
  -- price in dollars.
  let v1Payload = v1OrderPlaced "ord-1" 10
      v1Event = EventData
        { eventId       = Nothing
        , eventType     = EventType "OrderPlaced"
        , payload       = v1Payload
        , metadata      = Just (metadataFor 1)
        , causationId   = Nothing
        , correlationId = Nothing
        }
  _ <- mustStore store $
    appendToStream orderStream NoStream [v1Event]
  T.putStrLn "[codec-spike] wrote v1-shaped event"

  -- Step 2: append a v2 event through the live codec.
  let v2Native = OrderPlaced (OrderPlacedData
        { orderId         = "ord-2"
        , orderTotalCents = 4250
        , orderCurrency   = "EUR"
        })
      v2EventData = encodeForAppend orderCodec v2Native
  _ <- mustStore store $
    appendToStream orderStream (ExactVersion (StreamVersion 1)) [v2EventData]
  T.putStrLn "[codec-spike] wrote v2-shaped event"

  -- Step 3: also append an OrderCancelled (single-version) to
  -- prove the codec composes across constructors.
  let cancelEvent = OrderCancelled (OrderCancelledData
        { orderId      = "ord-1"
        , cancelReason = "customer changed mind"
        })
  _ <- mustStore store $
    appendToStream orderStream (ExactVersion (StreamVersion 2))
      [encodeForAppend orderCodec cancelEvent]
  T.putStrLn "[codec-spike] wrote v2 OrderCancelled"

  -- Step 4: read every event back and decode through the codec.
  recordedV <- mustStore store $
    readStreamForward orderStream (StreamVersion 0) 1024
  let recorded = V.toList recordedV
  decoded <- forM recorded $ \rec ->
    case decodeRecorded orderCodec rec of
      Right ev  -> pure ev
      Left err  -> failIO ("decode failed: " <> T.pack (show err))

  -- Step 5: assert the decoded results match expectations.
  let expected =
        [ OrderPlaced (OrderPlacedData
            { orderId = "ord-1"
            , orderTotalCents = 1000     -- 10 dollars upcast to cents
            , orderCurrency   = "USD"    -- default currency on upcast
            })
        , OrderPlaced (OrderPlacedData
            { orderId = "ord-2"
            , orderTotalCents = 4250
            , orderCurrency   = "EUR"
            })
        , OrderCancelled (OrderCancelledData
            { orderId      = "ord-1"
            , cancelReason = "customer changed mind"
            })
        ]
  when (decoded /= expected) $ do
    failIO $ "scenario 1 mismatch.\n  expected=" <> T.pack (show expected)
          <> "\n  got=" <> T.pack (show decoded)

  T.putStrLn $ "[codec-spike] decoded v1 → "
    <> T.pack (show (head decoded))
  T.putStrLn $ "[codec-spike] decoded v2 → "
    <> T.pack (show (decoded !! 1))


-- * Scenario 2 — QuickCheck stress test --------------------------------

scenarioStressTest :: KirokuStore -> IO ()
scenarioStressTest store = do
  T.putStrLn "[codec-spike] --- scenario 2: stress test (10 000 events) ---"
  let n = 10000 :: Int
  events <- generate (vectorOf n arbitrary) :: IO [OrderEvent]

  -- Use a fresh stream for the stress test so it doesn't tangle
  -- with scenario 1's contents.
  let stressStream = StreamName "stress-1"

  -- Append in batches of 500 to keep the SQL round-trips small
  -- without single-event overhead. Each batch's expected version
  -- is the *prior* batch's terminal version.
  let chunks = chunksOf 500 events
  appendBatches store stressStream chunks

  -- Read all back and decode.
  recordedV <- mustStore store $
    readStreamForward stressStream (StreamVersion 0) (fromIntegral (n + 1))
  let recorded = V.toList recordedV
  when (length recorded /= n) $ do
    failIO $ "stress test event-count mismatch: appended=" <> T.pack (show n)
          <> " recorded=" <> T.pack (show (length recorded))

  decoded <- forM recorded $ \rec ->
    case decodeRecorded orderCodec rec of
      Right ev  -> pure ev
      Left err  -> failIO ("stress decode failed: " <> T.pack (show err))

  when (decoded /= events) $ do
    let mismatchIx = firstMismatch 0 events decoded
    failIO $ "stress test mismatch at index "
          <> T.pack (show mismatchIx)
          <> "\n  expected=" <> T.pack (show (events !! mismatchIx))
          <> "\n  got=" <> T.pack (show (decoded !! mismatchIx))

  T.putStrLn $ "[codec-spike] stress test: " <> T.pack (show n)
            <> " events round-tripped"


appendBatches
  :: KirokuStore
  -> StreamName
  -> [[OrderEvent]]
  -> IO ()
appendBatches store sn = go 0
  where
    go _ [] = pure ()
    go priorVer (batch : rest) = do
      let expected = case priorVer of
            0 -> NoStream
            n -> ExactVersion (StreamVersion (fromIntegral n))
          batchData = map (encodeForAppend orderCodec) batch
      _ <- mustStore store $
        appendToStream sn expected batchData
      go (priorVer + length batch) rest


chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (c, rest) = splitAt n xs in c : chunksOf n rest


firstMismatch :: (Eq a) => Int -> [a] -> [a] -> Int
firstMismatch ix (x:xs) (y:ys)
  | x == y    = firstMismatch (ix + 1) xs ys
  | otherwise = ix
firstMismatch ix _ _ = ix


-- * Arbitrary instances for QuickCheck ---------------------------------

instance Arbitrary OrderEvent where
  arbitrary = oneof
    [ OrderPlaced    <$> arbitrary
    , OrderCancelled <$> arbitrary
    ]


instance Arbitrary OrderPlacedData where
  arbitrary = OrderPlacedData
    <$> shortText
    <*> choose (1, 1_000_000_000)
    <*> elements ["USD", "EUR", "JPY", "GBP"]


instance Arbitrary OrderCancelledData where
  arbitrary = OrderCancelledData
    <$> shortText
    <*> shortText


-- | Generate a short ASCII text so we don't blow up the JSON
-- payload size or burn time on Unicode normalisation.
shortText :: Gen Text
shortText = do
  n <- choose (1, 32)
  T.pack <$> vectorOf n (elements (['a'..'z'] ++ ['0'..'9']))
