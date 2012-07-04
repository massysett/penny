-- | Copper - the Penny parser
module Penny.Copper (
  -- * Parsing
  Ledger(Ledger),
  ledger,
  
  -- * Rendering
  render,
  renderItems,

  -- * Items
  I.Item(Transaction, Price, CommentItem, BlankLine),

  -- * Comments
  C.Comment(Comment),

  -- * Radix and grouping
  Q.RadGroup,
  Q.periodComma, Q.periodSpace, Q.commaPeriod, Q.commaSpace,
  Q.GroupingSpec(..),
  
  -- * Default time zone
  DT.DefaultTimeZone(DefaultTimeZone),
  DT.utcDefault) where

import Control.Applicative ((<$>))
import qualified Data.Text as X
import Text.Parsec ( manyTill, eof )
import Text.Parsec.Text ( Parser )

import qualified Penny.Copper.Meta as M
import qualified Penny.Copper.Comments as C
import qualified Penny.Copper.Qty as Q
import qualified Penny.Copper.DateTime as DT
import qualified Penny.Copper.Item as I

data Ledger =
  Ledger [(Line, I.Item)]
  deriving Show

ledger ::
  Filename
  -> DT.DefaultTimeZone
  -> Q.RadGroup
  -> Parser Ledger
ledger fn dtz rg =
  Ledger
  <$> manyTill (I.itemWithLineNumber fn dtz rg) eof

render ::
  DT.DefaultTimeZone
  -> (Q.GroupingSpec, Q.GroupingSpec)
  -> Q.RadGroup
  -> Ledger
  -> Maybe X.Text
render dtz gs rg (Ledger is) = renderItems dtz gs rg (map snd is)

renderItems ::
  DT.DefaultTimeZone
  -> (Q.GroupingSpec, Q.GroupingSpec)
  -> Q.RadGroup
  -> [I.Item]
  -> Maybe X.Text
renderItems dtz gs rg is =
  X.concat <$> mapM (I.render dtz gs rg) is
