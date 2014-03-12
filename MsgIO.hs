module MsgIO where

import Types

import Data.List as L
import Data.Text (Text,strip,splitOn)
import Data.Text.Encoding
import Data.Aeson
import Data.Maybe
import Data.String.Conversions

import qualified Data.HashMap.Strict as HM
import Data.Text.Encoding
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.ByteString.Base64 as B64
import GHC.Generics
import qualified Codec.Compression.Zlib as Z
import Control.Monad
import qualified Data.CaseInsensitive as CI

--
-- Input Message
--
--data Header = Header { field :: Text, value :: Text } deriving (Generic, Show)

data MsgIn = MsgIn {
  fetch_url :: Maybe Text,
  fetch_urls :: Maybe Text,
  fetch_headers :: Maybe [Header],
  fetch_routing_key :: Text,
  top_level :: Maybe Value            -- The full input message
} deriving (Generic, Show)

instance FromJSON Header
instance FromJSON MsgIn 
instance ToJSON Header
instance ToJSON MsgIn

getHeaders mi = case fetch_headers mi of Nothing -> [] 
                                         Just a -> a

getURLs mi =
  if(isJust $ fetch_url mi) then (fromJust $ fetch_url mi) : []
  	                        else filter (\s -> s /= "") $ map strip (splitOn " " (fromJust $ fetch_urls mi))


class Monad m => Connector m a c | m a -> c where
  newConnection :: a -> m c 

class (Monad m, Connector m a c)  => Source m a c r | m c r -> a where
  pop :: c -> m (Maybe (r, Bool -> m ()))

class (Monad m, Connector m a c) => Dest m a c k r | m c r k -> a where
  push :: c -> k -> r -> m ()

--
-- Output Message
-- 

data MString = MString (Either String BL.ByteString) deriving(Show)

instance ToJSON MString where
  toJSON (MString (Right t)) = toJSON $ decodeUtf8 (B64.encode (cs (Z.compress t)))
  toJSON (MString (Left t)) = toJSON t

data MsgOut = MsgOut {
  fetch_data :: Maybe MString,
  fetch_data_1 :: Maybe MString,
  fetch_data_2 :: Maybe MString,
  fetch_data_3 :: Maybe MString, 
  fetch_latency :: Maybe Int,
  fetch_status_code :: Maybe Int,
  fetch_proxy :: Maybe Endpoint,
  fetch_time :: Maybe Integer,
  fetch_redirect :: Maybe Text
} deriving(Generic, Show)

instance ToJSON MsgOut

msgOut = MsgOut {
  fetch_data = Nothing,
  fetch_data_1 = Nothing,
  fetch_data_2 = Nothing,
  fetch_data_3 = Nothing,
  fetch_latency = Nothing,
  fetch_status_code = Nothing,
  fetch_proxy = Nothing,
  fetch_time = Nothing,
  fetch_redirect = Nothing
}


--
-- Config
--

instance FromJSON Endpoint
instance ToJSON Endpoint

data CfgPipeline = CfgPipeline {
  amqp_in_host :: Endpoint,
  amqp_out_host :: Endpoint,
  amqp_in_queue :: Text,
  amqp_out_exchange :: Text,
  http_proxys :: [[Endpoint]],
  http_min_delay :: Maybe Int,
  http_start_delay :: Maybe Int
} deriving(Generic, Show)

instance FromJSON CfgPipeline

data CfgTop = CfgTop {
  name :: Text,
  pipelines :: [CfgPipeline]
} deriving(Generic, Show)

instance FromJSON CfgTop
 
