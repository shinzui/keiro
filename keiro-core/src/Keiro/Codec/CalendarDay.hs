-- | Frozen JSON policy for proleptic Gregorian calendar days.
--
-- The writer deliberately matches Aeson's 'Day' writer while the reader keeps
-- the historically accepted optional plus sign and non-canonical leading
-- zeroes. Every accepted spelling normalizes through 'renderCalendarDay'.
-- There is no timezone, locale, clock, or instant conversion in this module.
module Keiro.Codec.CalendarDay
  ( calendarDayCodecPolicyIdentity,
    renderCalendarDay,
    encodeCalendarDay,
    parseCalendarDayText,
    parseCanonicalCalendarDayText,
    parseCalendarDay,
  )
where

import Data.Aeson (Value (String), withText)
import Data.Aeson.Types (Parser)
import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar (Day, fromGregorianValid, toGregorian)
import Text.Read (readMaybe)

-- | Stable identity for the complete calendar-day JSON policy.
--
-- This identity is part of generated mapped-wire fingerprints. Changing the
-- accepted domain or emitted bytes requires a successor policy identity and a
-- retained reader for this version.
calendarDayCodecPolicyIdentity :: Text
calendarDayCodecPolicyIdentity = "keiro-core/calendar-day/1"

-- | Render a day as @[-]YYYY-MM-DD@ over the complete 'Day' carrier.
--
-- Years 0000 through 0999 are padded to four digits. Negative years down to
-- -0999 carry the sign plus four digits. Larger absolute years are never
-- truncated, and positive years never carry a plus sign.
renderCalendarDay :: Day -> Text
renderCalendarDay value =
  renderYear year <> "-" <> twoDigits month <> "-" <> twoDigits dayOfMonth
  where
    (year, month, dayOfMonth) = toGregorian value

    renderYear candidate
      | candidate >= 1000 = decimal candidate
      | candidate >= 0 = leftPadFour (decimal candidate)
      | candidate >= -999 = "-" <> leftPadFour (decimal (negate candidate))
      | otherwise = decimal candidate

    decimal = T.pack . show
    leftPadFour digits = T.replicate (4 - T.length digits) "0" <> digits
    twoDigits number =
      let tens = number `div` 10
          ones = number `mod` 10
       in T.pack [asciiDigit tens, asciiDigit ones]
    asciiDigit digit = toEnum (ord '0' + digit)

-- | Encode a day as a JSON string under policy v1.
encodeCalendarDay :: Day -> Value
encodeCalendarDay = String . renderCalendarDay

-- | Parse the v1 historical read language.
--
-- The reader accepts the same signed, at-least-four-digit year language used
-- by Aeson 2.2, but without Aeson's implementation-specific 15-digit cap. A
-- leading plus sign and redundant year zeroes are accepted for retained input
-- and normalize through 'renderCalendarDay'. Month and day are always exactly
-- two digits and invalid Gregorian dates are rejected.
parseCalendarDayText :: Text -> Either Text Day
parseCalendarDayText input = do
  (yearText, monthText, dayText) <- splitDate input
  year <- parseYear yearText
  month <- parseTwoDigits "month" monthText
  dayOfMonth <- parseTwoDigits "day" dayText
  maybe
    (Left ("invalid Gregorian calendar day: " <> input))
    Right
    (fromGregorianValid year month dayOfMonth)

-- | Parse only the canonical writer language.
parseCanonicalCalendarDayText :: Text -> Either Text Day
parseCanonicalCalendarDayText input = do
  value <- parseCalendarDayText input
  if renderCalendarDay value == input
    then Right value
    else Left ("non-canonical calendar day: " <> input)

-- | Parse a JSON string under the historical-compatible v1 read policy.
parseCalendarDay :: Value -> Parser Day
parseCalendarDay =
  withText "CalendarDay" $ \input ->
    either (fail . T.unpack) pure (parseCalendarDayText input)

splitDate :: Text -> Either Text (Text, Text, Text)
splitDate input =
  case T.splitOn "-" input of
    [year, month, dayOfMonth] -> Right (year, month, dayOfMonth)
    ["", year, month, dayOfMonth] -> Right ("-" <> year, month, dayOfMonth)
    _ -> Left ("calendar day must use [-]YYYY-MM-DD: " <> input)

parseYear :: Text -> Either Text Integer
parseYear input = do
  let (sign, digits) =
        case T.uncons input of
          Just ('+', rest) -> (1, rest)
          Just ('-', rest) -> (-1, rest)
          _ -> (1, input)
  if T.length digits < 4 || not (asciiDigits digits)
    then Left ("calendar-day year must contain at least four ASCII digits: " <> input)
    else case readMaybe (T.unpack digits) of
      Just value -> Right (sign * value)
      Nothing -> Left ("calendar-day year is not an integer: " <> input)

parseTwoDigits :: Text -> Text -> Either Text Int
parseTwoDigits label input
  | T.length input /= 2 || not (asciiDigits input) =
      Left ("calendar-day " <> label <> " must contain exactly two ASCII digits: " <> input)
  | otherwise =
      case readMaybe (T.unpack input) of
        Just value -> Right value
        Nothing -> Left ("calendar-day " <> label <> " is not an integer: " <> input)

asciiDigits :: Text -> Bool
asciiDigits value = not (T.null value) && T.all (\character -> character >= '0' && character <= '9') value
