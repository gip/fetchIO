{-# LANGUAGE OverloadedStrings #-}

module Amqp where

import Data.Maybe
import Data.Aeson
import Data.Text

import MsgIO hiding (user,host,password)
import Network.AMQP
import Network.AMQP.Types

data Endpoint = Endpoint { host :: String, 
                           user :: Text, 
                           password :: Text, 
                           queueOrExch :: Text }

instance Connector IO Endpoint (Channel,Text) where
  newConnection ep = do
    conn <- openConnection (host ep) "/" (user ep) (password ep)
    chan <- openChannel conn
    return (chan, queueOrExch ep)

instance Source IO Endpoint (Channel,Text) MsgIn where
  pop (c,q) = do
    m0 <- getMsg c Ack q
    let r = case m0 of Just(m) -> let (msg,tag) = (\ (a,b) -> (msgBody a, envDeliveryTag b)) m in
                                  case decode msg of Just md -> Just (md { top_level = decode msg } , ackOrNot c tag)
                                                     _ -> Nothing
                       Nothing -> Nothing
    return r

ackOrNot chan tag ack = if ack 
	                    then ackMsg chan tag False 
	                    else rejectMsg chan tag True

instance Dest IO Endpoint (Channel,Text) Text Value where
  push (c,e) k msg = do
    publishMsg c e k $ newMsg { msgBody = encode msg }
    return ()


