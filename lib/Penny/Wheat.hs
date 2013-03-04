module Penny.Wheat
  ( -- * Basic predicates

  -- * Other conveniences
  , futureFirstsOfTheMonth

  -- * Configuration and CLI
  , ColorToFile
  , BaseTime
  , WheatConf(..)
  , wheatMain

  -- * Re-exports
  , S.Runtime
  , S.currentTime
  , module Text.Matchers
  , module Penny.Steel.Prednote
  , module Data.Time
  ) where

import Control.Arrow (second)
import Control.Monad (join)
import qualified Control.Monad.Exception.Synchronous as Ex
import Data.List (intersperse)
import Data.Maybe (mapMaybe)
import qualified Penny.Steel.Prednote as N
import qualified Penny.Copper as Cop
import qualified Penny.Copper.Parsec as CP
import qualified Penny.Lincoln.Predicates as P
import qualified Penny.Lincoln.Queries as Q
import qualified Penny.Lincoln as L
import qualified Data.Text as X
import qualified Penny.Lincoln.Builders as Bd
import Data.Text (Text, pack)
import qualified Data.Time as T
import qualified Text.Matchers as M
import qualified Text.Parsec as Parsec
import qualified System.Console.MultiArg as MA
import qualified System.Console.Terminfo as TI
import qualified System.Exit as Exit
import System.Locale (defaultTimeLocale)
import qualified System.IO as IO
import qualified Penny.Shield as S

import Text.Matchers
import Penny.Steel.Prednote hiding (Pdct)
import Data.Time

data Defaults = Defaults
  { passVerbosity :: N.PassVerbosity
  , failVerbosity :: N.FailVer

------------------------------------------------------------
-- Other conveniences
------------------------------------------------------------


-- | A non-terminating list of starting with the first day of the
-- first month following the given day, followed by successive first
-- days of the month.
futureFirstsOfTheMonth :: T.Day -> [T.Day]
futureFirstsOfTheMonth d = iterate (T.addGregorianMonthsClip 1) d1
  where
    d1 = T.fromGregorian yr mo 1
    (yr, mo, _) = T.toGregorian $ T.addGregorianMonthsClip 1 d

------------------------------------------------------------
-- CLI
------------------------------------------------------------

type ProgName = String
type BriefDesc = String
type ColorToFile = Bool
type BaseTime = L.DateTime
type MoreHelp = [String]

help
  :: ProgName
  -> BriefDesc
  -> N.PassVerbosity
  -> N.FailVerbosity
  -> N.SpaceCount
  -> ColorToFile
  -> BaseTime
  -> MoreHelp
  -> String
help pn bd pv fv sc ctf bt mh = unlines $
  [ "usage: " ++ pn ++ "[options] ARGS"
  , ""
  , bd
  , "Options:"
  , ""
  , "--color-to-file no|yes"
  , "  If yes, use colors even when standard output is"
  , "  not a terminal. (default: " ++ dCtf ++ ")"
  , ""
  , "--pass-verbosity, -p VERBOSITY"
  , "--fail-verbosity, -f VERBOSITY"
  , "  Use the given level of verbosity for passing or for"
  , "  failing tests (each may be set independently.) Choices:"
  , "    silent - show nothing at all"
  , "    status - show only that the test passed or failed"
  , "    interesting - show that the test passed or failed, and"
  , "      the interesting results of the underlying predicates"
  , "    all - show that the test passed or failed, and all"
  , "      results from the underlying predicates"
  , "    (default pass verbosity: " ++ descV pv ++ ")"
  , "    (default fail verbosity: " ++ descV fv ++ ")"
  , ""
  , "--indentation, -i SPACES"
  , "  indent each level by this many spaces"
  , "  (default: " ++ dSc ++ ")"
  , ""
  , "--base-date, -d DATE"
  , "  use this date as basis for checks"
  , "  (currently: " ++ showDateTime bt ++ ")"
  , ""
  , "--help, -h - show help and exit"
  , ""
  ] ++ mh
  where
    dCtf = if ctf then "yes" else "no"
    descV v = case v of
      N.Silent -> "silent"
      N.Status -> "status"
      N.Interesting -> "interesting"
      N.All -> "all"
    dSc = show sc

showDateTime :: L.DateTime -> String
showDateTime (L.DateTime d h m s tz) =
  ds ++ " " ++ hmss ++ " " ++ showOffset
  where
    ds = show d
    hmss = hs ++ ":" ++ ms ++ ":" ++ ss
    hs = pad0 . show . L.unHours $ h
    ms = pad0 . show . L.unMinutes $ m
    ss = pad0 . show . L.unSeconds $ s
    pad0 str = if length str < 2 then '0':str else str
    showOffset =
      let (zoneHr, zoneMin) = abs (L.offsetToMins tz) `divMod` 60
          sign = if L.offsetToMins tz < 0 then "-" else "+"
      in sign ++ pad0 (show zoneHr) ++ pad0 (show zoneMin)

data Arg
  = APassV N.Verbosity
  | AFailV N.Verbosity
  | AColorToFile ColorToFile
  | AIndentation N.SpaceCount
  | ABaseTime L.DateTime
  | APosArg String
  deriving Eq

lsVerbosity :: [(String, N.Verbosity)]
lsVerbosity = [ ("silent", N.Silent)
              , ("status", N.Status)
              , ("interesting", N.Interesting)
              , ("all", N.All)
              ]

optPassVerbosity :: MA.OptSpec Arg
optPassVerbosity = MA.OptSpec ["pass-verbosity"] "p" (MA.ChoiceArg ls)
  where
    ls = fmap (second APassV) lsVerbosity

optFailVerbosity :: MA.OptSpec Arg
optFailVerbosity = MA.OptSpec ["fail-verbosity"] "f" (MA.ChoiceArg ls)
  where
    ls = fmap (second AFailV) lsVerbosity

optColorToFile :: MA.OptSpec Arg
optColorToFile = MA.OptSpec ["color-to-file"] "" (MA.ChoiceArg ls)
  where
    ls = fmap (second AColorToFile) [ ("no", False), ("yes", True) ]

type ExS = Ex.Exceptional String
optIndentation :: MA.OptSpec (ExS Arg)
optIndentation = MA.OptSpec ["indentation"] "i" (MA.OneArg f)
  where
    f s =
      let err = Ex.throw $ "improper indentation argument: " ++ s
      in case reads s of
          (i, ""):[] ->
            if i >= 0 then Ex.Success (AIndentation i) else err
          _ -> err

optBaseTime :: MA.OptSpec (ExS Arg)
optBaseTime = MA.OptSpec ["base-date"] "b" (MA.OneArg f)
  where
    f s = case Parsec.parse CP.dateTime  "" (X.pack s) of
      Left e -> Ex.throw $ "could not parse date: " ++ show e
      Right g -> return . ABaseTime $ g

type ParsedOpts = ( N.PassVerbosity, N.FailVerbosity, N.SpaceCount,
                    ColorToFile, BaseTime, [String])

-- | When passed the defaults, return the values to use, as they might
-- have been affected by the command arguments, or return Nothing if
-- help is needed.
parseArgs
  :: N.PassVerbosity
  -> N.FailVerbosity
  -> N.SpaceCount
  -> ColorToFile
  -> BaseTime
  -> [String]
  -> ParseResult
parseArgs pv fv sc ctf bt ss =
  let exLs = MA.simple MA.Intersperse opts (return . APosArg) ss
      opts = [ fmap return optHelp
             , fmap return optPassVerbosity
             , fmap return optFailVerbosity
             , fmap return optColorToFile
             , optIndentation
             , optBaseTime
             ]
  in case exLs of
      Ex.Exception e -> ParseErr . show $ e
      Ex.Success ls -> case sequence ls of
        Ex.Exception e -> ParseErr e
        Ex.Success ls' ->
          if AHelp `elem` ls'
          then NeedsHelp
          else Parsed ( (getPassVerbosity pv ls'), (getFailVerbosity fv ls')
                        , (getSpaceCount sc ls')
                        , (getColorToFile ctf ls'), (getBaseTime bt ls')
                        , (getPosArg ls'))

getPassVerbosity :: N.PassVerbosity -> [Arg] -> N.PassVerbosity
getPassVerbosity v as = case mapMaybe f as of
  [] -> v
  xs -> last xs
  where f a = case a of { APassV vb -> Just vb; _ -> Nothing }

getFailVerbosity :: N.FailVerbosity -> [Arg] -> N.FailVerbosity
getFailVerbosity v as = case mapMaybe f as of
  [] -> v
  xs -> last xs
  where f a = case a of { AFailV vb -> Just vb; _ -> Nothing }

getSpaceCount :: N.SpaceCount -> [Arg] -> N.SpaceCount
getSpaceCount sc as = case mapMaybe f as of
  [] -> sc
  xs -> last xs
  where f a = case a of { AIndentation i -> Just i; _ -> Nothing }

getColorToFile :: ColorToFile -> [Arg] -> ColorToFile
getColorToFile ctf as = case mapMaybe f as of
  [] -> ctf
  xs -> last xs
  where f a = case a of { AColorToFile i -> Just i; _ -> Nothing }

getPosArg :: [Arg] -> [String]
getPosArg = mapMaybe f
  where f a = case a of { APosArg s -> Just s; _ -> Nothing }

getBaseTime :: BaseTime -> [Arg] -> BaseTime
getBaseTime bd as = case mapMaybe f as of
  [] -> bd
  xs -> last xs
  where f a = case a of { ABaseTime x -> Just x; _ -> Nothing }

data WheatConf = WheatConf
  { briefDescription :: String
  , moreHelp :: [String]
  , passVerbosity :: N.PassVerbosity
  , failVerbosity :: N.FailVerbosity
  , spaceCount :: N.SpaceCount
  , colorToFile :: ColorToFile
  , tests :: BaseTime -> [N.Test L.PostFam]
  , baseTime :: BaseTime
  }

applyParse
  :: ProgName
  -> WheatConf
  -> [String]
  -> IO ParsedOpts
applyParse pn c as =
  case parseArgs (passVerbosity c) (failVerbosity c) (spaceCount c)
       (colorToFile c) (baseTime c) as of
    NeedsHelp -> do
      putStrLn (help pn (briefDescription c)
                (passVerbosity c) (failVerbosity c)
                (spaceCount c) (colorToFile c) (baseTime c)
                (moreHelp c))
      Exit.exitSuccess
    ParseErr e -> do
      putStrLn $ pn ++ ": could not parse command line: " ++ e
      Exit.exitFailure
    Parsed r -> return r

wheatMain :: (S.Runtime -> WheatConf) -> IO ()
wheatMain getConf = do
  rt <- S.runtime
  pn <- MA.getProgName
  as <- MA.getArgs
  let c = getConf rt
  (pv, fv, sc, ctf, bt, posargs) <- applyParse pn c as
  let getTerm =
        if ctf || (S.output rt == S.IsTTY)
        then TI.setupTermFromEnv
        else TI.setupTerm "dumb"
  ti <- getTerm
  let runTests is = map (N.runTest pv fv is 0) (tests c bt)
  good <- fmap and
          . join
          . fmap (mapM (N.showResults ti sc display))
          . fmap runTests
          $ getItems pn posargs
  if good
    then Exit.exitSuccess
    else Exit.exitFailure

-- | Displays a PostFam in a one line format.
--
-- Format:
--
-- File LineNo Date Payee Acct DrCr Cmdty Qty
display :: L.PostFam -> Text
display p = X.pack $ concat (intersperse " " ls)
  where
    ls = [file, lineNo, dt, pye, acct, dc, cmdty, qt]
    file = maybe (labelNo "filename") (X.unpack . L.unFilename)
           (Q.filename p)
    lineNo = maybe (labelNo "line number")
             (show . L.unPostingLine) (Q.postingLine p)
    dateFormat = "%Y-%m-%d %T %z"
    dt = T.formatTime defaultTimeLocale dateFormat
         . T.utctDay
         . L.toUTC
         . Q.dateTime
         $ p
    pye = maybe (labelNo "payee")
            (X.unpack . L.text) (Q.payee p)
    acct = X.unpack . X.intercalate (X.singleton ':')
           . map L.unSubAccount . L.unAccount . Q.account $ p
    dc = case Q.drCr p of
      L.Debit -> "Dr"
      L.Credit -> "Cr"
    cmdty = X.unpack . L.unCommodity . Q.commodity $ p
    qt = show . Q.qty $ p

labelNo :: String -> String
labelNo s = "(no " ++ s ++ ")"

getItems :: ProgName -> [String] -> IO [L.PostFam]
getItems pn ss = Cop.openStdin ss >>= f
  where
    f res = case res of
      Ex.Exception e -> do
        IO.hPutStrLn IO.stderr $ pn
          ++ ": error: could not parse ledgers: "
          ++ (X.unpack . Cop.unErrorMsg $ e)
        Exit.exitFailure
      Ex.Success g ->
        let toTxn i = case i of { Cop.Transaction x -> Just x; _ -> Nothing }
        in return . concatMap L.postFam
           . mapMaybe toTxn . Cop.unLedger $ g

