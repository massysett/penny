{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE BangPatterns #-}
-- | Copper - the default Penny parser
--
-- Copper runs in three phases.  The first phase transforms a string
-- into an abstract syntax tree, or AST.  It uses the Earley library
-- do this.  The grammar, in "Penny.Copper.Types", is a context-free
-- grammar created in "Penny.Copper.Grammar".
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
-- The second phase transforms this AST into the data types that are
-- used in the rest of Penny.  This is called the @locator@ and it
-- is in "Penny.Copper.Locator".
--
-- The third phase performs final error checking.  It ensures that
-- postings are valid, that transactions are balanced, and that
-- prices are valid.  This phase is called the @proofer@ and it is
-- in "Penny.Copper.Proofer".
--
-- This module contains the functions that most of the rest of the
-- library would ordinarily need.
module Penny.Copper where

import Accuerr (Accuerr)
import qualified Accuerr
import Control.Exception (Exception)
import qualified Control.Lens as Lens
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Sequence.NonEmpty (NonEmptySeq)
import qualified Data.Sequence.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as X
import Data.Typeable (Typeable)
import qualified Text.Earley as Earley
import Pinchot (Loc(Loc))
import qualified Pinchot

import Penny.Copper.Decopperize
import qualified Penny.Copper.EarleyGrammar as EarleyGrammar
import qualified Penny.Copper.Productions as Productions
import qualified Penny.Copper.Proofer as Proofer
import Penny.Copper.Types (WholeFile)
import Penny.Copper.Tracompri
import Penny.Cursor
import Penny.Scalar
import Penny.Tree

-- | Given an integer position in a text, obtain the Pinchot
-- position.
textPosition
  :: Int
  -- ^ Integer position (0-based, from Earley)
  -> Text
  -> Loc
textPosition int
  = X.foldl' add (Loc 1 1 1)
  . X.take int
  where
    add (Loc !lin !col !pos) c
      | c == '\n' = Loc (lin + 1) 1 (pos + 1)
      | c == '\t' = Loc lin (col + 8 - ((col - 1) `mod` 8)) (pos + 1)
      | otherwise = Loc lin (col + 1) (pos + 1)

-- | The name of a file being parsed.  This is optional and can be
-- the empty 'Text'.
type Filename = Text

data ParseErrorInfo = ParseErrorInfo
  { _failurePosition :: Loc
  , _expected :: [String]
  } deriving (Typeable, Show)

Lens.makeLenses ''ParseErrorInfo

data ParseFailReason
  = LeftoverInput
  | AbortedParse
  deriving (Typeable, Show)

Lens.makePrisms ''ParseFailReason

data ParseError = ParseError
  { _parseFailReason :: ParseFailReason
  , _parseErrorInfo :: ParseErrorInfo
  } deriving (Typeable, Show)

Lens.makeLenses ''ParseError

errorInfo
  :: Text
  -- ^ Input text
  -> Earley.Report String a
  -> ParseErrorInfo
errorInfo inp (Earley.Report pos exp _)
  = ParseErrorInfo (textPosition pos inp) exp

-- | Given a Pinchot rule, parse a complete string in that language.
runParser
  :: (forall r. Earley.Grammar r
        (Earley.Prod r String (Char, Loc) (p Char Loc)))
  -> Text
  -> Either ParseError (p Char Loc)
runParser grammar txt = case results of
  result:[]
    | Seq.null (Earley.unconsumed report) -> Right result
    | otherwise -> Left (ParseError LeftoverInput info)
  [] -> Left (ParseError AbortedParse info)
  _ -> error "runParser: grammar is ambiguous."
  where
    (results, report) = Pinchot.locatedFullParses grammar txt
    info = errorInfo txt report

-- | Parses a particular production from
-- 'Penny.Copper.Productions.Productions'.
parseProduction
  :: (forall r. Productions.Productions r Char Loc
      -> Earley.Prod r String (Char, Loc) (p Char Loc))
  -> Text
  -> Either ParseError (p Char Loc)
parseProduction getGrammar txt = case results of
  result:[]
    | Seq.null (Earley.unconsumed report) -> Right result
    | otherwise -> Left (ParseError LeftoverInput info)
  [] -> Left (ParseError AbortedParse info)
  _ -> error "runParser: grammar is ambiguous."
  where
    (results, report) = Pinchot.locatedFullParses grammar txt
    grammar = fmap getGrammar EarleyGrammar.earleyGrammar
    info = errorInfo txt report

-- | Creates a 'Tree' holding the filename.
filenameTree :: Filename -> Tree
filenameTree name = Tree (Just (SText "filename"))
  [ Tree (Just (SText name)) [] ]

-- | Given the results of a parse, append a filename tree to each
-- transaction.
appendFilenameTrees
  :: Functor f
  => Filename
  -> f (Either a (Seq Tree, b))
  -> f (Either a (Seq Tree, b))
appendFilenameTrees filename = Lens.over setter f
  where
    setter = Lens.mapped . Lens._Right . Lens._1
    f sq = sq `Lens.snoc` (filenameTree filename)


data ParseConvertProofError a = ParseConvertProofError
  { _filenameWithError :: Filename
  , _parseOrProofFailure
      :: Either ParseError (NonEmptySeq (Proofer.ProofFail a))
  } deriving (Typeable, Show)

Lens.makeLenses ''ParseConvertProofError

instance (Typeable a, Show a) => Exception (ParseConvertProofError a)

-- | Takes the result of parsing a production and returns either the
-- result or a ParseConvertProofError.
parseResultToError
  :: Filename
  -> Either ParseError (p Char Loc)
  -> Either (ParseConvertProofError a) (p Char Loc)
parseResultToError filename
  = either (Left . ParseConvertProofError filename . Left) Right

-- | Takes the result of proofing items and returns either the result
-- or a ParseConvertProofError.
proofResultToError
  :: Filename
  -> Accuerr (NonEmptySeq (Proofer.ProofFail a)) (Seq (Tracompri Loc))
  -> Either (ParseConvertProofError a) (Seq (Tracompri Cursor))
proofResultToError filename ac = case ac of
  Accuerr.AccFailure e -> Left . ParseConvertProofError filename
    . Right $ e
  Accuerr.AccSuccess g -> Right . fmap (fmap (Cursor filename)) $ g

-- | Parses, converts, and proofs a single file.
parseConvertProof
  :: (Filename, Text)
  -> Either (ParseConvertProofError Loc)
            (WholeFile Char Loc, (Seq (Tracompri Cursor)))
parseConvertProof (filename, txt) = do
  wholeFile <- parseResultToError filename
    $ parseProduction Productions.a'WholeFile txt
  res <- proofResultToError filename . Proofer.proofItems . dWholeFile
            $ wholeFile
  return (wholeFile, res)

parseConvertProofAccuerr
  :: (Filename, Text)
  -> Accuerr (NonEmptySeq (ParseConvertProofError Loc))
             (WholeFile Char Loc, Seq (Tracompri Cursor))
parseConvertProofAccuerr
  = Lens.over Accuerr._AccFailure NE.singleton
  . Accuerr.eitherToAccuerr
  . parseConvertProof

-- | Parses, converts, and proofs a series of files.
parseConvertProofFiles
  :: Seq (Filename, Text)
  -> Accuerr (NonEmptySeq (ParseConvertProofError Loc))
             (Seq (WholeFile Char Loc, Seq (Tracompri Cursor)))
parseConvertProofFiles = traverse parseConvertProofAccuerr
