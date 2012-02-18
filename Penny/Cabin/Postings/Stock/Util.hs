module Penny.Cabin.Postings.Stock.Util where

import qualified Data.Foldable as F
import qualified Data.Sequence as Seq
import qualified Data.Text as X

import qualified Penny.Cabin.Postings.Base.Base as B
import qualified Penny.Cabin.Postings.Base.Combinator as Comb
import qualified Penny.Cabin.Colors as CC
import qualified Penny.Cabin.Postings.Stock.Colors as SC
import qualified Penny.Cabin.Postings.Stock.Columns as Col
import qualified Penny.Cabin.Postings.Base.Row as R

zeroGrowToFit :: a -> b -> c -> d -> (B.ColumnWidth, e -> R.Cell)
zeroGrowToFit _ _ _ _ = (B.ColumnWidth 0, const (R.zeroCell))

isTrancheTopRow :: B.CellInfo c -> Bool
isTrancheTopRow c = (B.unTrancheRow . B.trancheRow $ c) == 0

data NonTopCellType = Justified | Overran

-- | Makes a column width and a cell maker, depending upon whether the
-- cell is in the top row of the tranche. If the cell is in the top
-- row of the tranche, the width will be equal to the widest text
-- passed in the sequence, and the cell maker will return a cell with
-- text contents. If the cell is not in the top row of the tranche,
-- the function returns a width of zero; what funtion is returned
-- depends on whether the NonTopCellType is Padded or Overran. For
-- Justified, the function returns a cell that is justified depending
-- on other cells in the column, but that is otherwise blank. For
-- Overran, the cell has no contents and is not justified.
makeGrowingCell ::
  NonTopCellType
  -> SC.BaseColors
  -> B.PostingInfo
  -> B.CellInfo Col.C
  -> R.Justification
  -> Seq.Seq X.Text
  -> (B.ColumnWidth,
      B.Table Col.C (B.PostingInfo, B.Queried Col.C) -> R.Cell)
makeGrowingCell cellType colors p ci just sq = (cw, f) where
  chunks = fmap (CC.chunk ts) sq
  folder t maxSoFar = bigger where
    bigger = max thisCol maxSoFar
    thisCol = B.ColumnWidth . CC.unWidth . CC.chunkSize $ t
  cw = if isTrancheTopRow ci
       then F.foldr folder (B.ColumnWidth 0) chunks
       else B.ColumnWidth 0
  col = B.cellCol ci
  ts = SC.colors p colors
  ks = if isTrancheTopRow ci
       then chunks
       else Seq.empty
  f = case cellType of
    Justified -> Comb.cell just col ts ks
    Overran -> const R.zeroCell
  
-- | Makes a column width and a cell maker to use for a spacer
-- cell. If the cell is in the top row of the tranche, it will be
-- justified and have a width of 1 only if the supplied boolean is
-- True. Otherwise, it will have a width of zero. If the cell is not
-- in the top row of the tranche, the function returns a width of
-- zero, and what function is returned depends on whether the cell is
-- Padded or Overran. If the cell is Padded, then its final width
-- depends on the width of other cells in the column; if it is
-- Overran, it has no contents and is not justified.

makeSpacerCell ::
  NonTopCellType
  -> SC.BaseColors
  -> B.PostingInfo
  -> B.CellInfo Col.C
  -> Bool
  -> (B.ColumnWidth,
      B.Table Col.C (B.PostingInfo, B.Queried Col.C) -> R.Cell)
makeSpacerCell cellType colors p ci showSpace = (cw, f) where
  cw = B.ColumnWidth $
       if isTrancheTopRow ci && showSpace then 1 else 0
  just = R.LeftJustify
  col = B.cellCol ci
  ts = SC.colors p colors
  ks = if isTrancheTopRow ci && showSpace
       then Seq.singleton (CC.chunk ts (X.singleton ' '))
       else Seq.empty
  f = case cellType of
    Justified -> Comb.cell just col ts ks
    Overran -> const R.zeroCell

  
                                                     

