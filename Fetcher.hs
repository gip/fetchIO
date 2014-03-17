module Fetcher where

import Types

import Data.Text
import Data.ByteString
import qualified Data.ByteString.Lazy as BL

import Control.Monad.Error

-- For the exception modeil, refer to http://www.haskell.org/haskellwiki/Exception

data FetcherException =
  Other String

data FetchException = FetchException { fatal::Bool, exception::String, info::String } 
  deriving (Show)
  
instance Error FetcherException
instance Error FetchException

-- ErrorT e m a, with e the error type and m the inner monad (IO)

class Fetcher m c | m -> c where
  newManager :: ErrorT FetcherException m c
  closeManager :: c -> ErrorT FetcherException m ()
  fetch :: c
        -> Endpoint                                                                                -- Proxy - could be localhost
        -> String                                                                                  -- URL to fetch
        -> [Header]                                                                                -- Headers
        -> Maybe Int                                                                               -- Timeout (us)
        -> ErrorT FetchException m (Int, Maybe BL.ByteString, Int, Integer, Maybe String)          -- (Http code, response, latency, timestamp, redirect)

