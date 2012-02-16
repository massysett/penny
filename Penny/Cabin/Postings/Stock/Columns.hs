module Penny.Cabin.Postings.Stock.Columns where

import Data.Ix (Ix)

data C =
  LineNum
  | SLineNum
  | Date
  | SDate
  | Multi  -- Row 0: Flag; Row 1: Tags; Row 2: Memo; Row 3: Filename
  | SMulti
  | Num
  | SNum
  | Payee
  | SPayee
  | Account
  | SAccount
  | PostingDrCr
  | SPostingDrCr
  | PostingCommodity
  | SPostingCommodity
  | PostingQty
  | SPostingQty
  | TotalDrCr
  | STotalDrCr
  | TotalCommodity
  | STotalCommodity
  | TotalQty
  | STotalQty
    deriving (Eq, Ord, Show, Ix)
