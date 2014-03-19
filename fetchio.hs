{-# LANGUAGE OverloadedStrings #-}

module Main where

import Types
import MsgIO
import Fetcher
import FetchController
import qualified FetchControllerDefault as FCDefault
import FetcherHttpConduit
import Amqp as A
import Ljson

import Prelude as P
import Data.Text.Encoding
import Data.Maybe
import Data.Either
import Data.List
import Data.Text as T hiding(map,find)
import Data.Text.Encoding
import Data.Typeable
import Data.String.Conversions
import qualified Data.ByteString.Lazy as BL

import Control.Exception
import Control.Concurrent
import GHC.Conc
import Control.Concurrent.STM
import Control.Concurrent.STM.TChan
import Control.Monad(when, liftM)
import Control.Applicative ((<$>))
import Control.Monad(forever)
import Control.Monad.Error

import System.Environment
import System.Timeout
import System.Time

--
-- Types
--
data Level = Err | Info deriving (Show)

data FetchTimeout = FetchTimeout deriving (Show, Typeable)
data WrongFormat = WrongFormat deriving (Show, Typeable)

instance Exception FetchTimeout
instance Exception WrongFormat

--
-- Pipeline description record
--
data Pipe a = Pipe { pId :: a,
                     pChan :: TChan String,
                     pPop :: IO (Maybe (MsgIn,Bool -> IO ())),
                     pPush :: Text -> Value -> IO (),
                     pDelay :: Maybe Int,
                     pStartDelay :: Maybe Int,
                     pProxy :: Endpoint
                   }

instance (Show a) => Show (Pipe a)  where
  show p = "Fetcher " ++ show (pId p) ++ ", proxy " ++ (show $ pProxy p)

--
-- Helper functions
--
logger m = do
  t <- getClockTime
  putStrLn $ P.concat ["[", show t, "][ts:", case t of TOD ts _ -> show ts,"] ", m]


--
-- main
--
main = do
  args <- getArgs
  case args of
    fi:[] -> do
      cfg <- (liftM $ decode) (BL.readFile fi)
      case cfg of 
        Left e -> output Err ("error: "++e)
        Right cfg -> startPipelines cfg
    _ -> output Err "usage: fetchio <configuration file>"
  return ()
  where
    output l m = putStrLn ("fetchio: " ++ (p l) ++ ": " ++ m)
      where p Err = "error"
            p Info = "info"

--
-- Start pipelines
--
startPipelines cfg = do 
  tc <- atomically $ newTChan
  mapM_ (startPipeline tc) $ pipelines cfg
  startBackground tc
  return () -- Dead
  where
    startPipeline tc pipe = do
      let ep_in = amqp_in_host pipe
      let ep_out = amqp_out_host pipe
      let h = P.concat $ http_proxys pipe
      conn <- newConnection ep_in
      conno <- if ep_in==ep_out then return conn
                                else newConnection ep_out
      let p = Pipe { pChan = tc, 
                     pPop = pop conn (amqp_in_queue pipe), 
                     pPush = curry (push conno) $ amqp_out_exchange pipe, 
                     pDelay = http_min_delay pipe, 
                     pStartDelay = http_start_delay pipe, 
                     pProxy = undefined, pId = undefined }
      forkIO $ startPipelineBackground $ map (\(i,proxy) -> (i, Nothing, p { pProxy = proxy, pId = i } ) ) (P.zip [0..] h) 

--
-- Pipeline background thread 
-- The thread will just makes sure all fetcher threads are running
--
startPipelineBackground threads = do
  threads' <- mapM handleThread threads
  threadDelay 100000
  startPipelineBackground threads'
  where
    handleThread (i,Nothing,p) = start i p
    handleThread t@(i, Just tid,p) = do
      status <- threadStatus tid
      case status of
        ThreadFinished -> do
          logger $ "Fetcher " ++ (show p) ++ " finished with ThreadFinished"
          start i p
        ThreadDied -> do
          logger $ "Fetcher " ++ (show p) ++ " finished with ThreadDied"
          start i p 
        _ -> return t
    start i p = do
      tid <- forkIO $ startFetcher i p
      return (i, Just tid, p)

--
-- Start the main background thread that handles messages from the fetchers
--
startBackground tc = do
  threadDelay 100000
  handle
  startBackground tc
  where
    handle = do 
      s <- atomically $ tryReadTChan tc
      if(isJust s)
      then do
        putStrLn (fromJust s)
        handle
      else
        return ()

--
-- Fetcher thread
--
startFetcher i pipe = do
  logger $ "New pipeline " ++ (show pipe)
  case pStartDelay pipe of 
    Just t -> do
      let ws = t * i
      logger("Pipeline will wait for " ++ (show ws) ++ "s")
      threadDelay $ 1000 * 1000 * ws
    Nothing -> return ()
  loop0 pipe
  return ()
  where
    loop0 pipe = forever $ do
      -- IO monad
      mng <- runErrorT newManager
      loop1 pipe mng
    loop1 pipe (Right mng) = do
      logger $ "Pipeline ready " ++ (show pipe)
      catches (loop pipe mng) [Handler (\e -> do putStrLn $ show (e::FetchTimeout)
                                                 _ <- runErrorT $ closeManager mng
                                                 return ()
                                             )]
    loop pipe mng = forever $ do
        iter pipe mng
        case pDelay pipe of
          Just delay -> threadDelay $ 1000 * delay
          Nothing -> return ()


controllers = (FCDefault.canHandle,FCDefault.initial,FCDefault.handle)
            : []

----
---- A single iteration of the fetcher
---- It will read from the input, fetch the url(s) and then perform a write-back
----
iter pipe mng = do
  r <- (pPop pipe)
  case r of
    Nothing -> return ()
    Just (mi, ackOrNack) -> do
      case find (\(can,_,_) -> can mi) controllers of
        Nothing -> do
          ackOrNack False
        Just (_,initial,handle) -> step (initial, Begin mi)
          where
            step st0 = do
              case handle st0 of 
                (_, AcknSend rk msg) -> do
                  (pPush pipe) rk msg
                  logger $ "Publishing message, routing key"++(show rk)++" on"++(show pipe)
                  ackOrNack True
                  logger $ "Acking message on"++(show pipe)
                (_, AckOnly) -> do
                  ackOrNack True
                  logger $ "Acking message on"++(show pipe)
                (_, NackOnly _) -> do
                  ackOrNack False
                  logger $ "Rejecting message on "++(show pipe)
                (st, Fetch url) -> do
                  r <- runErrorT $ fetch mng (pProxy pipe) (cs url) (fromMaybe [] $ fetch_headers mi) (Just $ 15*1000*1000)
                  case r of Left e -> logger $ "Fetched"++(show url)++", failed with message "++(show e)++" on "++(show pipe)
                            Right (c,_,_,_,_) -> logger $ "Fetched "++(show url)++", status "++(show c)++" on "++(show pipe)
                  step (st, Result url (pProxy pipe) r)

--
-- Catching all exceptions
--
catchAny :: IO a -> (SomeException -> IO a) -> IO a
catchAny = Control.Exception.catch


