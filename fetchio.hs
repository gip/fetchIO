{-# LANGUAGE OverloadedStrings #-}

module Main where

import MsgIO

import Data.Text.Encoding
import Data.Maybe
import Data.Aeson
import Data.Text as T hiding(map)
--import Data.Text.Lazy.Encoding
import System.Time
import Network
import Network.AMQP
import Network.AMQP.Types
import Data.Conduit
import Network.HTTP.Types.Status
import Network.HTTP.Conduit as C
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS
import Control.Exception
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TChan
import Control.Monad(when, liftM)
import Control.Applicative ((<$>))
import System.Environment


-- (ThreadId, Eihter String Int)

data Level = Err | Info deriving (Show)

output l m = putStrLn ("fetchio: " ++ (p l) ++ ": " ++ m)
  where p Err = "error"
        p Info = "info"

logger m = do
  t <- getClockTime
  putStrLn $ "[" ++ (show t) ++ "] " ++ m

main = do
  args <- getArgs
  catchAny (do
    cfg <- (liftM $ decode) (BL.readFile $ Prelude.head args)
    if isJust cfg 
    then
      let cfg' = fromJust cfg in
      start cfg'
    else
      output Err "couldn't read configuration") (\_ -> output Err "usage: fetchio <configuration file>")
  return ()

start cfg = do 
  tchan <- atomically $ newTChan
  mapM_ (startP tchan) $ pipelines cfg
  where
    allHost hg = map getHostInfo (hosts (fromJust $ getHostGroup cfg hg))
    firstHost hg = getHostInfo $ (Prelude.head $ hosts (fromJust $ getHostGroup cfg hg))
    startP tc pipe = do
      let in_c = firstHost (amqp_in_hosts pipe)
      let out_c = firstHost (amqp_out_hosts pipe)
      let h = allHost (http_hosts pipe)
      mapM_ (forkIO . simpleFetch tc in_c out_c (amqp_in_queue pipe) (amqp_out_exchange pipe) (http_min_delay pipe)) h
      waitFor tc
      return () -- Dead

waitFor tc = do 
  threadDelay 100000
  handle
  waitFor tc
  where
    handle = do 
      s <- atomically $ Main.tryReadTChan tc
      if(isJust s)
      then do
        putStrLn (fromJust s)
        handle
      else
        return ()


simpleFetch tchan
            in_c@(in_h, in_p, in_login, in_passw)       -- AMQP host
            out_c@(out_h, out_p, out_login, out_passw)
            qin                    -- Queue in
            eout                   -- Queue out
            wait
            proxy                  -- Proxy host (Maybe)
            = do
  logger ("Starting pipeline with params: " ++ (show qin) ++ " - " ++ (show eout) ++ " - " ++ (show proxy)) 
  conn <- openConnection (T.unpack in_h) "/" (fromMaybe "" in_login) (fromMaybe "" in_passw)
  chan <- openChannel conn
  chano <- if in_c == out_c 
           then
             openChannel conn  -- We create a new channel
           else do
           	  conno <- openConnection (T.unpack out_h) "/" (fromMaybe "" out_login) (fromMaybe "" out_passw)
           	  openChannel conno
  mng <- newManager $ def { managerResponseTimeout = Just 15000000 }
  loop chan chano mng
  return ()
  where
    loop c co mng = do
        catchAny (iter c co qin eout mng proxy) (\e -> do { atomically (writeTChan tchan $ show e); return () })
        when(isJust wait) (threadDelay $ 1000 * fromJust wait)
        loop c co mng



iter cin cout qi eo mng proxy = do
  r <- pop cin qi
  when(isJust r) $ do let (mi,tag, rraw) = fromJust r in
  	                  catchAny (doit mi rraw tag) (\e -> do { putStrLn $ show e ;rejectMsg cin tag True} )
  return ()
  where 
  	doit mi rraw tag = do
        let url = (T.unpack . fromJust $ fetch_url mi)
        let proxys = Just $ (\(h,p,_,_) -> T.concat [h, ":", T.pack $ show p]) $ proxy
        logger $ "Fetching " ++ url ++ ", " ++ (show proxys)
        (code,r,dt,ts,redirect) <- fetch proxy mng url (getHeaders mi)
        let mo = MsgOut { fetch_data = if(code==200) then Just $ MString (Right $ responseBody r) else Nothing, 
                          fetch_status_code = Just code,
                          fetch_latency = Just dt,
                          fetch_proxy = proxys,
                          fetch_time = Just ts,
                          fetch_redirect = fmap decodeUtf8 redirect }
        logger $ "Fetched " ++ url ++ ", " ++ (show proxys) ++ ", status " ++ (show $ code) ++ ", latency " ++ (show dt)
        let rk = T.concat [fetch_routing_key mi, ":", T.pack $ show code]
        let msg = newMsg { msgBody = encode $ copyFields (toJSON mo) (fromJust $ decode rraw) } -- TODO: Improve that
        publishMsg cout eo rk msg
        logger ("Publishing with key " ++ (show rk))
        ackMsg cin tag False

-- Pop a message from AMQP
pop c q = do
  m0 <- getMsg c Ack q
  let r = case m0 of Just(m) -> let (msg,tag) = (\ (a,b) -> (msgBody a, envDeliveryTag b)) m in
                                Just (fromJust (decode msg),tag, msg)
                     Nothing -> Nothing
  return r



-- Simple fetch wo redirect
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
  return (code, r, dt,case t1 of TOD ts _ -> ts, redirect)
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

--
-- Catching all exceptions
--
catchAny :: IO a -> (SomeException -> IO a) -> IO a
catchAny = Control.Exception.catch

-- 
-- This function exists in 7.6 but not 7.4
--
tryReadTChan chan = do
    b <- isEmptyTChan chan
    if b then return Nothing else Just <$> readTChan chan

