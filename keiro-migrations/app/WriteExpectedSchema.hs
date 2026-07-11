module Main (
    main,
)
where

import Codd.Extras.WriteSchema (writeExpectedSchemaMain)
import Data.Time (secondsToDiffTime)
import Keiro.Migrations.LegacyCodd (runAllKeiroMigrationsNoCheck)

main :: IO ()
main =
    writeExpectedSchemaMain "keiro" ["keiro"] "keiro-migrations/expected-schema" $ \settings ->
        runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)
