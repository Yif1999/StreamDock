"""Local authenticated obs-websocket fixture. Never connects to a real OBS instance.

Like OBS, every state change is announced as an event carrying the new value. Each request
type received is printed ("REQ <type>") so tests can see what the client asked for.
With --stale-record, the first GetRecordStatus answer is stale: recording starts (and its
event is sent) between reading the status and sending the answer."""
import base64, hashlib, json, socket, struct, sys

stale_record = '--stale-record' in sys.argv

server = socket.socket()
server.bind(('127.0.0.1', 0))
server.listen()
print(server.getsockname()[1], flush=True)

def exact(c, count):
    result = b''
    while len(result) < count:
        part = c.recv(count - len(result))
        if not part:
            raise EOFError()
        result += part
    return result

def receive(c):
    first, second = exact(c, 2)
    size = second & 127
    if size == 126: size = struct.unpack('!H', exact(c, 2))[0]
    elif size == 127: size = struct.unpack('!Q', exact(c, 8))[0]
    mask = exact(c, 4) if second & 128 else b''
    payload = exact(c, size)
    if mask: payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    if first & 15 == 8: raise EOFError()
    return json.loads(payload)

def send(c, op, data):
    payload = json.dumps({'op':op,'d':data}).encode()
    header = bytes([129, len(payload)]) if len(payload) < 126 else bytes([129,126]) + struct.pack('!H',len(payload))
    c.sendall(header + payload)

while True:
    c, _ = server.accept()
    try:
        request = b''
        while b'\r\n\r\n' not in request: request += exact(c,1)
        headers = dict(line.split(': ',1) for line in request.decode().split('\r\n')[1:] if ': ' in line)
        key = next(v for k,v in headers.items() if k.lower() == 'sec-websocket-key')
        accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        c.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n').encode())
        send(c,0,{'rpcVersion':1,'authentication':{'salt':'fixture-salt','challenge':'fixture-challenge'}})
        identify = receive(c)
        secret = base64.b64encode(hashlib.sha256(b'fixture-passwordfixture-salt').digest()).decode()
        expected = base64.b64encode(hashlib.sha256((secret+'fixture-challenge').encode()).digest()).decode()
        if identify['op'] != 1 or identify['d'].get('authentication') != expected: raise EOFError()
        send(c,2,{'negotiatedRpcVersion':1})
        recording=False; paused=False; muted=False; enabled=True; studio=False; program='Camera'; preview='Desktop'
        def event(kind, data): send(c,5,{'eventType':kind,'eventIntent':1,'eventData':data})
        # As obs-websocket does: outputActive is true only for STARTED and RESUMED.
        def output(kind, *states):
            for state in states: event(kind,{'outputActive':state in ('STARTED','RESUMED'),'outputState':'OBS_WEBSOCKET_OUTPUT_'+state})
        while True:
            message=receive(c); data=message['d']; kind=data['requestType']; args=data.get('requestData',{}); out={}; success=True
            print('REQ', kind, flush=True)
            if kind=='GetSceneList':out={'scenes':[{'sceneName':'Camera'},{'sceneName':'Desktop'}],'currentProgramSceneName':program,'currentPreviewSceneName':preview}
            elif kind=='GetRecordStatus':
                out={'outputActive':recording,'outputPaused':paused,'outputTimecode':'00:00:10.000'}
                if stale_record:
                    stale_record=False; recording=True
                    output('RecordStateChanged','STARTING','STARTED')
            elif kind=='GetStreamStatus':out={'outputActive':False,'outputTimecode':'00:00:00.000'}
            elif kind=='GetStudioModeEnabled':out={'studioModeEnabled':studio}
            elif kind in ('GetReplayBufferStatus','GetVirtualCamStatus'):out={'outputActive':False}
            elif kind=='GetInputList':out={'inputs':[{'inputName':'Mic'},{'inputName':'Desktop Audio'}]}
            elif kind=='GetInputMute':out={'inputMuted':muted if args['inputName']=='Mic' else False}
            elif kind=='GetSceneItemList':out={'sceneItems':[{'sceneItemId':7,'sourceName':'Camera Source','sceneItemEnabled':enabled},{'sceneItemId':19,'sourceName':'Overlay','sceneItemEnabled':True}]}
            elif kind=='GetHotkeyList':out={'hotkeys':['fixture-hotkey']}
            elif kind=='ToggleRecord':recording=not recording
            elif kind=='ToggleRecordPause':paused=not paused
            elif kind=='ToggleInputMute':muted=not muted
            elif kind=='SetStudioModeEnabled':studio=args['studioModeEnabled']
            elif kind=='SetCurrentProgramScene':program=args['sceneName']
            elif kind=='SetCurrentPreviewScene':preview=args['sceneName']
            elif kind=='SetSceneItemEnabled':
                if args['sceneItemId'] != 7:success=False
                else:enabled=args['sceneItemEnabled']
            elif kind=='TriggerStudioModeTransition':program=preview
            elif kind=='TriggerHotkeyByName':success=False
            else:success=False
            send(c,7,{'requestId':data['requestId'],'requestStatus':{'result':success,'code':100 if success else 500,'comment':'fixture rejected request'},'responseData':out})
            if not success: continue
            if kind=='ToggleRecord':
                if not recording: paused=False
                output('RecordStateChanged',*(('STARTING','STARTED') if recording else ('STOPPING','STOPPED')))
            elif kind=='ToggleRecordPause':output('RecordStateChanged','PAUSED' if paused else 'RESUMED')
            elif kind=='ToggleInputMute':event('InputMuteStateChanged',{'inputName':'Mic','inputMuted':muted})
            elif kind=='SetStudioModeEnabled':event('StudioModeStateChanged',{'studioModeEnabled':studio})
            elif kind in ('SetCurrentProgramScene','TriggerStudioModeTransition'):event('CurrentProgramSceneChanged',{'sceneName':program})
            elif kind=='SetCurrentPreviewScene':event('CurrentPreviewSceneChanged',{'sceneName':preview})
            elif kind=='SetSceneItemEnabled':event('SceneItemEnableStateChanged',{'sceneName':args['sceneName'],'sceneItemId':7,'sceneItemEnabled':enabled})
    except (EOFError, OSError, ValueError, KeyError):pass
    finally:c.close()
