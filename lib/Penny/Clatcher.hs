{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FunctionalDependencies #-}
module Penny.Clatcher where

import Control.Applicative
import qualified Control.Concurrent.Async as Async
import Control.Exception (IOException, catch,
  throwIO, Exception, bracketOnError)
import Control.Lens hiding (pre)
import Control.Monad.Reader
import Data.Bifunctor
import Data.Bifunctor.Joker
import Data.Functor.Compose
import Data.Monoid
import Text.Read (readMaybe)
import qualified Data.ByteString as BS
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text.IO as X
import qualified Data.Traversable as T
import Data.Typeable
import Penny.Amount
import Penny.Clatch
import Penny.Copper
import Penny.Ledger
import Penny.Ledger.Scroll
import Penny.Matcher
import Penny.Price
import Penny.Qty
import Penny.Representation
import Penny.SeqUtil
import Penny.Transaction
import Pipes
import Pipes.Cliff (pipeInput, NonPipe(..), terminateProcess, procSpec
  , waitForProcess)
import Pipes.Prelude (drain, tee)
import Pipes.Safe (SafeT, runSafeT)
import Rainbow
import qualified System.IO as IO
import System.Process (readProcess)

-- # Type synonyms

type PreFilter l = Matcher (TransactionL l, View (Converted (PostingL l))) l ()
type Filtereds l = Seq (Filtered (TransactionL l, View (Converted (PostingL l))))
type PostFilter l
  = Matcher (RunningBalance
    (Sorted (Filtered (TransactionL l, View (Converted (PostingL l)))))) l ()
type AllChunks = (Seq (Chunk Text), Seq (Chunk Text), Seq (Chunk Text))

type Reporter l
  = (Amount -> NilOrBrimScalarAnyRadix)
  -> Seq (Clatch l)
  -> Seq (Chunk Text)

class Report a where
  printReport :: Ledger l => a -> Reporter l

-- # Serials

stripUnits
  :: Seq (Seq (Either a (Transaction ((), b) ((), c))))
  -> Seq (Seq (Either a (Transaction b c)))
stripUnits = fmap (fmap (second (first snd . second snd)))

addSerials
  :: Seq (Seq (Either a (Transaction () ())))
  -> Seq (Seq (Either a (Transaction ((), TopLineSer) ((), PostingSer))))
addSerials
  = fmap (fmap runJoker)
  . fmap getCompose
  . assignSerialsToTxns
  . fmap Compose
  . fmap (fmap Joker)


-- # Streams

-- | An action that waits on a particular stream to finish.  This
-- action should block until the stream is done.
newtype Waiter = Waiter (IO ())

instance Monoid Waiter where
  mempty = Waiter (return ())
  mappend (Waiter x) (Waiter y) = Waiter $ Async.withAsync x $ \ax ->
    Async.withAsync y $ \ay -> do
      Async.wait ax
      Async.wait ay

-- | An action that terminates a stream right away.
newtype Terminator = Terminator (IO ())

instance Monoid Terminator where
  mempty = Terminator (return ())
  mappend (Terminator x) (Terminator y) = Terminator $ Async.withAsync x $ \ax ->
    Async.withAsync y $ \ay -> do
      Async.wait ax
      Async.wait ay


-- | A stream that accepts 'Chunk' 'Text', coupled with an action that
-- terminates the stream right away and an action that waits for the
-- stream to terminate normally.
data Stream = Stream (Consumer (Chunk Text) (SafeT IO) ()) Waiter Terminator

instance Monoid Stream where
  mempty = devNull
  mappend (Stream cx wx tx) (Stream cy wy ty)
    = Stream (tee cx >-> cy) (wx <> wy) (tx <> ty)

terminate :: Stream -> IO ()
terminate (Stream _ _ (Terminator t)) = t

wait :: Stream -> IO ()
wait (Stream _ (Waiter w) _) = w

devNull :: Stream
devNull = Stream drain (Waiter (return ())) (Terminator (return ()))

chunkConverter
  :: Monad m
  => ((Chunk Text) -> [ByteString] -> [ByteString])
  -> Pipe (Chunk Text) ByteString m a
chunkConverter f = do
  ck <- await
  let bss = f ck []
  mapM_ yield bss
  chunkConverter f

-- | Runs a stream that accepts on its standard input.
streamToStdin
  :: String
  -- ^ Program name
  -> [String]
  -- ^ Arguments
  -> ((Chunk Text) -> [ByteString] -> [ByteString])
  -- ^ Chunk converter
  -> IO Stream
streamToStdin name args conv = do
  (pipe, handle) <- pipeInput Inherit Inherit (procSpec name args)
  return (Stream (chunkConverter conv >-> pipe >> return ())
                 (Waiter (waitForProcess handle >> return ()))
                 (Terminator (terminateProcess handle)))

-- | Runs a stream that accepts input and sends it to a file.
streamToFile
  :: Bool
  -- ^ If True, append; otherwise, overwrite.
  -> String
  -- ^ Filename
  -> (Chunk Text -> [ByteString] -> [ByteString])
  -> IO Stream
streamToFile apnd fn conv = do
  h <- IO.openFile fn (if apnd then IO.AppendMode else IO.WriteMode)
  let toFile = do
        ck <- await
        liftIO $ mapM_ (BS.hPut h) (conv ck [])
        toFile
  return $ Stream toFile (Waiter (IO.hClose h))
    (Terminator (IO.hClose h))

feedStream
  :: IO Stream
  -> Seq (Chunk Text)
  -> IO b
  -> IO b
feedStream strm sq rest = withStream strm $ \str -> do
  let act = runSafeT $ runEffect $ Pipes.each sq >-> str
  bracketOnError (Async.async act) Async.cancel $ \asy -> do
    a <- rest
    Async.wait asy
    return a

-- | Runs a stream.  Under normal circumstances, waits for the
-- underlying process to stop running.  If an exception is thrown,
-- terminates the process immediately.
withStream
  :: IO Stream
  -> (Consumer (Chunk Text) (SafeT IO) () -> IO b)
  -> IO b
withStream acq useCsmr = bracketOnError acq terminate
  $ \str@(Stream csmr _ _) -> do
  r <- useCsmr csmr
  wait str
  return r

--
-- Converter
--

newtype Converter = Converter (Amount -> Maybe Amount)

makeWrapped ''Converter

instance Monoid Converter where
  mempty = Converter (const Nothing)
  mappend (Converter x) (Converter y) = Converter $ \a -> x a <|> y a

--
-- Octavo
--

data Octavo t l = Octavo
  { _filterer :: Matcher t l ()
  , _streamer :: IO Stream
  }

makeLenses ''Octavo

instance Monad l => Monoid (Octavo t l) where
  mempty = Octavo empty (return mempty)
  Octavo x0 x1 `mappend` Octavo y0 y1 = Octavo (x0 <|> y0)
    ((<>) <$> x1 <*> y1)

--
-- Errors
--

data PennyError
  = ParseError String
  deriving (Show, Typeable)

instance Exception PennyError

--
-- Loader
--

class Loader o l | o -> l where
  loadChunks :: Ledger l => l AllChunks -> o -> IO AllChunks

-- | Holds data, either loaded from a file or indicates the data to load.
data LoadScroll
  = Preloaded (Seq (Either Price (Transaction () ())))
  | OpenFile String
  deriving (Eq, Show, Ord)

readAndParseScroll
  :: LoadScroll
  -> IO (Seq (Either Price (Transaction () ())))
readAndParseScroll (Preloaded sq) = return sq
readAndParseScroll (OpenFile fn)
  = (either (throwIO . ParseError) return . copperParser)
  <=< X.readFile
  $ fn

instance Loader (Seq LoadScroll) Scroll where
  loadChunks (ScrollT act)
    = liftM (runReader act . stripUnits . addSerials)
    . T.mapM readAndParseScroll

preload
  :: String
  -- ^ Load from this file
  -> IO LoadScroll
preload fn = do
  txt <- X.readFile fn
  case copperParser txt of
    Left e -> throwIO $ ParseError e
    Right sq -> return . Preloaded $ sq

openFile :: String -> LoadScroll
openFile = OpenFile


--
-- ClatchOptions
--

data ClatchOptions l r o = ClatchOptions
  { _converter :: Converter
  , _renderer :: Maybe (Either (Maybe RadCom) (Maybe RadPer))
  , _pre :: Octavo (TransactionL l, View (Converted (PostingL l))) l
  , _sorter :: Seq (Filtereds l -> l (Filtereds l))
  , _post :: Octavo (RunningBalance (Sorted (Filtered
      (TransactionL l, View (Converted (PostingL l)))))) l
  , _report :: IO Stream
  , _reporter :: r
  , _opener :: o
  }

makeLenses ''ClatchOptions

instance (Monad l, Monoid r, Monoid o) => Monoid (ClatchOptions l r o) where
  mempty = ClatchOptions
    { _converter = mempty
    , _renderer = Nothing
    , _pre = mempty
    , _sorter = mempty
    , _post = mempty
    , _report = return mempty
    , _reporter = mempty
    , _opener = mempty
    }

  mappend x y = ClatchOptions
    { _converter = _converter x <> _converter y
    , _renderer = getLast $ Last (_renderer x) <> Last (_renderer y)
    , _pre = _pre x <> _pre y
    , _sorter = _sorter x <> _sorter y
    , _post = _post x <> _post y
    , _report = (<>) <$> _report x <*> _report y
    , _reporter = _reporter x <> _reporter y
    , _opener = _opener x <> _opener y
    }

-- | How many colors to show for a particular terminal.
data HowManyColors = HowManyColors
  { _showAnyColors :: Bool
  -- ^ If True, show colors.  How many colors to show depends on the
  -- value of '_show256Colors'.

  , _show256Colors :: Bool
  -- ^ If True and '_showAnyColors' is True, show 256 colors.  If
  -- False and '_showAnyColors' is True, show 8 colors.  If
  -- '_showAnyColors' is False, no colors are shown regardless of the
  -- value of '_show256Colors'.
  } deriving (Eq, Show, Ord)

makeLenses ''HowManyColors

colorizer
  :: HowManyColors
  -> Chunk Text
  -> [ByteString]
  -> [ByteString]
colorizer (HowManyColors anyC c256)
  | not anyC = toByteStringsColors0
  | not c256 = toByteStringsColors8
  | otherwise = toByteStringsColors256

-- | With 'mempty', both fields are 'True'.  'mappend' runs '&&' on
-- both fields.
instance Monoid HowManyColors where
  mempty = HowManyColors True True
  mappend (HowManyColors x1 x2) (HowManyColors y1 y2)
    = HowManyColors (x1 && y1) (x2 && y2)

-- | How many colors to show, for various terminals.
data ChooseColors = ChooseColors
  { _canShow0 :: HowManyColors
  -- ^ Show this many colors when @tput@ indicates that the terminal
  -- can show no colors, or when @tput@ fails.

  , _canShow8 :: HowManyColors
  -- ^ Show this many colors when @tput@ indicates that the terminal
  -- can show at least 8, but less than 256, colors.

  , _canShow256 :: HowManyColors
  -- ^ Show this many colors when @tput@ indicates that the terminal
  -- can show 256 colors.
  } deriving (Eq, Show, Ord)

makeLenses ''ChooseColors

tputColors :: IO (ReifiedLens' ChooseColors HowManyColors)
tputColors = catch getLens handle
  where
    handle :: IOException -> IO (ReifiedLens' ChooseColors HowManyColors)
    handle _ = return $ Lens canShow0
    getLens = do
      str <- readProcess "tput" ["colors"] ""
      return $ case readMaybe (init str) of
        Nothing -> Lens canShow0
        Just i
          | i < (8 :: Int) -> Lens canShow0
          | i < 256 -> Lens canShow8
          | otherwise -> Lens canShow256

-- | Uses the 'Monoid' instance of 'HowManyColors'.
instance Monoid ChooseColors where
  mempty = ChooseColors mempty mempty mempty
  mappend (ChooseColors x0 x1 x2) (ChooseColors y0 y1 y2)
    = ChooseColors (x0 <> y0) (x1 <> y1) (x2 <> y2)

-- | Type holding values that have a certain number of colors.
data Colorable a = Colorable
  { _chooseColors :: ChooseColors
  , _colored :: a
  } deriving (Functor, Foldable, Traversable)

instance Monoid a => Monoid (Colorable a) where
  mempty = Colorable mempty mempty
  mappend (Colorable x0 x1) (Colorable y0 y1)
    = Colorable (x0 <> y0) (x1 <> y1)

class Streamable a where
  toStream :: a -> IO Stream

-- | Record for data to create a process that reads from its standard input.
data StdinProcess = StdinProcess
  { _programName :: String
  , _programArgs :: [String]
  }

makeLenses ''StdinProcess

instance Monoid StdinProcess where
  mempty = StdinProcess mempty mempty
  mappend (StdinProcess x0 x1) (StdinProcess y0 y1)
    = StdinProcess (x0 <> y0) (x1 <> y1)

instance Streamable (Colorable StdinProcess) where
  toStream (Colorable clrs stp) = do
    chooser <- tputColors
    let clrzr = colorizer (clrs ^. (runLens chooser))
    streamToStdin (_programName stp) (_programArgs stp) clrzr

-- | Data to create a sink that puts data into a file.
data FileSink = FileSink
  { _sinkFilename :: String
  , _appendToSink :: Bool
  }

instance Monoid FileSink where
  mempty = FileSink mempty False
  mappend (FileSink x0 x1) (FileSink y0 y1)
    = FileSink (x0 <> y0) (x1 && y1)

makeLenses ''FileSink

instance Streamable (Colorable FileSink) where
  toStream (Colorable clrs (FileSink fn apnd)) = do
    chooser <- tputColors
    let clrzr = colorizer (clrs ^. (runLens chooser))
    streamToFile apnd fn clrzr

-- | Creates a stream that, when you apply 'toStream' to the result,
-- sends output to @less@.  By default, the number of colors is the
-- maximum number allowed by the terminal.
toLess :: Colorable StdinProcess
toLess = Colorable clrs (StdinProcess "less" ["-R"])
  where
    clrs = ChooseColors
      { _canShow0 = HowManyColors False False
      , _canShow8 = HowManyColors True False
      , _canShow256 = HowManyColors True True
      }

-- | Creates a stream that, when you apply 'toStream' to the result,
-- sends output to a file.  By default, no colors are used under any
-- circumstance, and any existing file is replaced.
toFile
  :: String
  -- ^ Filename
  -> Colorable FileSink
toFile fn = Colorable clrs (FileSink fn False)
  where
    clrs = ChooseColors
      { _canShow0 = HowManyColors False False
      , _canShow8 = HowManyColors False False
      , _canShow256 = HowManyColors False False
      }

--
-- Messages
--

msgsToChunks
  :: Seq (Seq Message)
  -> Seq (Chunk Text)
msgsToChunks = join . join . fmap (fmap (Seq.fromList . ($ []) . toChunks))

--
-- Main clatcher
--

smartRender
  :: ClatchOptions l r o
  -> Renderings
  -> Amount
  -> NilOrBrimScalarAnyRadix
smartRender opts (Renderings rndgs) (Amount cy qt)
  = c'NilOrBrimScalarAnyRadix'QtyRepAnyRadix
  $ repQtySmartly rndrer (fmap (fmap snd) rndgs) cy qt
  where
    rndrer = maybe (Right Nothing) id . _renderer $ opts

makeReport
  :: (Loader o l, Ledger l, Report r)
  => ClatchOptions l r o
  -> IO AllChunks
makeReport opts = loadChunks act (_opener opts)
  where
    act = do
      ((msgsPre, rndgs, msgsPost), cltchs) <-
        allClatches (opts ^. converter . _Wrapped')
                    (_filterer . _pre $ opts)
                    (_sorter opts) (_filterer . _post $ opts)
      let cks = printReport (_reporter opts) (smartRender opts rndgs)
                             cltchs
      return (msgsToChunks msgsPre, msgsToChunks msgsPost, cks)

clatcher
  :: (Loader o l, Ledger l, Report r)
  => ClatchOptions l r o
  -> IO ()
clatcher opts = do
  (msgsPre, msgsPost, cksRpt) <- makeReport opts
  feedStream (opts ^. pre . streamer) msgsPre $
    feedStream (opts ^. post . streamer) msgsPost $
    feedStream (opts ^. report) cksRpt $
    return ()
