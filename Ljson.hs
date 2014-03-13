-- 
-- Ljson implements a simple JSON with links (starting with '$link:')
--
-- { "abc" : v, "field1" : "v1", "field2" : "$link:abc" }  where v is whatever JSON value
-- will become { "abc" : "efg", "field1" : "v1", "field2" : v } 

module Ljson(Ljson.decode, Ljson.encode, Value, merge, toJSON) where

import Data.ByteString.Lazy
import Data.Text as T
import qualified Data.HashMap.Strict as HM
import qualified Data.Vector as V
import Data.Aeson as A
import Data.Maybe
import Data.Traversable as DT
import Control.Monad


merge (Object o0) (Object o1) = Object (HM.union o0 o1)

encode :: (ToJSON a) => a -> ByteString
encode = A.encode

-- decode bs decode ByteString bs to a JSON Value
--
decode :: (Monad m, FromJSON a) => ByteString -> m a
decode bs = do
  v <- case A.decode bs of Just x -> return x
                           _ -> fail "Invalid JSON"          
  r <- trans v
  case fromJSON r of Success y -> return y
                     _ -> fail "Wrong format, cannot match value"


-- replace the links in a JSON Value
-- Links are "$link:name"
--
trans :: Monad m => Value -> m Value
trans j = trans' j
  where
    d = flip dict $ j
    trans' (Object o) = liftM Object $  DT.mapM trans' o
    trans' (Array a) = liftM Array $ DT.mapM trans' a
    trans' ss@(String s) =
      if T.take 6 s == "$link:" then get $ T.drop 6 s else return ss 
    trans' x = return x
    get k = case d k of Just x -> return x
                        Nothing -> fail ("Key '" ++ T.unpack k ++ "' not found")


-- dict k v searches for the key k
--
dict :: Text -> Value -> Maybe Value
dict k v = dict' v
  where
    dict' (Object hm) = case HM.lookup k hm of r@(Just _) -> r
                                               Nothing -> first dict' (Prelude.map snd $ HM.toList hm) -- HM.toList is lazy
    dict' (Array v) = first dict' (V.toList v)
    dict' _ = Nothing

first f (l:ls) = case f l of x@(Just _) -> x
                             Nothing -> first f ls
first f [] = Nothing

