{-# LANGUAGE OverloadedStrings #-}

module Main where

import MsgIO
import Http

import Data.Text.Encoding
import Data.Maybe
import Data.Aeson
import Data.Text as T hiding(map)
import Data.Text.Encoding
import Data.Typeable
--import Data.Text.Lazy.Encoding
import System.Time
import System.Locale
import Network
import Network.TLS
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
import Control.Monad(forever)
import System.Environment
import System.Timeout


data Level = Err | Info deriving (Show)

data FetchTimeout = FetchTimeout deriving (Show, Typeable)
data WrongFormat = WrongFormat deriving (Show, Typeable)

instance Exception FetchTimeout
instance Exception WrongFormat

output l m = putStrLn ("fetchio: " ++ (p l) ++ ": " ++ m)
  where p Err = "error"
        p Info = "info"

logger m = do
  t <- getClockTime
  putStrLn $ Prelude.concat ["[", show t, "][ts:", case t of TOD ts _ -> show ts,"] ", m]

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
  waitFor tchan
  return () -- Dead
  where
    allHost hg = map getHostInfo (hosts (fromJust $ getHostGroup cfg hg))
    firstHost hg = getHostInfo $ (Prelude.head $ hosts (fromJust $ getHostGroup cfg hg))
    startP tc pipe = do
      let in_c = firstHost (amqp_in_hosts pipe)
      let out_c = firstHost (amqp_out_hosts pipe)
      let h = allHost (http_hosts pipe)
      mapM_ (forkIO . simpleFetch tc in_c out_c (amqp_in_queue pipe) (amqp_out_exchange pipe) (http_min_delay pipe)) h
      return ()

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
            (pn,pp,puser,ppass)    -- Proxy host (Maybe)
            = do
  logger ("Building pipeline with params: " ++ (show qin) ++ " - " ++ (show eout) ++ " - " ++ (show proxy))
  conn <- openConnection (T.unpack in_h) "/" (fromMaybe "" in_login) (fromMaybe "" in_passw)
  chan <- openChannel conn
  chano <- if in_c == out_c 
           then
             openChannel conn  -- We create a new channel
           else do
           	  conno <- openConnection (T.unpack out_h) "/" (fromMaybe "" out_login) (fromMaybe "" out_passw)
           	  openChannel conno
  loop0 chan chano
  return ()
  where
    proxy= (pn, pp, liftM encodeUtf8 puser, liftM encodeUtf8 ppass)
    loop0 chan chano = forever $ do
      mng <- newManager $ def { managerCheckCerts = \ _ _ _-> return CertificateUsageAccept }
      logger ("Pipeline ready with params: " ++ (show qin) ++ " - " ++ (show eout) ++ " - " ++ (show proxy)) 
      catches (loop chan chano mng) [Handler (\e -> do { putStrLn $ show (e::FetchTimeout); closeManager mng })]
    loop c co mng = forever $ do
        iter c co qin eout mng proxy
        when(isJust wait) (threadDelay $ 1000 * fromJust wait)


iter cin cout qi eo mng proxy = do
  r <- pop cin qi
  when(isJust r) $ do 
    let (mi,tag, rraw) = fromJust r
    --catchAny (doit' mi rraw tag) (\e -> do { putStrLn $ show e ;reject tag } )
    doit' mi rraw tag
  return ()
  where
    doit' mi rraw tag = catches (doit mi rraw tag) (handlers tag)
    handlerWrap tag h action = Handler (\e -> do
      b <- h e
      if b then ack tag else reject tag
      action
      )
    handlers tag = [ handlerWrap tag handlerHttpE (return ()), handlerWrap tag (\(e::FetchTimeout) -> return False) (throw FetchTimeout),
                     handlerWrap tag (\(e::WrongFormat) -> return True) (return ()) ]
    handlerHttpE (InvalidUrlException s ss) = do
      putStrLn $ s++" "++ss
      return True
    handlerHttpE (TlsException s) = do
      putStrLn $ (show s)
      return True
    handlerHttpE (C.HandshakeFailed) = do
      return True
    handlerHttpE e = do
      putStrLn $ (show e) ++ " " ++ (show proxy)
      return False
    reject tag = rejectMsg cin tag True
    ack tag = do
      ackMsg cin tag False
      return ()
    doit mi rraw tag = do
        let urls = map T.unpack $ getURLs mi
        --let urls = case fetch_url mi of Just u -> T.unpack u
        --                               Nothing -> throw WrongFormat
        let proxys = Just $ (\(h,p,_,_) -> T.concat [h, ":", T.pack $ show p]) $ proxy
        mo <- mapM (\url -> do
          logger $ "Fetching " ++ url ++ ", " ++ (show proxys)
          tuple <- timeout (15*1000*1000) $ fetch proxy mng url (getHeaders mi)
          let (code,r,dt,ts,redirect) = case tuple of Just val -> val
                                                      Nothing -> throw FetchTimeout
          let moo = msgOut { fetch_data = if(code==200) then Just $ MString (Right $ responseBody r) else Nothing, 
                             fetch_status_code = Just code,
                             fetch_latency = Just dt,
                             fetch_proxy = proxys,
                             fetch_time = Just ts,
                             fetch_redirect = fmap decodeUtf8 redirect }
          logger $ "Fetched " ++ url ++ ", " ++ (show proxys) ++ ", status " ++ (show $ code) ++ ", latency " ++ (show dt)
                              ++ ", redirect " ++ (show redirect)
          return moo) urls
        let (code,mout)= case mo of m:[] -> (fetch_status_code m, m) 
                                    m:m1:[] -> (fetch_status_code m, m { fetch_data_1 = fetch_data m1 } )
                                    m:m1:m2:[] -> (fetch_status_code m, m { fetch_data_1 = fetch_data m1, fetch_data_2 = fetch_data m2 } )
        let rk = T.concat [fetch_routing_key mi, ":", T.pack $ show (fromJust code)]
        let msg = newMsg { msgBody = encode $ copyFields (toJSON mout) (fromJust $ decode rraw) } -- TODO: Improve that
        case code of
          Just c | c==200 || c==404 -> do              
            publishMsg cout eo rk msg
            logger ("Publishing with key " ++ (show rk))
            ack tag
          Just c -> do -- Retry
            logger ("Rejecting message, code " ++ (show c))
            reject tag

-- Pop a message from AMQP
pop c q = do
  m0 <- getMsg c Ack q
  let r = case m0 of Just(m) -> let (msg,tag) = (\ (a,b) -> (msgBody a, envDeliveryTag b)) m in
                                Just (fromJust (decode msg),tag, msg)
                     Nothing -> Nothing
  return r


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

