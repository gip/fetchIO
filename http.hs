{-# LANGUAGE OverloadedStrings #-}

module Http(fetch) where

import Data.Conduit
import Data.Text
import Data.Text.Encoding
import Data.Maybe
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL

--import Network
import Network.HTTP.Types.Status
import Network.HTTP.Conduit as C
import Network.HTTP.Types.Header

import System.Time

import qualified Data.ByteString as BS

--
-- Fetch with redirect
--
fetch :: (Text, Int, Maybe t, Maybe t1)  -- Proxy - could be localhost
      -> Manager                         -- Http manager
      -> String                          -- URL to fetcg
      -> [Header]                        -- Headers
      -> IO (Int, Response BL.ByteString, Int, Integer, Maybe BS.ByteString)  -- (Http code, response, latency, timestamp, redirect) 
fetch proxy mng url he = do
  req <- parseUrl url 
  t0 <- getClockTime
  let req0 = req { checkStatus = \_ _ _-> Nothing, redirectCount = 0 }
  let req1 = case proxy of ("localhost", 80, Nothing, Nothing) -> req0
                           (h,p, _, _) -> addProxy (encodeUtf8 h) p req0
  let req2 = req1 { requestHeaders = he ++ (requestHeaders req1) }
  -- Fetch
  --r <- runResourceT $ httpLbs req2 mng
  (code, r, redirect) <- fetchF req2 Nothing
  t1 <- getClockTime
  dt <- return $ (toMicros $ diffClockTimes t1 t0) `div` 1000
  return (code, r, dt, case t1 of TOD ts _ -> ts, redirect)
  where
    urlFromRequest r = BS.concat [if secure r then "https://" else "http://", C.host r, C.path r] 
    fetchF req redirect = do
      (code, r, reqredirect) <- runResourceT $ do 
        r' <- httpLbs req mng
        let code' = statusCode $ responseStatus r'
        return (code', r', getRedirectedRequest req (responseHeaders r') (responseCookieJar r') code')
      if isJust reqredirect
      then 
        fetchF (fromJust reqredirect) (Just $ fromJust reqredirect)
      else
        return (code, r, fmap urlFromRequest redirect)

--
-- Micros from TimeDiff
-- 
toMicros :: TimeDiff -> Int
toMicros diff = fromInteger((toPicos diff) `div` 1000000)
  where
    toPicos :: TimeDiff -> Integer
    toPicos (TimeDiff 0 0 0 h m s p) = p + (fromHours h) + (fromMinutes m) + (fromSeconds s)
      where fromSeconds s = 1000000000000 * (toInteger s)
            fromMinutes m = 60 * (fromSeconds m)
            fromHours   h = 60 * (fromMinutes h)