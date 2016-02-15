-- | Copper - the default Penny parser
--
-- Copper runs in two phases.  The first phase transforms a string
-- into an abstract syntax tree, or AST.  It uses the Earley library
-- do this.  The grammar, in "Penny.Grammar", is a context-free
-- grammar created in "Penny.Pinchot".
-- Most error handling occurs within this
-- grammar itself--that is, the grammar is meticulously written so
-- that invalid constructs are not valid in the grammar.
--
-- The grammar does a remarkable amount of work: it ensures the
-- correctness of all dates (even leap days).  It constrains number
-- representations to permissible forms (even ensuring that grouping
-- constructs are valid--for instance, you cannot have two grouping
-- characters in a row.)  It ensures that if the user enters a side
-- (Debit, using @<@, or Credit, using @>@) that she does not enter
-- a number representation that is zero.
--
-- However, the grammar cannot do everything.  It cannot ensure that
-- transactions are balanced or that prices are constructed using
-- different commodities for the from-commodity and the
-- to-commodity.  So, a valid AST is not necessarily a valid Copper
-- file.  That's where "Penny.ConvertAst" comes in.  It
-- checks these constructs for validity, while also performing some
-- injective transformations (for example, it transforms quoted
-- strings to their equivalent Text forms.)
--
-- This module contains 'copperParser', a single function that both
-- constructs the AST and transforms it to Lincoln types using
-- "Penny.ConvertAst".
module Penny.Copper where

import Data.Sequence (Seq)
import Data.Text (Text)

import Penny.Ents
import Penny.Price
import Penny.Tree

-- | Constructs the Copper AST and transforms it
-- using "Penny.ConvertAst".
--
-- Returns either an error or the results.  If there is an error,
-- the string is never empty; however, the type system does nothing
-- to ensure this.  The error string is a human-readable error
-- message.

copperParser
  :: Text
  -> Either String (Seq (Either Price (Seq Tree, Balanced (Seq Tree))))
copperParser = undefined
{-

import Control.Lens ((<|))
import Data.Foldable (toList)
import Data.Sequence (Seq)
import Penny.Ents
import Data.List (intersperse)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as X
import qualified Data.Text.IO as XIO
import Text.Megaparsec (parse, eof)

import Penny.Friendly
import Penny.Clatch
import Penny.Copper.Ast
import Penny.Copper.ConvertAst
import Penny.Price
import Penny.Tree

copperParser inp = do
  ast <- case parse (pAst <* eof) "" inp of
    Left e -> Left (show e)
    Right g -> Right g
  case convertItemsFromAst ast of
    Left ers -> Left $ formatConvertErrors ers
    Right g -> return g

formatConvertErrors :: (ConvertE, Seq ConvertE) -> String
formatConvertErrors (c1, cs)
  = unlines . ("Error interpreting input file:":) . concat
  . intersperse [""] . (friendly c1 :) . map friendly . toList $ cs


-- | Parse input files and create transactions.

loadTransactions
  :: Seq Text
  -- ^ Filenames
  -> IO (Seq Transaction)
  -- ^ Transactions.  If there is a parse error, throws an exception.

loadTransactions = fmap addSerials . mapM load
  where
    load filename = do
      txt <- XIO.readFile . X.unpack $ filename
      case copperParser txt of
        Left e -> fail e
        Right g -> return rights
          where
            rights = foldr f Seq.empty g
              where
                f ei acc = case ei of
                  Left _ -> acc
                  Right txn -> txn <| acc
-}
