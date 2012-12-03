-- | The Convert report. This report converts all account balances to
-- a single commodity, which must be specified.

module Penny.Cabin.Balance.Convert (
  Opts(..)
  , Sorter
  , report
  , cmdLineReport
  , getSorter
  ) where

import Control.Applicative ((<$>), (<*>))
import qualified Control.Monad.Exception.Synchronous as Ex
import qualified Data.Tree as E
import qualified Data.Foldable as Fdbl
import qualified Data.Traversable as Tvbl
import qualified Penny.Cabin.Options as CO
import qualified Penny.Cabin.Colors as C
import qualified Penny.Cabin.Chunk as Chunk
import qualified Penny.Cabin.Balance.Util as U
import qualified Penny.Cabin.Balance.Convert.Chunker as K
import qualified Penny.Cabin.Balance.Convert.Help as H
import qualified Penny.Cabin.Balance.Convert.Options as O
import qualified Penny.Cabin.Balance.Convert.Parser as P
import qualified Penny.Cabin.Interface as I
import qualified Penny.Copper as Cop
import qualified Penny.Lincoln as L
import qualified Penny.Lincoln.Balance as Bal
import qualified Penny.Liberty as Ly
import qualified Penny.Shield as S
import qualified Data.Map as M
import qualified Data.Text as X
import Data.Monoid (mempty, mappend, mconcat)

-- | Options for the Convert report. These are the only options you
-- need to use if you are supplying options programatically (as
-- opposed to parsing them in from the command line.)
data Opts = Opts {
  drCrColors :: C.DrCrColors
  , baseColors :: C.BaseColors
  , balanceFormat :: L.Qty -> X.Text
  , showZeroBalances :: CO.ShowZeroBalances
  , sorter :: Sorter
  , target :: L.To
  , dateTime :: L.DateTime
  }

-- | How to sort each line of the report. Each subaccount has only one
-- BottomLine (unlike in the MultiCommodity report, where each
-- subaccount may have more than one BottomLine, one for each
-- commodity.)
type Sorter =
  (L.SubAccountName, L.BottomLine)
  -> (L.SubAccountName, L.BottomLine)
  -> Ordering

-- | Converts all commodities in a Balance to a single commodity and
-- combines all the BottomLines into one. Fails with an error message
-- if no conversion data is available.
convertBalance ::
  L.PriceDb
  -> L.DateTime
  -> L.To
  -> L.Balance
  -> Ex.Exceptional X.Text L.BottomLine
convertBalance db dt to bal = fmap mconcat r
  where
    r = mapM (convertOne db dt to) . M.assocs . L.unBalance $ bal

-- | Converts a single BottomLine to a new commodity. Fails with an
-- error message if no conversion data is available.
convertOne ::
  L.PriceDb
  -> L.DateTime
  -> L.To
  -> (L.Commodity, L.BottomLine)
  -> Ex.Exceptional X.Text L.BottomLine
convertOne db dt to (cty, bl) =
  case bl of
    L.Zero -> return L.Zero
    L.NonZero (L.Column dc qt) -> Ex.mapExceptional e g ex
      where
        ex = L.convert db dt to am
        am = L.Amount qt cty
        e = convertError to (L.From cty)
        g r = L.NonZero (L.Column dc r)

-- | Creates an error message for conversion errors.
convertError ::
  L.To
  -> L.From
  -> L.PriceDbError
  -> X.Text
convertError (L.To to) (L.From fr) e =
  let fromErr = L.text (L.Delimited (X.singleton ':')
                        (Fdbl.toList . L.unCommodity $ fr))
      toErr = L.text (L.Delimited (X.singleton ':')
                      (Fdbl.toList . L.unCommodity $ to))
  in case e of
    L.FromNotFound ->
      X.pack "no data to convert from commodity "
      `X.append` fromErr
    L.ToNotFound ->
      X.pack "no data to convert to commodity "
      `X.append` toErr
    L.CpuNotFound ->
      X.pack "no data to convert from commodity "
      `X.append` fromErr
      `X.append` (X.pack " to commodity ")
      `X.append` toErr
      `X.append` (X.pack " at given date and time")


-- | Create a price database.
buildDb :: [L.PricePoint] -> L.PriceDb
buildDb = foldl f L.emptyDb where
  f db pb = L.addPrice db pb

-- | All data for the report after all balances have been converted to
-- a single commodity and all the sums of the child accounts have been
-- added to the parent accounts.
data ForestAndBL = ForestAndBL {
  _tbForest :: E.Forest (L.SubAccountName, L.BottomLine)
  , _tbTotal :: L.BottomLine
  , _tbTo :: L.To
  }

-- | Converts the balance data in preparation for screen rendering.
rows :: ForestAndBL -> [K.Row]
rows (ForestAndBL f tot to) = first:second:rest
  where
    first = K.ROneCol $ K.OneColRow 0 desc
    desc = X.pack "All amounts reported in commodity: "
           `X.append` (L.text 
                       . L.Delimited (X.singleton ':')
                       . L.textList
                       . L.unTo
                       $ to)
    second = K.RMain $ K.MainRow 0 (X.pack "Total") tot
    rest = map mainRow
           . concatMap E.flatten
           . map U.labelLevels
           $ f


mainRow :: (Int, (L.SubAccountName, L.BottomLine)) -> K.Row
mainRow (l, (a, b)) = K.RMain $ K.MainRow l x b
  where
    x = L.text a

-- | The function for the Convert report. Use this function if you are
-- setting the options from a program (as opposed to parsing them in
-- from the command line.) Will fail if the balance conversions fail.
report ::
  Opts
  -> [L.PricePoint]
  -> [L.Box a]
  -> Ex.Exceptional X.Text [Chunk.Chunk]
report os@(Opts dc bc fmt _ _ _ _) ps bs =
  fmap (K.rowsToChunks fmt dc bc)
  . fmap rows
  . sumConvertSort os ps
  $ bs


-- | Creates a report respecting the standard interface for reports
-- whose options are parsed in from the command line.
cmdLineReport ::
  Cop.DefaultTimeZone
  -> (S.Runtime -> O.DefaultOpts)
  -> I.Report
cmdLineReport dtz toOpts = I.Report H.help "convert" parser
  where
    parser = fmap f (P.parseOpts dtz)
    f getOpts rt _ _ bs ps = do
      let defaultOpts = toOpts rt
          pDefaultOpts = O.toParserOpts defaultOpts
          op' = getOpts pDefaultOpts
          noDefault = X.pack "no default price found"
          colors = CO.autoColors (P.colorPref op') rt
      rptOpts <- Ex.fromMaybe noDefault
                 $ fromParsedOpts ps (O.format defaultOpts) op'
      cks <- report rptOpts ps bs
      return $ Chunk.chunksToText colors cks


-- | Sums the balances from the bottom to the top of the tree (so that
-- parent accounts have the sum of the balances of all their
-- children.) Then converts the commodities to a single commodity, and
-- sorts the accounts as requested. Fails if the conversion fails.
sumConvertSort ::
  Opts
  -> [L.PricePoint]
  -> [L.Box a]
  -> Ex.Exceptional X.Text ForestAndBL
sumConvertSort os ps bs = mkResult <$> convertedFrst <*> convertedTot
  where
    (Opts _ _ _ szb str tgt dt) = os
    bals = U.balances szb bs
    (frst, tot) = U.sumForest mempty mappend bals
    convertBal (a, bal) =
        (\bl -> (a, bl)) <$> convertBalance db dt tgt bal
    db = buildDb ps
    convertedFrst = mapM (Tvbl.mapM convertBal) frst
    convertedTot = convertBalance db dt tgt tot
    mkResult f t = ForestAndBL (U.sortForest str f) t tgt

-- | Determine the most frequent To commodity.
mostFrequent :: [L.PricePoint] -> Maybe L.To
mostFrequent = U.lastMode . map (L.to . L.price)


-- | Get options for the report, depending on what options were parsed
-- from the command line. Fails if the user did not specify a
-- commodity and mostFrequent fails.
fromParsedOpts ::
  [L.PricePoint]
  -> (L.Qty -> X.Text)
  -> P.Opts
  -> Maybe Opts
fromParsedOpts pp fmt (P.Opts _ dc bc szb tgt dt so sb) =
  case tgt of
    P.ManualTarget to ->
      Just $ Opts dc bc fmt szb (getSorter so sb) to dt
    P.AutoTarget ->
      case mostFrequent pp of
        Nothing -> Nothing
        Just to ->
          Just $ Opts dc bc fmt szb (getSorter so sb) to dt

-- | Returns a function usable to sort pairs of SubAccount and
-- BottomLine depending on how you want them sorted.
getSorter :: P.SortOrder -> P.SortBy -> Sorter
getSorter o b = flipper f
  where
    flipper = case o of
      P.Ascending -> id
      P.Descending -> Ly.flipOrder
    f p1@(a1, _) p2@(a2, _) = case b of
      P.SortByName -> compare a1 a2
      P.SortByQty -> cmpBottomLine p1 p2

cmpBottomLine :: Sorter
cmpBottomLine (n1, bl1) (n2, bl2) =
  case (bl1, bl2) of
    (L.Zero, L.Zero) -> EQ
    (L.NonZero _, L.Zero) -> LT
    (L.Zero, L.NonZero _) -> GT
    (L.NonZero c1, L.NonZero c2) ->
      mconcat [dc, qt, na]
      where
        dc = case (Bal.drCr c1, Bal.drCr c2) of
          (L.Debit, L.Debit) -> EQ
          (L.Debit, L.Credit) -> LT
          (L.Credit, L.Debit) -> GT
          (L.Credit, L.Credit) -> EQ
        qt = compare (Bal.qty c1) (Bal.qty c2)
        na = compare n1 n2
