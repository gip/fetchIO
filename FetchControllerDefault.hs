module FetchControllerDefault(canHandle, handle, initial) where

import MsgIO
import Fetcher
import Ljson
import FetchController
import Data.String.Conversions
import Data.Text as T

data State todo done msg = Initial | Final | State todo done msg

canHandle _ = True

initial = Initial 

handle (Initial, Begin mi) = next $ State urls [] mi
  where urls = getURLs mi
        st = State urls []

handle (State urls dn msg, Result url proxy r) = 
  case r of Left (FetchException fatal e _) -> (Final, if fatal then AckOnly else NackOnly $ (show e))
            Right (c,res,dt,ts,red) -> 
              case c of
              	c | c==200 -> next (State urls ((c,res,dt,ts,red,proxy):dn) msg)
                c | c==404 || c==503 || c==403 -> (Final, AckOnly) -- TODO: send a message with return code
                _ -> (Final, NackOnly $ "http code " ++ (show c)) 

next (State (url:urls) dn mi) = (State urls dn mi, Fetch url)

next (State [] dn mi) = (Final, AcknSend rk mo2)
  where rk = T.concat [fetch_routing_key mi, ":200"]
        fres Nothing = Nothing
        fres (Just r) = Just $ MString (Right r)
        mo0 (c,res,dt,ts,red,p) = 
          msgOut { fetch_data = if(c==200) then fres res else Nothing, 
                   fetch_status_code = Just c,
                   fetch_latency = Just dt,
                   fetch_proxy = Just p,
                   fetch_time = Just ts,
                   fetch_redirect = (fmap cs) red }
        mo1 = case dn of r0:[] -> mo0 r0 
                         r0:(_,r1,_,_,_,_):[] -> (mo0 r0) { fetch_data_1 = fres r1 }  
                         r0:(_,r1,_,_,_,_)
                           :(_,r2,_,_,_,_):[] -> (mo0 r0) { fetch_data_1 = fres r1,
                                                            fetch_data_2 = fres r2  }   
                         r0:(_,r1,_,_,_,_)
                           :(_,r2,_,_,_,_)
                           :(_,r3,_,_,_,_):[] -> (mo0 r0) { fetch_data_1 = fres r1,
                                                            fetch_data_2 = fres r2,
                                                            fetch_data_3 = fres r3  } 
        mo2 = case top_level mi of Just tl -> merge (toJSON mo1) tl
                                   Nothing -> toJSON mo1
