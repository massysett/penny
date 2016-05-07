{-# LANGUAGE TemplateHaskell #-}
-- | Obtaining transactions and prices from a Copper-formatted file
-- takes three steps: parsing, conversion, and proofing.  This
-- module performs proofing.
--
-- Proofing can fail.  If it does, the proofer tries to accumulate
-- as many error messages as possible, so that the user can fix all
-- errors at once rather than having to fix one error at a time.

module Penny.Copper.Proofer where

import Penny.Commodity
import Penny.Copper.Decopperize
import Penny.Copper.PriceParts
import Penny.Ents
import Penny.NonEmpty
import qualified Penny.NonEmpty as NonEmpty
import Penny.Price
import Penny.Trio
import Penny.Tree

import qualified Control.Lens as Lens
import Control.Monad (foldM)
import Data.Sequence (Seq)
import qualified Data.Validation as V
import Pinchot (Loc)

data Reason
  = FailedToAddTrio TrioError
  | Imbalanced ImbalancedError
  | MatchingFromTo Commodity
  deriving Show

data ProofFail = ProofFail
  { _location :: Loc
  , _reason :: Reason
  } deriving Show

Lens.makeLenses ''ProofFail

addPostingToEnts
  :: Ents (Seq Tree)
  -> (Loc, Trio, Seq Tree)
  -> Either ProofFail (Ents (Seq Tree))
addPostingToEnts ents (pos, trio, trees)
  = case appendTrio ents trio of
      Left e -> Left (ProofFail pos (FailedToAddTrio e))
      Right f -> Right $ f trees

-- | Creates an 'Balanced' from a sequence of postings.  If any single
-- posting fails, returns a single error message.  If balancing
-- fails, returns a single error message.
balancedFromPostings
  :: Seq (Loc, Trio, Seq Tree)
  -> Either ProofFail (Balanced (Seq Tree))
balancedFromPostings sq = case nonEmpty sq of
  Nothing -> return mempty
  Just ne@(NonEmpty (pos, _, _) _) -> case foldM addPostingToEnts mempty ne of
    Left e -> Left e
    Right g -> case entsToBalanced g of
      Left e -> Left (ProofFail pos (Imbalanced e))
      Right g -> return g

price
  :: PriceParts Loc
  -- ^
  -> Either ProofFail Price
price pp = case makeFromTo (FromCy (_priceFrom pp)) (ToCy (_priceTo pp)) of
  Nothing -> Left (ProofFail (_pricePos pp) (MatchingFromTo (_priceFrom pp)))
  Just fromTo -> Right (Price (_priceTime pp) fromTo (_priceExch pp))

proofItem
  :: Either (PriceParts Loc) TxnParts
  -- ^
  -> Either ProofFail (Either Price (Seq Tree, Balanced (Seq Tree)))
proofItem x = case x of
  Left p -> fmap Left (price p)
  Right (topLine, pstgs) -> fmap mkTxn (balancedFromPostings pstgs)
    where
      mkTxn bal = Right (topLine, bal)

proofItems
  :: Seq (Either (PriceParts Loc) TxnParts)
  -- ^
  -> V.AccValidation (NonEmpty ProofFail)
      (Seq (Either Price (Seq Tree, Balanced (Seq Tree))))
proofItems
  = sequenceA
  . fmap (Lens.view V._AccValidation)
  . Lens.over (Lens.mapped . Lens._Left) NonEmpty.singleton
  . fmap proofItem
