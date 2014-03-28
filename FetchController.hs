module FetchController where

import MsgIO
import Ljson
import Data.ByteString.Lazy as BL

--
-- FetchIO logic basically implement a state machine that is 'programmed'
--   by the controller

--    -----------                       --------------
--    | fetchIO |  <--(State,Command)-- | controller |
--    -----------                       --------------
--         |                                  ^
--         \-----------(State,Result)---------/



--data Stage a = Initial MsgIn 
--             | Final Bool (Maybe MsgOut)     -- Ack MsgOut
--             | Other a
--  deriving(Show)

data Command a k m = AckOnly
                   | AcknSend k m
                   | NackOnly String
                   | CantHandle
                   | Fetch a
  deriving(Show)

data Result u p e a = Begin MsgIn
                     | Result u p (Either e a)
  deriving(Show)
