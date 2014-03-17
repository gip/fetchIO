module Types where

import Data.Text
import Data.ByteString
import qualified Data.ByteString.Lazy as BL

import GHC.Generics

data Header = Header { field :: Text, value :: Text } deriving (Generic, Show)

data Endpoint = Endpoint { host :: Maybe Text,
                           port :: Maybe Int,
                           user :: Maybe Text,
                           pass :: Maybe Text 
                         } deriving (Generic,Eq)

instance Show Endpoint where
  show ep = Prelude.concat ["{host = ", show $ host ep, ", port = ", show $ port ep, 
                            ", user = ", show $ f (user ep), ", pass = ", show $ f (pass ep), "}"]
    where
      f (Just _) = "<redacted>"
      f _ = "<none>" 

getHost (Endpoint (Just h) _ _ _) = h
getHost (Endpoint Nothing _ _ _) = "localhost"
