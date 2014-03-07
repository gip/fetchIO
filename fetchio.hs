{-# LANGUAGE OverloadedStrings #-}

module Main where

import MsgIO
import Http
import Amqp as A

import Data.Text.Encoding
import Data.Maybe
import Data.Aeson
import Data.Text as T hiding(map)
import Data.Text.Encoding
import Data.Typeable
import Data.String.Conversions
import qualified Data.HashMap.Strict as HM

--import Data.Text.Lazy.Encoding
import System.Time
import System.Locale
import Network
import Network.TLS
import Network.AMQP
import Network.AMQP.Types
import Network.Connection
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
      let in_c@(in_h, in_p, in_login, in_passw) = firstHost (amqp_in_hosts pipe)
      let out_c@(out_h, out_p, out_login, out_passw) = firstHost (amqp_out_hosts pipe)
      let h = Prelude.concatMap allHost (http_hosts pipe)
      conn <- newConnection $ Endpoint { A.host= cs in_h, A.user= fromMaybe "" in_login, 
                              A.password= fromMaybe "" in_passw, A.queueOrExch= amqp_in_queue pipe }
      conno <- newConnection $ Endpoint { A.host= cs out_h, A.user= fromMaybe "" out_login, 
                              A.password= fromMaybe "" out_passw, A.queueOrExch= amqp_out_exchange pipe }
      let f = \a b -> forkIO $ simpleFetch tc (pop conn) (push conno) (http_min_delay pipe) (http_start_delay pipe) a b
      mapIM_ f h
      return ()

mapIM_ f l = mapM_ (uncurry f) (Prelude.zip [0..] l) 

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
            fpop
            fpush
            wait
            start_wait
            i                          -- Index
            (pn,pp,puser,ppass)        -- Proxy host (Maybe)
            = do
  --logger ("Building pipeline with params: " ++ (show chan) ++ " - " ++ (show chano) ++ " - " ++ (show proxy))
  logger "New pipeline"
  when(isJust start_wait) $ do
    let ws = (fromJust start_wait) * i
    logger("Pipeline will wait for " ++ (show ws) ++ "s")
    threadDelay $ 1000 * 1000 * ws
  loop0 fpop fpush
  return ()
  where
    waitMs= fromJust wait
    proxy= (pn, pp, liftM encodeUtf8 puser, liftM encodeUtf8 ppass)
    loop0 fpop fpush = forever $ do
      mng <- C.newManager $ mkManagerSettings settings Nothing
      --logger ("Pipeline ready with params: " ++ (show chan) ++ " - " ++ (show chano) ++ " - " ++ (show proxy)) 
      logger "Pipeline ready"
      catches (loop fpop fpush mng) [Handler (\e -> do { putStrLn $ show (e::FetchTimeout); closeManager mng })]
    loop fpop fpusf mng = forever $ do
        iter fpop fpush mng proxy
        when(isJust wait) (threadDelay $ 1000 * waitMs)
    settings= TLSSettingsSimple { settingDisableCertificateValidation= True,
                                  settingDisableSession= True,
                                  settingUseServerName= True }

iter fpop fpush mng proxy = do
  r <- fpop
  when(isJust r) $ do 
    let (mi,ackOrNack) = fromJust r
    --catchAny (doit' mi rraw tag) (\e -> do { putStrLn $ show e ;reject tag } )
    doit' mi ackOrNack
  return ()
  where
    doit' mi ackOrNack = catches (doit mi ackOrNack) (handlers ackOrNack)
    handlerWrap ackOrNack h action = Handler (\e -> do
      b <- h e
      ackOrNack b
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
    doit mi ackOrNack = do
        let urls = map cs $ getURLs mi
        let proxys = Just $ (\(h,p,_,_) -> T.concat [h, ":", cs $ show p]) $ proxy
        mo <- mapM (fetch' proxys (getHeaders mi)) urls
        let (code,mout)= case mo of m:[] -> (fetch_status_code m, m) 
                                    m:m1:[] -> (fetch_status_code m, m { fetch_data_1 = fetch_data m1 } )
                                    m:m1:m2:[] -> (fetch_status_code m, m { fetch_data_1 = fetch_data m1, fetch_data_2 = fetch_data m2 } )
        let rk = T.concat [fetch_routing_key mi, ":", cs $ show (fromJust code)]
        let msg = merge (toJSON mout) (top_level mi) -- Keep the fields from MsgIn
        case code of
          Just c | c==200 || c==404 || c==503 || c==403 -> do              
            fpush rk msg
            logger ("Publishing with key " ++ (show rk))
            ackOrNack True
          Just c -> do -- Retry
            logger ("Rejecting message, code " ++ (show c))
            ackOrNack False
    merge (Object o0) (Just (Object o1)) = Object (HM.union o0 o1)
    fetch' proxys headers url = do
      logger $ "Fetching " ++ url ++ ", " ++ (show proxys)
      tuple <- timeout (15*1000*1000) $ fetch proxy mng url headers
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
      return moo    

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

