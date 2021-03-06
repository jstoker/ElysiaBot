{-# LANGUAGE OverloadedStrings #-}
module Modules.GDict.GDict (moduleCmds, moduleRaws, onLoad) where
import Network.SimpleIRC
import qualified Data.Map as M
import Data.Maybe
import Data.Either
import qualified Data.ByteString.Char8 as B
import System.Process
import Control.Concurrent
import Control.Concurrent.MVar (MVar)
import System.IO
import Control.Exception
import Modules.GDict.GDictParse
import Types

moduleCmds = M.fromList
  [(B.pack "dict", find)]

moduleRaws = M.empty

onLoad :: MVar [MIrc] -> String -> IO ()
onLoad _ _ = putStrLn "GDict loaded *worships*"

find :: MVar MessageArgs -> IrcMessage -> IO B.ByteString
find _ m = do
  evalResult <- lookupDict searchTerm
  either (\err -> return $ (B.pack err))
         (\res -> return $ B.pack $ limitMsg 200 (formatParsed res))
         evalResult
  where msg = mMsg m
        searchTerm = (B.unpack $ B.unwords (drop 1 $ B.words msg))

limitMsg limit xs = 
  if length xs > limit
    then take limit xs ++ "..."
    else xs

formatParsed :: ParsedDict -> String
formatParsed dict
  | not $ null $ related dict =
    (related dict !! 0) ++ " - " ++ (meanings dict !! 0)
  | otherwise = (meanings dict !! 0)

