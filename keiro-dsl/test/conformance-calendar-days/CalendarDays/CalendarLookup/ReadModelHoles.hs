-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module CalendarDays.CalendarLookup.ReadModelHoles
  ( calendarLookupQuery
  ) where

import Generated.CalendarDays.CalendarLookup.ReadModelTable (calendarLookupQualifiedTable)
import Generated.CalendarDays.CalendarLookup.QueryContract (CalendarLookupQueryInput, CalendarLookupQueryResult)
import Hasql.Transaction qualified as Tx

-- HOLE: query "public"."calendar_values" via calendarLookupQualifiedTable; never rely on search_path.
-- The generated QueryContract owns query input/result type identity.
-- Declared columns:
calendarLookupQuery :: CalendarLookupQueryInput -> Tx.Transaction CalendarLookupQueryResult
calendarLookupQuery _input = calendarLookupQualifiedTable `seq` error "HOLE: fill calendar_lookup query"