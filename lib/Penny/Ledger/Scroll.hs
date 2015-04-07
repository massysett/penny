{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | A 'Scroll' is a an implementation of a 'Ledger'.  The 'Scroll' is
-- the simplest 'Ledger', as it simply takes a list of concrete prices
-- and transactions and stores them in memory.
module Penny.Ledger.Scroll where

import Penny.Amount
import Penny.Ledger
import Control.Applicative
import Control.Monad.Trans.Class
import Penny.Lincoln.Transaction
import Data.Functor.Identity
import Penny.Lincoln.Field
import Penny.Lincoln.Ents
import Penny.Lincoln.Ent
import Penny.Lincoln.Prices
import Control.Monad.Reader
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq

type Environment
  = Seq (Seq (Either Price (Transaction TopLineSer PostingSer)))

newtype ScrollT m a
  = ScrollT (ReaderT Environment m a)
  deriving
  ( Functor
  , Applicative
  , Monad
  , MonadTrans
  , MonadReader Environment
  )

type Scroll = ScrollT Identity

instance (Applicative m, Monad m) => Ledger (ScrollT m) where
  type PriceL (ScrollT m) = Price
  type TransactionL (ScrollT m) = Transaction TopLineSer PostingSer
  type TreeL (ScrollT m) = Tree
  type PostingL (ScrollT m) = Ent (PstgMeta PostingSer)

  vault = ask
  dateTime (Price dt _ _) = return dt
  fromTo (Price _ tr _) = return tr
  exchange (Price _ _ ex) = return ex
  scalar (Tree _ s _) = return s
  realm (Tree r _ _) = return r
  offspring (Tree _ _ ts) = return . Seq.fromList $ ts
  txnMeta (Transaction (TopLine ts _) _) = return . Seq.fromList $ ts
  topLineSer (Transaction (TopLine _ zk) _) = return zk
  pstgMeta (Ent _ (PstgMeta tr _ _)) = return . Seq.fromList $ tr
  postings (Transaction _ bal) = return . balancedToSeqEnt $ bal
  trio (Ent _ (PstgMeta _ tri _)) = return tri
  qty (Ent (Amount _ q) _) = return q
  commodity (Ent (Amount c _) _) = return c
  postingSer (Ent _ (PstgMeta _ _ a)) = return a

