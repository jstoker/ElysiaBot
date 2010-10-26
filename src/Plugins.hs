{-# LANGUAGE DeriveDataTypeable, OverloadedStrings, StandaloneDeriving #-}
module Plugins (PluginCommand(..), writeCommand, runPlugins, pluginLoop, messagePlugin) where
import System.IO
import System.IO.Error (try, catch, isEOFError)
import System.Process
import System.FilePath
import System.Directory

import Control.Concurrent
import Control.Concurrent.MVar (MVar)
import Control.Monad
import Control.Applicative
import Control.Exception (IOException)

import Network.SimpleIRC

import Text.JSON
import Text.JSON.Generic
import Text.JSON.Types

import Data.Maybe
import Data.List (isPrefixOf)

import qualified Data.ByteString.Char8 as B

import Types

data RPC = 
    RPCRequest
      { reqMethod :: B.ByteString
      , reqParams :: JSValue
      , reqId     :: Maybe Rational
      } 
  | RPCResponse 
      { rspResult :: B.ByteString
      , rspError  :: Maybe B.ByteString
      , rspID     :: Rational
      }
  deriving (Typeable, Show)
  
data Message = 
   MsgSend
    { servAddr :: String
    , rawMsg   :: String
    }
  | MsgCmdAdd
    { command  :: String }
  | MsgPid
    { pid      :: Int }
  deriving Show
  
data PluginCommand = PluginCommand
  | PCMessage IrcMessage MIrc
  | PCCmdMsg  IrcMessage MIrc String String -- IrcMessage, Server, prefix, (msg without prefix)
  | PCQuit

validateFields :: JSValue -> [String] -> Bool
validateFields (JSObject obj) fields =
  let exist = map (get_field obj) fields
  in all (isJust) exist

-- -.-
getJSString :: JSValue -> String
getJSString (JSString (JSONString s)) = s

getJSMaybe :: JSValue -> Maybe JSValue
getJSMaybe (JSObject obj) = 
  get_field obj "Just"
getJSMaybe (JSString (JSONString s)) = 
  if s == "Nothing"
    then Nothing
    else error $ "Maybe in a JSON literal is a string, but it is not, \"Nothing\", got " ++ s

getJSRatio :: JSValue -> Rational
getJSRatio (JSRational _ r) = r
getJSRatio _ = error "Not a JSRational."

errorResult :: Result a -> a
errorResult (Ok a) = a
errorResult (Error s) = error s

-- Turns the parsed JSValue into a RPC(Either a RPCRequest or RPCResponse)
jsToRPC :: JSValue -> RPC
jsToRPC js@(JSObject obj) 
  | validateFields js ["method", "params", "id"] =
    let rID = getJSMaybe $ fromJust $ get_field obj "id" 
    in RPCRequest 
         { reqMethod = B.pack $ getJSString $ fromJust $ get_field obj "method"
         , reqParams = fromJust $ get_field obj "params" 
         , reqId     = if isJust $ rID 
                          then Just $ getJSRatio $ fromJust rID
                          else Nothing 
         }

  -- TODO: RPCResponse.

-- This function just checks the reqMethod of RPCRequest.
rpcToMsg :: RPC -> Message
rpcToMsg req@(RPCRequest method _ _)
  | method == "send"    = rpcToSend   req
  | method == "cmdadd"  = rpcToCmdAdd req
  | method == "pid"     = rpcToPID    req 

-- Turns an RPC(Which must be a RPCRequest with a method of "send") into a MsgSend.
rpcToSend :: RPC -> Message
rpcToSend (RPCRequest _ (JSArray params) _) = 
  MsgSend server msg
  where server    = getJSString $ params !! 0
        msg       = getJSString $ params !! 1

rpcToCmdAdd :: RPC -> Message
rpcToCmdAdd (RPCRequest _ (JSArray params) _) = 
  MsgCmdAdd cmd
  where cmd = getJSString $ params !! 0

rpcToPID :: RPC -> Message
rpcToPID (RPCRequest _ (JSArray params) _) =
  MsgPid (read pid) -- TODO: Check whether it's an int.
  where pid = getJSString $ params !! 0

decodeMessage :: String -> Message
decodeMessage xs = rpcToMsg $ jsToRPC parsed
  where parsed = errorResult $ decode xs 
  
-- Writing JSON ----------------------------------------------------------------

deriving instance Data IrcMessage

showJSONMIrc :: MIrc -> IO JSValue
showJSONMIrc s = do
  addr <- getAddress s
  nick <- getNickname s
  user <- getUsername s
  chans <- getChannels s
  
  return $ JSObject $ toJSObject $
    [("address", showJSON $ addr)
    ,("nickname", showJSON $ nick)
    ,("username", showJSON $ user)
    ,("chans", showJSON $ chans)
    ]

showJSONCommand :: PluginCommand -> IO JSValue
showJSONCommand (PCMessage msg serv) = do
  servJSON <- showJSONMIrc serv
  return $ JSObject $ toJSObject $
    [("method", showJSON ("recv" :: String))
    ,("params", JSArray [toJSON msg, servJSON])
    ,("id", showJSON ("Nothing" :: String))
    ]

showJSONCommand (PCCmdMsg msg serv prefix cmd) = do
  servJSON <- showJSONMIrc serv
  return $ JSObject $ toJSObject $
    [("method", showJSON ("cmd" :: String))
    ,("params", JSArray [toJSON msg, servJSON, showJSON prefix, showJSON cmd])
    ,("id", showJSON ("Nothing" :: String))
    ]

showJSONCommand (PCQuit) = do
  return $ JSObject $ toJSObject $
    [("method", showJSON ("quit" :: String))
    ,("params", JSArray [])
    ,("id", showJSON ("Nothing" :: String))
    ]

-- End of JSON -----------------------------------------------------------------

isCorrectDir dir f = do
  r <- doesDirectoryExist (dir </> f)
  return $ r && f /= "." && f /= ".." && not ("." `isPrefixOf` f)

runPlugins :: IO [MVar Plugin]
runPlugins = do
  contents  <- getDirectoryContents "Plugins/"
  fContents <- filterM (isCorrectDir "Plugins/") contents
  
  mapM (runPlugin) fContents
  
runPlugin :: String -> IO (MVar Plugin)
runPlugin plDir = do
  currWorkDir <- getCurrentDirectory
  let plWorkDir = currWorkDir </> "Plugins/" </> plDir
      shFile    = plWorkDir </> "run.sh"
  putStrLn $ "-- " ++ plWorkDir
  (inpH, outH, errH, pid) <- runInteractiveProcess ("./run.sh") [] (Just plWorkDir) Nothing
  hSetBuffering outH LineBuffering
  hSetBuffering errH LineBuffering
  hSetBuffering inpH LineBuffering

  -- TODO: read the plugin.ini file.
  newMVar $ 
    Plugin plDir "" [] outH errH inpH pid Nothing [] []

getAllLines :: Handle -> IO [String]
getAllLines h = liftA2 (:) first rest `catch` (\_ -> return []) 
  where first = hGetLine h
        rest = getAllLines h

getErrs :: Plugin -> IO String
getErrs plugin = do
  -- hGetContents is lazy, getAllLines is a non-lazy hGetContents :D
  contents <- getAllLines (pStderr plugin)
  return $ unlines contents

pluginLoop :: MVar MessageArgs -> MVar Plugin -> IO ()
pluginLoop mArgs mPlugin = do
  plugin <- readMVar mPlugin
  
  -- This will wait until some output appears, and let us know when
  -- stdout is EOF
  outEof <- hIsEOF (pStdout plugin)

  if not outEof
    then do
      line <- hGetLine (pStdout plugin)
      putStrLn $ "Got line from plugin(" ++ pName plugin ++ "): " ++ line
      
      when ("{" `isPrefixOf` line) $ do 
        let decoded = decodeMessage line

        case decoded of
          MsgSend addr msg -> sendRawToServer mArgs addr msg
          MsgPid pid       -> do _ <- swapMVar mPlugin (plugin {pPid = Just pid}) 
                                 return ()
          MsgCmdAdd cmd    -> do _ <- swapMVar mPlugin (plugin {pCmds = cmd:pCmds plugin}) 
                                 return ()
      
      pluginLoop mArgs mPlugin
    else do
      -- Get the error message
      errs <- getErrs plugin

      -- Plugin crashed
      putStrLn $ "WARNING: Plugin(" ++ pName plugin ++ ") crashed, " ++ 
                 errs
      args <- takeMVar mArgs
      let filt = filter (mPlugin /=) (plugins args)
      putMVar mArgs (args {plugins = filt})

sendRawToServer :: MVar MessageArgs -> String -> String -> IO ()
sendRawToServer mArgs server msg = do
  args <- readMVar mArgs 
  servers <- readMVar $ argServers args
  filtered <- filterM (\srv -> do addr <- getAddress srv
                                  return $ addr == (B.pack server)) 
                         servers
  if not $ null filtered
    then sendRaw (filtered !! 0) (B.pack msg)
    else -- TODO: Make it report the error to the plugin
         return ()

writeCommand :: PluginCommand -> MVar Plugin -> IO ()
writeCommand cmd mPlugin = do
  plugin <- readMVar mPlugin
  (JSObject json) <- showJSONCommand cmd
  --putStrLn $ "Sending to plugin: " ++ (showJSObject json) ""
  hPutStrLn (pStdin plugin) ((showJSObject json) "")
  
messagePlugin :: MVar MessageArgs -> EventFunc
messagePlugin mArgs s m = do
  args <- readMVar mArgs
  mapM_ (writeCommand (PCMessage m s)) (plugins args)



