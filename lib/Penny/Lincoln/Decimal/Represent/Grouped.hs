module Penny.Lincoln.Decimal.Represent.Grouped where

import Penny.Lincoln.Decimal.Components
import Penny.Lincoln.Decimal.Abstract
import Penny.Lincoln.Decimal.Lane
import qualified Penny.Lincoln.Decimal.Represent.Ungrouped as U
import Prelude hiding (exponent)
import Deka.Native.Abstract hiding (Exponent(..))
import Data.List.Split (chunksOf)
import qualified Penny.Lincoln.Decimal.Masuno as M

-- | Represents a number, with digit grouping.  Rules for digit
-- grouping:
--
-- * Digits to the left of the radix are grouped only if there are
-- at least five digits to the left of the radix.
--
-- * Digits to the right of the radix are never grouped.

grouped
  :: (HasExponent a, Laned a b)
  => a
  -> Rep b
grouped a = case lane a of
  Center -> RZero $ U.ungroupedZero (exponent a)
  NonCenter (s, d) -> RFigure $ groupedNonZero (exponent a) s d

-- | Splits a single MSG group into a group of MSG and less
-- significant digits.  First all LSD are split into groups of 3.
-- Then, if the most significant resulting group has 1 or 2 digits,
-- it is placed into the MSG.  Otherwise,  the MSD will be in its
-- own group.  No grouping at all is performed if the MSG has less
-- than five digits.

groupMSG :: M.MSG -> (M.MSG, [M.LSG])
groupMSG (M.MSG nv decems)
  | length decems < 4 = (M.MSG nv decems, [])
  | otherwise = case groupsOf3 decems of
      [] -> error "groupMSG: error 1"
      dg1:xs -> (M.MSG nv msgRest, lsgs)
        where
          (msgRest, lsgs) = case dg1 of
            x:[] -> ([x], map mkLSG xs)
            x:y:[] -> ([x,y], map mkLSG xs)
            _ -> ([], map mkLSG (dg1:xs))
          mkLSG digs = case digs of
            [] -> error "groupMSG: error 2"
            a:as -> M.LSG a as

groupedNonZero
  :: Exponent
  -> a
  -> Decuple
  -> Figure a
groupedNonZero expn sd dc = Figure sd $
  case figNonZero $ U.ungroupedNonZero expn sd dc of

    NZMasuno (M.Masuno ei) -> case ei of
      Left (M.Monly msg _) ->
        NZMasuno (M.Masuno (Left (M.Monly msg' lsgs)))
        where
          (msg', lsgs) = groupMSG msg

      Right (M.Fracuno msg _ fgs) ->
        NZMasuno (M.Masuno (Right (M.Fracuno msg' lsgs fgs)))
        where
          (msg', lsgs) = groupMSG msg

    o -> o

-- | Splits a list into groups of 3.  If it doesn't divide evenly,
-- parts at the front will be shorter.

groupsOf3 :: [a] -> [[a]]
groupsOf3 = map reverse . reverse . chunksOf 3 . reverse