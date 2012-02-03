module Main where

import Control.Monad
import Data.Text ( pack )
import qualified Data.Text.IO as TIO
import Data.Time
import System.Environment
import Text.Parsec
import Text.Show.Pretty

import Penny.Copper

main :: IO ()
main = do
  dtz <- liftM DefaultTimeZone getCurrentTimeZone
  (a:[]) <- getArgs
  f <- TIO.readFile a
  let (rad, sep) = radixAndSeparator '.' ','
      fn = Filename (pack a)
      e = parse (ledger fn dtz rad sep) a f
  putStrLn $ ppShow e

