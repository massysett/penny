module Penny.Tree.LZ3 where

import qualified Penny.Core.NovDecs as NovDecs
import qualified Penny.Core.Anna.SeqDecsNE as SeqDecsNE
import qualified Penny.Tree.LZ6 as LZ6
import Control.Applicative
import Text.Parsec.Text

data T a
  = Novem NovDecs.T (Maybe (SeqDecsNE.T a))
  | Group a (LZ6.T a)
  deriving (Eq, Ord, Show)

parser :: Parser a -> Parser (T a)
parser pa =
  Novem <$> NovDecs.parser <*> optional (SeqDecsNE.parser pa)
  <|> Group <$> pa <*> LZ6.parser pa
