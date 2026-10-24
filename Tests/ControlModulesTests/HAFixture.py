"""Local Home Assistant fixture. Never connects to real home devices."""
import base64, hashlib, json, socket, struct

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
    if size > 65536: raise ValueError("oversized frame: " + str(size))
    mask = exact(c, 4) if second & 128 else b''
    payload = exact(c, size)
    if mask: payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    if first & 15 == 8: raise EOFError()
    return json.loads(payload)

def send(c, data):
    payload = json.dumps(data).encode()
    header = bytes([129, len(payload)]) if len(payload) < 126 else bytes([129,126]) + struct.pack('!H',len(payload))
    c.sendall(header + payload)


def entity(id, state, **attrs):
    return {'entity_id': id, 'state': state, 'attributes': dict(friendly_name=id, **attrs)}

states = {
    'light.desk': entity('light.desk', 'off', brightness=128, supported_color_modes=['brightness']),
    'switch.plug': entity('switch.plug', 'on'),
    'scene.work': entity('scene.work', 'unknown'),
    'script.fail': entity('script.fail', 'off'),
    'script.timeout': entity('script.timeout', 'off'),
    'sensor.temperature': entity('sensor.temperature', '22', unit_of_measurement='°C'),
    'cover.blinds': entity('cover.blinds', 'closed', supported_features=11, current_position=0),
    'light.offline': entity('light.offline', 'unavailable'),
    'input_boolean.race': entity('input_boolean.race', 'off'),
    'sensor.calls': entity('sensor.calls', '0'),
}
services = {
    'light': {'toggle': {}, 'turn_on': {}, 'turn_off': {}},
    'switch': {'toggle': {}, 'turn_on': {}, 'turn_off': {}},
    'scene': {'turn_on': {}}, 'script': {'turn_on': {}},
    'cover': {'open_cover': {}, 'close_cover': {}, 'stop_cover': {}},
    'input_boolean': {'toggle': {}},
}
while True:
    c, _ = server.accept()
    try:
        request = b''
        while b'\r\n\r\n' not in request: request += exact(c, 1)
        headers = dict(line.split(': ', 1) for line in request.decode().split('\r\n')[1:] if ': ' in line)
        key = next(v for k,v in headers.items() if k.lower() == 'sec-websocket-key')
        accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        c.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n').encode())
        send(c, {'type': 'auth_required', 'ha_version': '2026.10.3'})
        auth = receive(c)
        if auth.get('type') != 'auth' or auth.get('access_token') != 'fixture-token':
            send(c, {'type': 'auth_invalid', 'message': 'Invalid token'})
            continue
        send(c, {'type': 'auth_ok', 'ha_version': '2026.10.3'})
        subscription = None
        def changed(id):
            send(c, {'id': subscription, 'type': 'event', 'event': {'event_type': 'state_changed', 'data': {'entity_id': id, 'new_state': states.get(id)}}})
        while True:
            m = receive(c); kind = m['type']; id = m['id']
            result = None; success = True
            if kind == 'subscribe_events': subscription = id
            elif kind == 'get_states':
                # A change racing the initial snapshot must win over that snapshot.
                send(c, {'id': id, 'type': 'result', 'success': True, 'result': list(states.values())})
                states['input_boolean.race']['state'] = 'on'
                changed('input_boolean.race')
                continue
            elif kind == 'get_services': result = services
            elif kind == 'ping':
                send(c, {'id': id, 'type': 'pong'})
                continue
            elif kind == 'call_service':
                target = m.get('target', {}).get('entity_id')
                if target == 'script.timeout': continue
                if target == 'script.fail': success = False
                elif target not in states or m['domain'] != target.split('.')[0] or m['service'] not in services[m['domain']]: success = False
                else:
                    states['sensor.calls']['state'] = str(int(states['sensor.calls']['state']) + 1)
                    changed('sensor.calls')
                    if m['service'] == 'toggle': states[target]['state'] = 'off' if states[target]['state'] == 'on' else 'on'
                    elif m['service'] == 'turn_on':
                        states[target]['state'] = 'on'
                        if 'brightness_step_pct' in m.get('service_data', {}):
                            states[target]['attributes']['brightness'] = 153
                    elif m['service'] == 'turn_off': states[target]['state'] = 'off'
                    elif m['service'] == 'open_cover': states[target]['state'] = 'open'
                    elif m['service'] == 'close_cover': states[target]['state'] = 'closed'
                    changed(target)
            else: success = False
            send(c, {'id': id, 'type': 'result', 'success': success, 'result': result, 'error': {'code': 'unauthorized'}})
    except (EOFError, OSError, ValueError, KeyError): pass
    finally: c.close()
