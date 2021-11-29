{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  OpenTelemetry.Attributes
-- Copyright   :  (c) Ian Duncan, 2021
-- License     :  BSD-3
-- Description :  Key-value pair metadata used in 'OpenTelemetry.Trace.Span's, 'OpenTelemetry.Trace.Link's, and 'OpenTelemetry.Trace.Event's
-- Maintainer  :  Ian Duncan
-- Stability   :  experimental
-- Portability :  non-portable (GHC extensions)
--
-- An Attribute is a key-value pair, which MUST have the following properties:
-- 
-- - The attribute key MUST be a non-null and non-empty string.
-- - The attribute value is either:
-- - A primitive type: string, boolean, double precision floating point (IEEE 754-1985) or signed 64 bit integer.
-- - An array of primitive type values. The array MUST be homogeneous, i.e., it MUST NOT contain values of different types. For protocols that do not natively support array values such values SHOULD be represented as JSON strings.
-- - Attribute values expressing a numerical value of zero, an empty string, or an empty array are considered meaningful and MUST be stored and passed on to processors / exporters.
--
-----------------------------------------------------------------------------
module OpenTelemetry.Attributes 
  ( Attributes
  , emptyAttributes
  , addAttribute
  , addAttributes
  , getAttributes
  , lookupAttribute
  , Attribute (..)
  , ToAttribute (..)
  , PrimitiveAttribute (..)
  , ToPrimitiveAttribute (..)
  -- * Attribute limits
  , AttributeLimits (..)
  , defaultAttributeLimits
  -- * Unsafe utilities
  , unsafeAttributesFromListIgnoringLimits
  , unsafeMergeAttributesIgnoringLimits 
  ) where
import Data.Int ( Int64 )
import Data.Text ( Text )
import qualified Data.HashMap.Strict as H
import qualified Data.Text as T
import GHC.Generics
import Data.Data
import Data.Hashable

-- | Default attribute limits used in the global attribute limit configuration if no environment variables are set.
--
-- Values:
--
-- - 'attributeCountLimit': @Just 128@
-- - 'attributeLengthLimit':  or @Nothing@
defaultAttributeLimits :: AttributeLimits
defaultAttributeLimits = AttributeLimits
  { attributeCountLimit = Just 128
  , attributeLengthLimit = Nothing
  }

data Attributes = Attributes
  { attributes :: !(H.HashMap Text Attribute)
  , attributesCount :: {-# UNPACK #-} !Int
  }
  deriving stock (Show, Eq)

emptyAttributes :: Attributes
emptyAttributes = Attributes mempty 0

addAttribute :: ToAttribute a => AttributeLimits -> Attributes -> Text -> a -> Attributes
addAttribute AttributeLimits{..} attrs@Attributes{..} k v = case attributeCountLimit of
  Nothing -> Attributes newAttrs newCount
  Just limit_ -> if newCount > limit_
    then attrs
    else Attributes newAttrs newCount
  where
    newAttrs = H.insert k (limitLengths $ toAttribute v) attributes
    newCount = if H.member k attributes
      then attributesCount
      else attributesCount + 1

    limitPrimAttr limit_ (TextAttribute t) = TextAttribute (T.take limit_ t)
    limitPrimAttr _ attr = attr

    limitLengths attr = case attributeLengthLimit of
      Nothing -> attr
      Just limit_ -> case attr of
        AttributeValue val -> AttributeValue $ limitPrimAttr limit_ val
        AttributeArray arr -> AttributeArray $ fmap (limitPrimAttr limit_) arr
        
{-# INLINE addAttribute #-}

addAttributes :: ToAttribute a => AttributeLimits -> Attributes -> [(Text, a)] -> Attributes
-- TODO, this could be done more efficiently
addAttributes limits = foldl (\attrs' (k, v) -> addAttribute limits attrs' k v)
{-# INLINE addAttributes #-}

getAttributes :: Attributes -> (Int, H.HashMap Text Attribute)
getAttributes Attributes{..} = (attributesCount, attributes)

lookupAttribute :: Attributes -> Text -> Maybe Attribute
lookupAttribute Attributes{..} k = H.lookup k attributes

-- | It is possible when adding attributes that a programming error might cause too many
-- attributes to be added to an event. Thus, 'Attributes' use the limits set here as a safeguard
-- against excessive memory consumption.
--
-- See 'getAttributeLimits' and 'setAttributeLimits' to alter these.
data AttributeLimits = AttributeLimits
  { attributeCountLimit :: Maybe Int
  -- ^ The number of unique attributes that may be added to an 'Attributes' structure before they are dropped.
  , attributeLengthLimit :: Maybe Int
  -- ^ The maximum length of string attributes that may be set. Longer-length string values will be truncated to the
  -- specified amount.
  }
  deriving stock (Read, Show, Eq, Ord, Data, Generic)
  deriving anyclass (Hashable)

class ToPrimitiveAttribute a where
  toPrimitiveAttribute :: a -> PrimitiveAttribute

data Attribute
  = AttributeValue PrimitiveAttribute
  | AttributeArray [PrimitiveAttribute]
  deriving stock (Read, Show, Eq, Ord, Data, Generic)
  deriving anyclass (Hashable)

data PrimitiveAttribute
  = TextAttribute Text
  | BoolAttribute Bool
  | DoubleAttribute Double
  | IntAttribute Int64
  deriving stock (Read, Show, Eq, Ord, Data, Generic)
  deriving anyclass (Hashable)


class ToAttribute a where
  toAttribute :: a -> Attribute
  default toAttribute :: ToPrimitiveAttribute a => a -> Attribute
  toAttribute = AttributeValue . toPrimitiveAttribute

instance ToPrimitiveAttribute PrimitiveAttribute where
  toPrimitiveAttribute = id

instance ToAttribute PrimitiveAttribute where
  toAttribute = AttributeValue

instance ToPrimitiveAttribute Text where
  toPrimitiveAttribute = TextAttribute
instance ToAttribute Text

instance ToPrimitiveAttribute Bool where
  toPrimitiveAttribute = BoolAttribute
instance ToAttribute Bool

instance ToPrimitiveAttribute Double where
  toPrimitiveAttribute = DoubleAttribute
instance ToAttribute Double

instance ToPrimitiveAttribute Int64 where
  toPrimitiveAttribute = IntAttribute
instance ToAttribute Int64

instance ToPrimitiveAttribute Int where
  toPrimitiveAttribute = IntAttribute . fromIntegral
instance ToAttribute Int

instance ToAttribute Attribute where
  toAttribute = id

instance ToPrimitiveAttribute a => ToAttribute [a] where
  toAttribute = AttributeArray . map toPrimitiveAttribute

unsafeMergeAttributesIgnoringLimits :: Attributes -> Attributes -> Attributes
unsafeMergeAttributesIgnoringLimits (Attributes l lc) (Attributes r rc) = Attributes (l <> r) (lc + rc)

unsafeAttributesFromListIgnoringLimits :: [(Text, Attribute)] -> Attributes
unsafeAttributesFromListIgnoringLimits l = Attributes hm c
  where
    hm = H.fromList l
    c = H.size hm