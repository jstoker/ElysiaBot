import sys, os
import collections
import json

stdin = sys.stdin
stdout = sys.stdout
debug = open('debug.log', 'a')

def DEBUG(key, message):
	debug.write('* '+key+' *\n')
	debug.write(message+'\n')
	debug.flush()

global connected
connected = False

_queue = collections.deque()
_handlers = collections.defaultdict(lambda: [])

def flush_queue():
	DEBUG("flush_queue", "flushing queue")
	while _queue:
		DEBUG("write", _queue[0])
		stdout.write(_queue.popleft()+'\n')
	stdout.flush()
	DEBUG("flush_queue", "flushed queue")

def write(method, id, obj, force=False):
	obj = {'method': method, "id": id, "params": obj}
	data = json.dumps(obj, separators=(',',':'))
	
	if not connected and not force:
		DEBUG("write", "Attempting to write %s, but am currently DISCONNECTED. Added to queue." % data)
		_queue.append(data)
		return False
	else:
		DEBUG("write", data)
		stdout.write(data + '\n')
		stdout.flush()
	return True

def bind(command, callback):
	_handlers[command].append(callback)
	write("cmdadd", 0, [command])
	DEBUG("bind", "Command "+`command`+" binded to "+`callback`)

def handler(message):
	if _handlers.has_key(message["command"]):
		
		for handler in _handlers[message["command"]]:
			DEBUG("handler", "Found %r." % handler)
			handler(message)
	return

def poll():
	if _queue:
		flush_queue()
	
	json_raw = stdin.readline()
	DEBUG('raw', json_raw)
	#return 
	data = json.loads(json_raw)
	
	assert 'jsonrpc' not in data.keys()
	assert 'version' not in data.keys()
	if data.has_key("result"):
		return # ignored
	assert data["method"] in ("recv", "cmd")
	assert data.has_key("params")
	params = data["params"]
	if data["method"] == "recv":
		message = {
				   'nick':    params[0]["nick"],
				   'ident':   params[0]["user"],
				   'host':    params[0]["host"],
				   'cmd':     params[0]["code"],
				   'message': params[0]["msg"],
				   'channel': params[0]["chan"],
				   'other':   params[0]["other"],
				   'raw':     params[0]["raw"],
		           'me':      {'server':   params[1]["address"],
							   'nickname': params[1]["nickname"],
							   'username': params[1]["username"],
							   'channels': params[1]["chans"]
							  }
		          }
	elif data["method"] == "cmd":
		message = {
				   'nick':    params[0]["nick"],
				   'ident':   params[0]["user"],
				   'host':    params[0]["host"],
				   'cmd':     params[0]["code"],
				   'message': params[0]["msg"],
				   'channel': params[0]["chan"],
				   'other':   params[0]["other"],
				   'raw':     params[0]["raw"],
		           'me':      {'server':   params[1]["address"],
							   'nickname': params[1]["nickname"],
							   'username': params[1]["|username"],
							   'channels': params[1]["chans"]
							  },
		           'command': params[1]["|"]
		          }
		handler(message)
	
def loop():
	global connected
	if not connected:
		write("pid", None, [os.getpid()], force=True)
		connected = True
	
	while True:
		poll()