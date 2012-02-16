module Penny.Cabin.Postings.Row (
  Justification(LeftJustify, RightJustify),
  Cell,
  emptyCell,
  appendLine,
  prependLine,
  widestLine,
  Row,
  emptyRow,
  prependCell,
  appendCell,
  Rows,
  emptyRows,
  prependRow,
  appendRow,
  HasChunk(chunk)) where

import Data.Monoid (Monoid, mempty, mappend)
import qualified Data.Foldable as F
import Data.Sequence (Seq, (<|), (|>), ViewL ((:<)))
import qualified Data.Sequence as S
import qualified Data.Text as X

import Penny.Cabin.Colors
  (Chunk, TextSpec, chunkSize, Width(Width, unWidth))
import qualified Penny.Cabin.Colors as C

-- | How to justify cells. LeftJustify leaves the right side
-- ragged. RightJustify leaves the left side ragged.
data Justification =
  LeftJustify
  | RightJustify
  deriving Show

-- | A cell of text output. You tell the cell how to justify itself
-- and how wide it is. You also tell it the background colors to
-- use. The cell will be appropriately justified (that is, text
-- aligned between left and right margins) and padded (with lines of
-- blank text added on the bottom as needed) when joined with other
-- cells into a Row.
data Cell =
  Cell { justification :: Justification
       , width :: Width
       , padSpec :: TextSpec
       , chunks :: Seq Chunk }

data PaddedCell =
  PaddedCell { justifiedChunks :: Seq Chunk
             , _bottom :: Chunk }

emptyCell :: Justification -> Width -> TextSpec -> Cell
emptyCell j w ts = Cell j w ts S.empty

appendLine :: Chunk -> Cell -> Cell
appendLine ch c = c { chunks = chunks c |> ch }

prependLine :: Chunk -> Cell -> Cell
prependLine ch c = c { chunks = ch <| chunks c }

widestLine :: Cell -> Width
widestLine = F.foldr max (Width 0) . fmap chunkSize . chunks

-- | A Row consists of several Cells. The Cells will be padded and
-- justified appropriately, with the padding adjusting to accomodate
-- other Cells in the Row.
newtype Row = Row (Seq PaddedCell)

emptyRow :: Row
emptyRow = Row S.empty

justify :: TextSpec -> Width -> Justification -> Chunk -> Chunk
justify ts wi@(Width w) j c = glue padding c where
  glue pd ck = case j of
    LeftJustify -> ck `mappend` pd
    RightJustify -> pd `mappend` ck
  padding = C.chunk ts t
  t = X.pack (replicate s ' ')
  s = if wi > chunkSize c
      then w - (unWidth . chunkSize $ c)
      else 0

newtype Height = Height { unHeight :: Int }
                 deriving (Show, Eq, Ord)

bottomPad :: TextSpec -> Width -> Chunk
bottomPad ts (Width w) = C.chunk ts t where
  t = X.pack (replicate w ' ')

morePadding ::
  Height
  -> PaddedCell
  -> PaddedCell
morePadding h (PaddedCell cs c) = PaddedCell cs' c where
  cs' = if unHeight h > S.length cs
        then cs `mappend` pads
        else cs
  pads = S.replicate (unHeight h - S.length cs) c

justifyAll ::
  TextSpec -> Width -> Justification -> Seq Chunk -> Seq Chunk
justifyAll ts w j = fmap (justify ts w j)

addCell ::
  (PaddedCell -> Seq PaddedCell -> Seq PaddedCell)
  -> Cell
  -> Row
  -> Row
addCell glue c (Row cs) = let
  s = padSpec c
  justified = justifyAll s (width c)
              (justification c) (chunks c)
  pc = PaddedCell justified (bottomPad s (width c))
  in case S.viewl cs of
    S.EmptyL -> Row (S.singleton pc)
    existing :< _ -> let
      newHeight = max (height existing) (height pc)
      pcs = glue pc cs
      in Row (fmap (morePadding newHeight) pcs)

prependCell :: Cell -> Row -> Row
prependCell = addCell (<|) 

appendCell :: Cell -> Row -> Row
appendCell = addCell (flip (|>))

height :: PaddedCell -> Height
height (PaddedCell cs _) = Height (S.length cs)

-- | Several rows, joined together.
newtype Rows = Rows (Seq Row)

emptyRows :: Rows
emptyRows = Rows S.empty

prependRow :: Row -> Rows -> Rows
prependRow r (Rows rs) = Rows (r <| rs)

appendRow :: Row -> Rows -> Rows
appendRow r (Rows rs) = Rows (rs |> r)

instance Monoid Rows where
  mempty = Rows S.empty
  mappend (Rows s1) (Rows s2) = Rows $ mappend s1 s2

class HasChunk a where
  chunk :: a -> Chunk

instance HasChunk Row where
  chunk (Row cells) =
    if S.null cells
    then mempty
    else F.foldr mappend mempty zipped where
      zipped = F.foldr1 zipper (fmap justifiedChunks cells)
      zipper s1 s2 = S.zipWith mappend s1 s2

instance HasChunk Rows where
  chunk (Rows rs) = F.foldr mappend mempty (fmap chunk rs)
