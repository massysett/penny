module Penny.Liberty.Error where

import Data.Text (Text, pack)
import qualified System.Console.MultiArg.Error as MAE

data Error = MultiArgError MAE.Expecting MAE.Saw
             | MakeMatcherFactoryError Text
             | DateParseError
             | BadPatternError Text
             | BadNumberError Text
             | BadQtyError Text
             | BadSortKeyError Text
             | BadComparator Text
             | BadExpression
             | BadColorName Text
             | BadFieldName Text
             | BadBackgroundArg Text
             | UnexpectedWord Text Text
             deriving Show

instance MAE.Error Error where
  parseErr = MultiArgError

-- | Barebones for now
display :: Error -> Text
display = pack . show