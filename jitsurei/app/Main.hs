module Main
  ( main
  )
where

import Jitsurei

main :: IO ()
main =
  putStrLn ("jitsurei demonstrates " <> show (orderStream (OrderId "order-demo")))
