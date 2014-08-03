{-# LANGUAGE RankNTypes, NoImplicitPrelude #-}
module Penny.Numbers.Abstract.Aggregates.Generators where

import Penny.Numbers.Abstract.Aggregates
import Penny.Numbers.Abstract.Unpolar.Generators
import Penny.Numbers.Abstract.RadGroup
import Penny.Numbers.Abstract.RadGroup.Generators
import Penny.Numbers.Qty
import Penny.Numbers.Qty.Generators
import Data.Sums.Generators
import Test.QuickCheck
import Control.Monad
import Prelude.Generators
import Prelude hiding (either)
import Data.Sums

polarity
  :: (Int, Gen n)
  -> (Int, Gen (o, p))
  -> Gen (Polarity n o p)
polarity (fn, gn) (fo, go) =
  frequency [(fn, fmap Center gn), (fo, fmap (uncurry OffCenter) go)]

ungroupedZero
  :: Gen (Radix r)
  -> Gen (UngroupedZero r)
ungroupedZero r = fmap UngroupedZero $
  s2 (1, uZZeroOnly) (1, (uZTrailing r))

ungroupedNonZero
  :: Gen (Radix r)
  -> Gen (UngroupedNonZero r)
ungroupedNonZero r = fmap UngroupedNonZero $
  s3 (1, uNWhole) (1, (uNWholeRadix r)) (1, (uNRadFrac r))

ungroupedUnpolar
  :: Gen (Radix r)
  -> Gen (UngroupedUnpolar r)
ungroupedUnpolar r = fmap UngroupedUnpolar $
  s2 (1, ungroupedZero r) (1, ungroupedNonZero r)

ungroupedPolar
  :: Gen p
  -> Gen (Radix r)
  -> Gen (UngroupedPolar r p)
ungroupedPolar p r = fmap UngroupedPolar $ polarity (1, ungroupedZero r)
  (3, liftM2 (,) (ungroupedNonZero r) p)

groupedNonZero
  :: Gen (Radix r)
  -> (forall a. Gen (a -> Group r a))
  -> Gen (GroupedNonZero r)
groupedNonZero r g = fmap GroupedNonZero $
  s5 (1, masunoGroupedLeft g) (1, masunoGroupedLeftRad r g)
     (1, masunoGroupedRight r g) (1, fracunoFirstGroupZ r g)
     (1, fracunoFirstGroupNZ r g)

groupedUnpolar
  :: Gen (Radix r)
  -> (forall a. Gen (a -> Group r a))
  -> Gen (GroupedUnpolar r)
groupedUnpolar r g = fmap GroupedUnpolar $
  s2 (1, gZ r g) (1, groupedNonZero r g)

groupedPolar
  :: Gen p
  -> Gen (Radix r)
  -> (forall a. Gen (a -> Group r a))
  -> Gen (GroupedPolar r p)
groupedPolar p r g = fmap GroupedPolar $
  polarity (1, gZ r g) (3, (liftM2 (,) (groupedNonZero r g) p))

unpolar
  :: Gen (Radix r)
  -> (forall a. Gen (a -> Group r a))
  -> Gen (Unpolar r)
unpolar r g = fmap Unpolar $
  s2 (1, (ungroupedUnpolar r)) (1, (groupedUnpolar r g))

polar
  :: Gen p
  -> Gen (Radix r)
  -> (forall a. Gen (a -> Group r a))
  -> Gen (Polar r p)
polar p r g = fmap Polar $
  s2 (1, (ungroupedPolar p r)) (1, (groupedPolar p r g))

abstract
  :: Gen p
  -> Gen (Radix r)
  -> (forall a. Gen (a -> Group r a))
  -> Gen (Abstract r p)
abstract p r g = fmap Abstract $
  s2 (1, (unpolar r g)) (3, (polar p r g))

unpolarPeriod :: Gen (Unpolar Period)
unpolarPeriod = unpolar (return radPeriod) groupPeriod

unpolarComma :: Gen (Unpolar Comma)
unpolarComma = unpolar (return radComma) groupComma

unpolarEitherRadix :: Gen (Either (Unpolar Period) (Unpolar Comma))
unpolarEitherRadix = either unpolarPeriod unpolarComma

polarPeriodSide :: Gen (Polar Period Side)
polarPeriodSide = polar side (return radPeriod) groupPeriod

polarCommaSide :: Gen (Polar Comma Side)
polarCommaSide = polar side (return radComma) groupComma

polarEitherRadix :: Gen (Either (Polar Period Side) (Polar Comma Side))
polarEitherRadix = either polarPeriodSide polarCommaSide

-- | Generates a Polar that is non-zero.
polarNonZero :: Gen (Either (Polar Period Side) (Polar Comma Side))
polarNonZero = polarEitherRadix `suchThat` pd
  where
    pd ei = case ei of
      Left (Polar s2) -> case s2 of
