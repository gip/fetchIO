module Amqp where

import Types
import Ljson

import Data.Maybe
import Data.Text
import Data.String.Conversions

import MsgIO hiding (user,host,password)
import Network.AMQP
import Network.AMQP.Types


instance Connector IO Channel where
  type ConnectionData = Endpoint
  newConnection ep = do
    conn <- openConnection (cs $ getHost ep) "/" (fromMaybe "" $ user ep) (fromMaybe "" $ pass ep)
    chan <- openChannel conn
    return chan

instance Source IO Channel MsgIn where
  type SRouting = Text  -- queue
  pop c q = do
    m0 <- getMsg c Ack q
    let r = case m0 of Just(m) -> let (msg,tag) = (\ (a,b) -> (msgBody a, envDeliveryTag b)) m in
                                  case decode msg of Just md -> Just (md { top_level = decode msg } , ackOrNot c tag)
                                                     _ -> Nothing
                       Nothing -> Nothing
    return r

ackOrNot chan tag ack = if ack 
	                    then ackMsg chan tag False 
	                    else rejectMsg chan tag True

instance Dest IO Channel Value where
  type DRouting = (Text,Text)  -- (exchange,routing key)
  push c (e,k) msg = do
    publishMsg c e k $ newMsg { msgBody = encode msg }
    return ()


