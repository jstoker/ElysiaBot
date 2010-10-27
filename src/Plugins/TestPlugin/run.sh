# the -i.. appends .. to the searchpath 
ghc --make -i.. TestPlugin.hs && chmod +x TestPlugin && ./TestPlugin
