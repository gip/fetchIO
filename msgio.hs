{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module MsgIO where

import Data.List as L
import Data.Text (Text,strip,splitOn)
import Data.Aeson
import Data.Maybe
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
-- Input
--
data Header = Header { field :: Text, value :: Text } deriving (Generic, Show)

data MsgIn = MsgIn {
  fetch_url :: Maybe Text,
  fetch_urls :: Maybe Text,
  fetch_headers :: Maybe [Header],
  fetch_routing_key :: Text
} deriving (Generic, Show)


instance FromJSON Header
instance FromJSON MsgIn
instance ToJSON Header
instance ToJSON MsgIn

getHeaders mi = map (\h -> (CI.mk (encodeUtf8 $ field h), encodeUtf8 $ value h)) (case fetch_headers mi of Nothing -> [] 
                                                                                                           Just a -> a)

getURLs mi =
  if(isJust $ fetch_url mi) then (fromJust $ fetch_url mi) : []
  	                        else map strip (splitOn " " (fromJust $ fetch_urls mi))


--
-- Output Message
-- 

data MString = MString (Either String BL.ByteString) deriving(Show)

instance ToJSON MString where
  toJSON (MString (Right t)) = toJSON $ (B64.encode (B.concat (BL.toChunks (Z.compress t))))
  toJSON (MString (Left t)) = toJSON t

data MsgOut = MsgOut {
  fetch_data :: Maybe MString,
  fetch_latency :: Maybe Int,
  fetch_status_code :: Maybe Int,
  fetch_proxy :: Maybe Text,
  fetch_time :: Maybe Integer,
  fetch_redirect :: Maybe Text,
  fetch_response_array :: Maybe [MsgOut]
} deriving(Generic, Show)

instance ToJSON MsgOut

msgOut = MsgOut {
  fetch_data = Nothing,
  fetch_latency = Nothing,
  fetch_status_code = Nothing,
  fetch_proxy = Nothing,
  fetch_time = Nothing,
  fetch_redirect = Nothing,
  fetch_response_array = Nothing
}


--
-- Config
--

data CfgHost = CfgHost {
  host :: Maybe Text,
  port :: Maybe Int,
  user :: Maybe Text,
  password :: Maybe Text
} deriving(Generic, Show)

instance FromJSON CfgHost

getHostInfo c = 
  (fromMaybe "localhost" $ host c,
   fromMaybe 80 $ port c,           
   user c, password c)


data CfgHostGroup =CfgHostGroup {
  group :: Text,
  hosts :: [CfgHost]
} deriving(Generic, Show)

instance FromJSON CfgHostGroup

data CfgPipeline = CfgPipeline {
  amqp_in_hosts :: Text,
  amqp_out_hosts :: Text,
  amqp_in_queue :: Text,
  amqp_out_exchange :: Text,
  http_hosts :: Text,
  http_min_delay :: Maybe Int
} deriving(Generic, Show)

instance FromJSON CfgPipeline

data CfgTop = CfgTop {
  name :: Text,
  groups :: Maybe [CfgHostGroup],
  pipelines :: [CfgPipeline]
} deriving(Generic, Show)

instance FromJSON CfgTop

getHostGroup :: CfgTop -> Text -> Maybe CfgHostGroup
getHostGroup cfg g = join (liftM (L.find (\hg -> MsgIO.group hg == g)) $ groups cfg)
  
copyFields (Object o0) (Object o1) = Object (HM.union o0 o1)
  


