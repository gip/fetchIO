-- A Fetcher module built on top of Http.Conduit
--
module FetcherHttpConduit where


import Types
import Fetcher

import Data.Conduit
import Data.Text(Text)
import Data.Maybe
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.String.Conversions
import qualified Data.CaseInsensitive as CI

import Network.HTTP.Types.Status
import Network.HTTP.Conduit as C
import Network.HTTP.Types.Header
import Network.TLS
import Network.HTTP.Types.Status
import Network.Connection

import System.Time
import System.Timeout
import Control.Monad.Trans.Resource
import Control.Exception as CE
import Control.Monad.Error       -- Using monads-tf

instance Fetcher IO Manager where
  newManager = lift $ C.newManager $ mkManagerSettings settings Nothing
    where settings= TLSSettingsSimple { settingDisableCertificateValidation= True
                                      , settingDisableSession= True
                                      , settingUseServerName= True
                                      }
  closeManager mng = lift $ C.closeManager mng
  fetch mng proxy url he to = fetchIO mng proxy url he to


-- Between IO and ErrorT
--
fetchIO mng proxy url he to = do -- In the error monad
  r <- liftIO $ catches v handlers
  case r of Right v -> return v      
            Left e -> throwError e  
  where v = do                   -- In the IO monad
          v0 <- case to of Just t -> timeout t $ fetchIO' mng proxy url he
                           Nothing -> (liftM Just) $ fetchIO' mng proxy url he
          case v0 of Just a -> return $ Right a
                     Nothing -> return $ Left $ FetchException False "Timeout" url
        handlers = map (\f -> Handler (\e -> return $ Left $ f e) ) h
        h = [ \(e::HttpException) -> 
                case e of C.InvalidUrlException _ _ -> FetchException True (show e) url
                          C.HandshakeFailed -> FetchException False (show e) url
                          TlsException ee -> FetchException True (show ee) url
                          _ -> FetchException False (show e) url
            ]

-- In the IO monad
--
fetchIO' mng proxy url he = do
  req <- parseUrl url 
  t0 <- getClockTime
  let req0 = req { checkStatus = \_ _ _-> Nothing, redirectCount = 0 }
  let req1 = case proxy of Endpoint Nothing            Nothing   _       _       -> req0
                           Endpoint (Just "localhost") Nothing   _       _       -> req0
                           Endpoint (Just "localhost") (Just 80) _       _       -> req0
                           Endpoint mh                  mp       _       _       -> addProxy (cs $ fromMaybe "localhost" mh) (fromMaybe 80 mp) req0
  let req2 = req1 { requestHeaders = headers ++ (requestHeaders req1) }
  let req3 = case proxy of Endpoint _ _ (Just user) (Just pass) -> applyBasicAuth (cs user) (cs pass) req2
                           _ -> req2
  (code, r, redirect) <- fetchF req3 Nothing
  t1 <- getClockTime
  dt <- return $ (toMicros $ diffClockTimes t1 t0) `div` 1000
  return (code, r, dt, case t1 of TOD ts _ -> ts, fmap cs redirect)
  where
    headers = map (\h -> (CI.mk (cs $ field h), cs $ value h)) he
    urlFromRequest r = BS.concat [if secure r then "https://" else "http://", C.host r, C.path r] 
    fetchF req redirect = do
      (code, r, reqredirect) <- runResourceT $ do 
        r' <- httpLbs req mng
        let code' = statusCode $ responseStatus r'
        return (code', Just $ responseBody r', getRedirectedRequest req (responseHeaders r') (responseCookieJar r') code')
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
