module Composite.Aeson.Formats.Generic
  ( abeJsonFormat, aesonJsonFormat, jsonArrayFormat, jsonObjectFormat
  , SumStyle(..), jsonSumFormat
  ) where

import Composite.Aeson.Base (JsonFormat(JsonFormat), JsonProfunctor(JsonProfunctor), FromJson(FromJson))
import Control.Arrow (second)
import Control.Lens (_Wrapped, over, unsnoc)
import Data.Aeson (FromJSON, ToJSON, (.=), toJSON)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.BetterErrors as ABE
import qualified Data.HashMap.Strict as StrictHashMap
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NEL
import Data.Monoid ((<>))
import Data.Text (Text, intercalate, unpack)
import qualified Data.Vector as Vector

-- |Produce an explicit 'JsonFormat' by using the implicit Aeson 'ToJSON' instance and an explicit @aeson-better-errors@ 'ABE.Parse'.
abeJsonFormat :: ToJSON a => ABE.Parse e a -> JsonFormat e a
abeJsonFormat p = JsonFormat $ JsonProfunctor toJSON p

-- |Produce an explicit 'JsonFormat' by using the implicit Aeson 'FromJSON' and 'ToJSON' instances.
--
-- If an @aeson-better-errors@ parser is available for @a@, it's probably better to use 'abeJsonFormat' to get the enhanced error reporting.
aesonJsonFormat :: (ToJSON a, FromJSON a) => JsonFormat e a
aesonJsonFormat = JsonFormat $ JsonProfunctor toJSON ABE.fromAesonParser


-- |'JsonFormat' for any type which can be converted to/from a list which maps to a JSON array.
jsonArrayFormat :: (t -> [a]) -> ([a] -> ABE.Parse e t) -> JsonFormat e a -> JsonFormat e t
jsonArrayFormat oToList iFromList =
  over _Wrapped $ \ (JsonProfunctor o i) ->
    JsonProfunctor (Aeson.Array . Vector.fromList . map o . oToList)
                   (ABE.eachInArray i >>= iFromList)

-- |'JsonFormat' for any type which can be converted to/from a list of pairs which maps to a JSON object.
jsonObjectFormat :: (t -> [(Text, a)]) -> ([(Text, a)] -> ABE.Parse e t) -> JsonFormat e a -> JsonFormat e t
jsonObjectFormat oToList iFromList =
  over _Wrapped $ \ (JsonProfunctor o i) ->
    JsonProfunctor (Aeson.Object . StrictHashMap.fromList . map (second o) . oToList)
                   (ABE.eachInObject i >>= iFromList)


-- Describes how a sum format should map to JSON.
--
-- Summary of the styles:
--
--   * 'SumStyleFieldName' represents alternate sum branches as different mutually exclusive fields in an object, e.g. @{ "first": 123 }@.
--   * 'SumStyleTypeValue' represents alternate sum branches as different two-field objects, e.g. @{ "type": "first", "value": 123 }@.
--   * 'SumStyleMergeType' represents alternate sum branches by an intrinsic type field and only works with objects, e.g. @{ "type": "first", "a": 123 }@
--
-- Given:
--
-- @
--   data MySum
--     = SumFirst Int
--     | SumSecond String
--
--   mySumFormat :: 'SumStyle' -> 'JsonFormat' e MySum
--   mySumFormat style = jsonSumFormat style o i
--     where
--       o = \ case
--         SumFirst  i -> ("first",  'toJsonWithFormat' 'intJsonFormat'    i)
--         SumSecond s -> ("second", 'toJsonWithFormat' 'stringJsonFormat' s)
--       i = \ case
--         "first"  -> SumFirst  <$> 'parseJsonWithFormat' 'intJsonFormat'
--         "second" -> SumSecond <$> 'parseJsonWithFormat' 'stringJsonFormat'
-- @
--
-- For 'SumStyleFieldName', the object will always have a single field whose name is determined by which element of the sum it represents. For example:
--
-- @
--   toJsonWithFormat (mySumFormat SumStyleFieldName) (SumFirst 123)
-- @
--
-- will yield
--
-- @
--   { "first": 123 }
-- @
--
-- For @'SumStyleTypeValue' typeField valueField@, the object will have two fields @typeField@ and @valueField@, the former determining the format of the
-- latter. For example:
--
-- @
--   toJsonWithFormat (mySumFormat (SumStyleTypeValue "typ" "val")) (SumFirst 123)
-- @
--
-- will yield
--
-- @
--   { "typ": "first", "val": 123 }
-- @
--
-- For @'SumStyleMergeType' typeField@, its expected that every branch of the sum maps to an object in JSON, and the sum will add a new field @typeField@
-- to the object. It's fundamentally a bit dangerous as the assertion that each branch maps as an object is not enforced in the type system, so errors will
-- be produced at runtime. The previously given example can't be used as both branches (@Int@ and @String@) map to JSON values other than objects.
--
-- Given:
--
-- @
--   data FirstThing = FirstThing { a :: Int, b :: String }
--   firstThingJsonFormat = ... -- maps as { a: 123, b: "foo" }
--
--   data MySum
--     = SumFirst FirstThing
--     | ...
--
--   mySumFormat :: 'SumStyle' -> 'JsonFormat' e MySum
--   mySumFormat style = jsonSumFormat style o i
--     where
--       o = \ case
--         SumFirst ft -> ("first", 'toJsonWithFormat' 'firstThingJsonFormat' ft)
--         ...
--       i = \ case
--         "first"  -> SumFirst <$> 'parseJsonWithFormat' 'firstThingJsonFormat'
--         ...
-- @
--
-- Then
--
-- @
--   toJsonWithFormat (SumStyleMergeType "typ") (SumFirst (FirstThing 123 "abc"))
-- @
--
-- will yield
--
-- @
--   { "typ": "first", "a": 123, "b": "abc" }
-- @
--
-- __Warning:__ (again) that 'SumStyleMergeType' will trigger __run time errors__ (ala @error@) when converting to JSON if any of the sum branches yields
-- something that isn't an object. It will also yield a run time error if that object already contains a conflicting field.
data SumStyle
  = SumStyleFieldName
  -- ^Map to a single-field object with the field name determined by the sum branch and the field value being the encoded value for that branch.
  | SumStyleTypeValue Text Text
  -- ^Map to a two-field object with fixed field names, the first being the type field and the second beind the value field.
  | SumStyleMergeType Text
  -- ^Given that each sum branch maps to a JSON object, add/parse an additional field to that object with the given name.

-- |Helper used by the various sum format functions which takes a list of input format pairs and makes an oxford comma list of them.
expectedFieldsForInputs :: NonEmpty (Text, x) -> String
expectedFieldsForInputs ((f, _) :| rest) =
  case unsnoc rest of
    Just (prefix, (fLast, _)) -> unpack $ f <> ", " <> intercalate ", " (map fst prefix) <> ", or " <> fLast
    Nothing                   -> unpack f

-- |'JsonFormat' which maps sum types to JSON according to 'SumStyle', given a pair of functions to decompose and recompose the sum type.
jsonSumFormat :: SumStyle -> (a -> (Text, Aeson.Value)) -> NonEmpty (Text, FromJson e a) -> JsonFormat e a
jsonSumFormat = \ case
  SumStyleFieldName     -> jsonFieldNameSumFormat
  SumStyleTypeValue t v -> jsonTypeValueSumFormat t v
  SumStyleMergeType t   -> jsonMergeTypeSumFormat t

-- |'JsonFormat' which maps sum types to JSON in the 'SumStyleFieldName' style.
jsonFieldNameSumFormat :: (a -> (Text, Aeson.Value)) -> NonEmpty (Text, FromJson e a) -> JsonFormat e a
jsonFieldNameSumFormat oA iAs =
  JsonFormat (JsonProfunctor o i)
  where
    expected = expectedFieldsForInputs iAs
    o a = let (t, v) = oA a in Aeson.object [t .= v]
    i = do
      fields <- ABE.withObject $ pure . StrictHashMap.keys
      case fields of
        [f] ->
          case lookup f (NEL.toList iAs) of
            Just (FromJson iA) -> ABE.key f iA
            Nothing -> fail $ "unknown field " <> unpack f <> ", expected one of " <> expected
        [] ->
          fail $ "expected an object with one field (" <> expected <> ") not an empty object"
        _ ->
          fail $ "expected an object with one field (" <> expected <> ") not many fields"


-- |'JsonFormat' which maps sum types to JSON in the 'SumStyleTypeValue' style.
jsonTypeValueSumFormat :: Text -> Text -> (a -> (Text, Aeson.Value)) -> NonEmpty (Text, FromJson e a) -> JsonFormat e a
jsonTypeValueSumFormat typeField valueField oA iAs =
  JsonFormat (JsonProfunctor o i)
  where
    expected = expectedFieldsForInputs iAs
    o a = let (t, v) = oA a in Aeson.object [typeField .= t, valueField .= v]
    i = do
      t <- ABE.key typeField ABE.asText
      case lookup t (NEL.toList iAs) of
        Just (FromJson iA) -> ABE.key valueField iA
        Nothing -> fail $ "expected " <> unpack typeField <> " to be one of " <> expected

-- |'JsonFormat' which maps sum types to JSON in the 'SumStyleMergeType' style.
jsonMergeTypeSumFormat :: Text -> (a -> (Text, Aeson.Value)) -> NonEmpty (Text, FromJson e a) -> JsonFormat e a
jsonMergeTypeSumFormat typeField oA iAs =
  JsonFormat (JsonProfunctor o i)
  where
    expected = expectedFieldsForInputs iAs
    o a = case oA a of
      (t, Aeson.Object fields) | StrictHashMap.member typeField fields ->
        error $ "PRECONDITION VIOLATED: encoding a value with merge type sum style yielded "
             <> "(" <> unpack t <> ", " <> show (Aeson.Object fields) <> ") which already contains the field " <> unpack typeField
      (t, Aeson.Object fields) ->
        Aeson.Object (StrictHashMap.insert typeField (Aeson.String t) fields)
      (t, other) ->
        error $ "PRECONDITION VIOLATED: encoding a value with merge type sum style yielded "
             <> "(" <> unpack t <> ", " <> show other <> ") which isn't an object"
    i = do
      t <- ABE.key typeField ABE.asText
      case lookup t (NEL.toList iAs) of
        Just (FromJson iA) -> iA
        Nothing -> fail $ "expected " <> unpack typeField <> " to be one of " <> expected
