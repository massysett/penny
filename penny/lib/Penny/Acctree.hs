{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE FlexibleContexts #-}
module Penny.Acctree where

import Control.Lens (view, (<|))
import Control.Monad (join)
import Data.Foldable (toList)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Text (Text, pack)
import qualified Data.Text as X
import Rainbow
import Rainbox

import Penny.Balance
import Penny.BalanceMap
import Penny.Cell
import Penny.Clatch.Types
import Penny.Clatch.Access.Posting
import Penny.Clatch.Access.Converted
import Penny.Clatcher (Report)
import Penny.Colors
import Penny.Commodity
import Penny.Copper.Copperize
import Penny.Decimal
import qualified Penny.Polar as Polar
import Penny.Popularity
import Penny.Rep

acctreeReport
  :: Colors
  -> History
  -> Seq (Clatch l)
  -> Seq (Chunk Text)
acctreeReport clrs hist
  = render
  . tableByRows
  . formatTable hist clrs
  . foldr (<>) mempty
  . fmap mkBalanceMap
  where
    mkBalanceMap clatch = balanceMap (view account clatch)
      (c'Balance'Amount . best $ clatch)

-- | The 'acctree' report shows a tree of all accounts and their
-- balances.
acctree :: Report
acctree _ colors hist clatches = acctreeReport colors hist clatches

unrollBalanceMap :: Int -> Text -> BalanceMap -> Seq (Int, Text, Balance)
unrollBalanceMap lvl lbl mp
  = (lvl, lbl, topLevelBalance mp)
  <| join (fmap (uncurry (unrollBalanceMap (lvl + 1)))
                . Seq.fromList . Map.toAscList . lowerBalances $ mp)

qtyRows :: Env -> Map Commodity Decimal -> Seq (Seq (Chunk Text))
qtyRows env = fmap mkRow . Seq.fromList . Map.toAscList
  where
    mkRow (cy, q) = Seq.singleton . fore (foreground env q)
      . back (view rowBackground env)
      . chunk $ txt
      where
        txt = pack
          . toList
          . t'NilOrBrimAnyRadix
          . c'NilOrBrimAnyRadix'RepAnyRadix
          . repDecimal ei $ q
        ei = either (Left . Just) (Right . Just)
            . selectGrouper
            . Penny.Popularity.groupers (view history env)
            . Just $ cy

foreground
  :: Env
  -> Decimal
  -> Radiant
foreground env q = case pole'Decimal q of
  Nothing -> view (colors.neutral) env
  Just p
    | p == Polar.debit -> view (colors.debit) env
    | otherwise -> view (colors.credit) env

sideRows :: Env -> Map Commodity Decimal -> Seq (Seq (Chunk Text))
sideRows env = fmap mkRow . Seq.fromList . Map.toAscList
  where
    mkRow (_, q) = Seq.singleton . fore (foreground env q)
      . back (view rowBackground env) . chunk $ sideTxt
      where
        sideTxt = case pole'Decimal q of
          Nothing -> "--"
          Just s
            | s == Polar.debit -> "<"
            | otherwise -> ">"

commodityRows :: Env -> Map Commodity Decimal -> Seq (Seq (Chunk Text))
commodityRows env = fmap mkRow . Seq.fromList . Map.toAscList
  where
    mkRow (cy, q) = Seq.singleton . fore (foreground env q)
      . back (view rowBackground env) . chunk $ cy

labelRows :: Int -> Text -> Env -> Seq (Seq (Chunk Text))
labelRows lvl lbl env = Seq.singleton . Seq.singleton
  . back (view rowBackground env)
  . fore (view (colors.nonLinear) env)
  . chunk
  . (pad <>)
  $ lbl
  where
    pad = X.replicate lvl "  "

formatTableRow
  :: Int
  -- ^ Indentation level
  -> Text
  -- ^ Label for this level
  -> Env
  -> Balance
  -> Seq Cell
formatTableRow lvl lbl env (Balance mp)
  = [ side, spaceCell 1 env,
      qty, spaceCell 1 env,
      commodity, spaceCell 2 env,
      label ]
  where
    side = Cell (sideRows env mp) top left bkgd
    bkgd = view rowBackground env
    qty = Cell (qtyRows env mp) top right bkgd
    commodity = Cell (commodityRows env mp) top left bkgd
    label = Cell (labelRows lvl lbl env) top left bkgd

formatTable
  :: History
  -> Colors
  -> BalanceMap
  -> Seq (Seq Cell)
formatTable hist clrs balMap = Seq.zipWith mkRow evenOdd unrolled
  where
    evenOdd = Seq.fromList . take (Seq.length unrolled)
      . concat
      $ repeat [view evenBackground clrs, view oddBackground clrs]
    unrolled = unrollBalanceMap 0 "Total" balMap
    mkRow bkgd (lvl, lbl, bal) = formatTableRow lvl lbl
      (Env bkgd hist clrs) bal
