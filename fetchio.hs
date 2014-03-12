{-# LANGUAGE OverloadedStrings #-}

module Main where

import Types
import MsgIO
import Http
import Amqp as A
import Ljson

import Prelude as P
import Data.Text.Encoding
import Data.Maybe
import Data.Either
import Data.List
import Data.Text as T hiding(map)
import Data.Text.Encoding
import Data.Typeable
import Data.String.Conversions
import qualified Data.ByteString.Lazy as BL

import Control.Exception
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TChan
import Control.Monad(when, liftM)
import Control.Applicative ((<$>))
import Control.Monad(forever)
import Control.Monad.Error

import System.Environment
import System.Timeout
import System.Time

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
  putStrLn $ P.concat ["[", show t, "][ts:", case t of TOD ts _ -> show ts,"] ", m]

main = do
  args <- getArgs
  case args of
    fi:[] -> do
      cfg <- (liftM $ decode) (BL.readFile fi)
      case cfg of 
        Left e -> output Err ("error: "++e)
        Right cfg -> start cfg
    _ -> output Err "usage: fetchio <configuration file>"
  return ()

start cfg = do 
  tchan <- atomically $ newTChan
  mapM_ (startP tchan) $ pipelines cfg
  waitFor tchan
  return () -- Dead
  where
    firstHost hg = getHostInfo $ (P.head $ hosts (fromJust $ getHostGroup cfg hg))
    startP tc pipe = do
      let ep_in = amqp_in_host pipe
      let ep_out = amqp_out_host pipe
      let h = http_proxys pipe
      conn <- newConnection (ep_in,amqp_in_queue pipe)  
      conno <- newConnection (ep_out,amqp_out_exchange pipe)
      let f = \a b -> forkIO $ simpleFetch tc (pop conn) (push conno) (http_min_delay pipe) (http_start_delay pipe) a b
      mapIM_ f h
      return ()

mapIM_ f l = mapM_ (uncurry f) (P.zip [0..] l) 

waitFor tc = do 
  threadDelay 100000
  handle
  waitFor tc
  where
    handle = do 
      s <- atomically $ tryReadTChan tc
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
            proxy                      -- Proxy
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
    loop0 fpop fpush = forever $ do
      -- IO monad
      mng <- runErrorT newManager
      loop1 fpop fpush mng
    loop1 fpop fpush (Right mng) = do
      logger "Pipeline ready"
      catches (loop fpop fpush mng) [Handler (\e -> do putStrLn $ show (e::FetchTimeout)
                                                       _ <- runErrorT $ closeManager mng
                                                       return ()
                                             )]
    loop fpop fpusf mng = forever $ do
        iter fpop fpush mng proxy
        when(isJust wait) (threadDelay $ 1000 * waitMs)

iter fpop fpush mng proxy = do
  r <- fpop
  case r of 
    Nothing -> return ()
    Just (mi, ackOrNack) -> do
      let urls = map cs $ getURLs mi
      rs <- mapM (\url -> runErrorT $ fetch mng proxy url (getHeaders mi) (Just $ 15*1000*1000)) urls
      case partitionEithers rs of
        (l@(lh:lt),_) -> do
          logger $ "Fetch failed for " ++ (show urls) ++ " with message " ++ (show lh)
          let isFatal = P.foldr (\e acc -> acc || (fatal e)) False l
          logger $ "  Fatal" ++ (show isFatal)
          ackOrNack isFatal  
        ([], r@((_,res,dt,ts,red):rt)) -> do
          mapM_ ( \(url,(c,_,lat,ts,redirect)) -> logger $ "Fetched " ++ url ++ ", status " ++ (show c) ) $ P.zip urls r
          let codes = nub $ map (\(c,_,_,_,_) -> c) r
          case codes of 
            [c] -> do -- All return codes are same 
              let mo0 = msgOut { fetch_data = if(c==200) then Just $ MString (Right $ fromJust res) else Nothing, 
                                 fetch_status_code = Just c,
                                 fetch_latency = Just dt,
                                 fetch_proxy = Just proxy,
                                 fetch_time = Just ts,
                                 fetch_redirect = fmap cs red }
              let mo1 = case r of _:[] -> mo0
                                  _:(_,r1,_,_,_):[] -> mo0 { fetch_data_1 = Just $ MString (Right $ fromJust r1) }  
                                  _:(_,r1,_,_,_)
                                   :(_,r2,_,_,_):[] -> mo0 { fetch_data_1 = Just $ MString (Right $ fromJust r1),
                                                             fetch_data_2 = Just $ MString (Right $ fromJust r2) }                  
              let rk = T.concat [fetch_routing_key mi, ":", cs $ show c]
              let msg = case top_level mi of Just tl -> merge (toJSON mo1) tl
                                             Nothing -> toJSON mo0
              case c of
                c | c==200 || c==404 || c==503 || c==403 -> do              
                  fpush rk msg
                  logger $ "Publishing with key " ++ (show rk)
                  ackOrNack True
                _ -> do
                  logger ("Rejecting message, code " ++ (show c))
                  ackOrNack False  
            _ -> do
              logger "All return codes were the same, not sure what to do!"
              ackOrNack False    
      return ()
  return ()
 

--
-- Catching all exceptions
--
catchAny :: IO a -> (SomeException -> IO a) -> IO a
catchAny = Control.Exception.catch


