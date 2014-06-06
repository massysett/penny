module Penny.Lincoln.Decimal.Represent.Ungrouped where

import Penny.Lincoln.Decimal.Components
import Penny.Lincoln.Decimal.Abstract
import Penny.Lincoln.Decimal.Zero
import Penny.Lincoln.Decimal.Groups
import qualified Penny.Lincoln.Decimal.Masuno as M
import qualified Penny.Lincoln.Decimal.Frac as F
import Penny.Lincoln.Natural
import Prelude hiding (exponent)
import qualified Deka.Native.Abstract as D

-- | Represents a number, without any digit grouping.

ungrouped
  :: Exponent
  -> Lane a
  -> Rep a
ungrouped e a = case a of
  Center -> RZero $ ungroupedZero e
  NonCenter (s, d) -> RFigure $ ungroupedNonZero e s d

ungroupedZero :: Exponent -> Zero
ungroupedZero ex
  | e < 0 = error "ungroupedZero: negative exponent"
  | e == 0 = Zero (Left PlainZero)
  | otherwise = Zero (Right (GroupedZero True g []))
  where
    e = unNonNegative . unExponent $ ex
    g = Group . maybe (error "ungroupedZero: non-positive group")
      id . positive $ e

ungroupedNonZero
  :: Exponent
  -> a
  -> D.Decuple
  -> Figure a
ungroupedNonZero ex sd dc
  | e < 0 = error "ungroupedNonZero: negative exponent"
  | e == 0 = Figure sd . NZMasuno . M.Masuno . Left $ wholeOnly
  | e >= decupleLen = Figure sd . NZFrac $ frac
  | otherwise = Figure sd . NZMasuno . M.Masuno . Right $ wholeFrac
  where
    e = unNonNegative . unExponent $ ex
    D.Decuple msd rest = dc
    decupleLen = length rest + 1

    wholeOnly = M.Monly msg []
      where
        msg = MSG msd rest

    frac = F.Frac True [] msg []
      where
        msg = F.ZeroesMSG nZeroes (MSG msd rest)
        nZeroes = maybe (error "ungroupedNonZero: error 1") id
          . nonNegative $ e - decupleLen

    wholeFrac = M.Fracuno msg [] [fg]
      where
        nOnLeft = decupleLen - e
        (leftLessSigDigs, rtDigs) = splitAt (nOnLeft - 1) rest
        msg = MSG msd leftLessSigDigs
        fg = case rtDigs of
          [] -> error "ungroupedNonZero: error 2"
          x:xs -> M.FG x xs

