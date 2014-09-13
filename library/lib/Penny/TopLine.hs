module Penny.TopLine where

import qualified Penny.DateTime as DateTime
import qualified Penny.Memo as Memo
import qualified Penny.Number as Number
import qualified Penny.Flag as Flag
import qualified Penny.Payee as Payee
import qualified Penny.Location as Location
import qualified Penny.Clxn as Clxn
import qualified Penny.Serial as Serial

data T = T
  { dateTime :: DateTime.T
  , memo :: Memo.T
  , number :: Maybe Number.T
  , flag :: Maybe Flag.T
  , payee :: Maybe Payee.T
  , location :: Location.T
  , clxn :: Clxn.T
  , globalSerial :: Serial.T
  , clxnSerial :: Serial.T
  } deriving (Eq, Ord, Show)