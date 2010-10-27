import sys
sys.path.append('..')

import PluginUtils

def test(message):
	PluginUtils.DEBUG("test", "SENDING!")
	PluginUtils.write("send", message["id"], [message["server"], "PRIVMSG #() :Omg!"])
	return

PluginUtils.bind("test", test)

PluginUtils.loop()

