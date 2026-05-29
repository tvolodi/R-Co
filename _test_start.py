import urllib.request, json, time

token_url = 'http://localhost:8081/realms/bpm-default/protocol/openid-connect/token'
token_data = 'client_id=bpm-platform-api&username=admin-user&password=admin-pass&grant_type=password'
req = urllib.request.Request(token_url, token_data.encode())
resp = urllib.request.urlopen(req)
token = json.loads(resp.read().decode('utf-8-sig'))['access_token']
print('Token OK')

api_url = 'http://localhost:8080/api/v1/definitions'
ts = str(time.time()).replace('.', '')[-6:]

# Test 1: START/END only (should work)
body1 = json.dumps({
    'name': 'test-se-' + ts,
    'version': '1.0.0',
    'description': '',
    'stage': None,
    'graph': {
        'nodes': [
            {'id': 'start', 'node_type': 'START', 'label': None, 'attributes': None},
            {'id': 'end', 'node_type': 'END', 'label': None, 'attributes': None}
        ],
        'edges': [
            {'id': 'e1', 'source': 'start', 'target': 'end', 'condition': None, 'is_default': False}
        ]
    }
})

req = urllib.request.Request(api_url, body1.encode(), {
    'Authorization': 'Bearer ' + token,
    'Content-Type': 'application/json'
}, method='POST')
try:
    resp = urllib.request.urlopen(req)
    print('Test 1 (START/END): OK', resp.status)
except urllib.error.HTTPError as e:
    print('Test 1 (START/END): Error', e.code, ':', e.read().decode()[:200])

# Test 2: START + HUMAN_TASK + END with attributes as JSON string
ts2 = str(time.time()).replace('.', '')[-6:]
body2 = json.dumps({
    'name': 'test-ht-' + ts2,
    'version': '1.0.0',
    'description': '',
    'stage': None,
    'graph': {
        'nodes': [
            {'id': 'start', 'node_type': 'START', 'label': None, 'attributes': None},
            {'id': 'task-1', 'node_type': 'HUMAN_TASK', 'label': 'Review',
             'attributes': '{"role":"admin-user"}'},
            {'id': 'end', 'node_type': 'END', 'label': None, 'attributes': None}
        ],
        'edges': [
            {'id': 'e1', 'source': 'start', 'target': 'task-1', 'condition': None, 'is_default': False},
            {'id': 'e2', 'source': 'task-1', 'target': 'end', 'condition': None, 'is_default': False}
        ]
    }
})
req = urllib.request.Request(api_url, body2.encode(), {
    'Authorization': 'Bearer ' + token,
    'Content-Type': 'application/json'
}, method='POST')
try:
    resp = urllib.request.urlopen(req)
    print('Test 2 (HUMAN_TASK): OK', resp.status)
except urllib.error.HTTPError as e:
    print('Test 2 (HUMAN_TASK): Error', e.code, ':', e.read().decode()[:200])
