import http.client, json, time

# Get token via new connection
conn = http.client.HTTPConnection("localhost", 8081)
params = 'client_id=bpm-platform-api&username=admin-user&password=admin-pass&grant_type=password'
conn.request("POST", "/realms/bpm-default/protocol/openid-connect/token", params, {"Content-Type": "application/x-www-form-urlencoded"})
resp = conn.getresponse()
token_data = json.loads(resp.read().decode('utf-8-sig'))
token = token_data['access_token']
conn.close()
print('Token OK:', token[:20] + '...')

# Test with START/END - FRESH connection every time
ts = str(time.time()).replace('.', '')[-6:]
body = json.dumps({
    'name': 'test-fresh-' + ts,
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

conn2 = http.client.HTTPConnection("localhost", 8080)
conn2.request("POST", "/api/v1/definitions", body.encode(), {
    "Authorization": "Bearer " + token,
    "Content-Type": "application/json"
})
resp2 = conn2.getresponse()
print('Status:', resp2.status)
print('Response:', resp2.read().decode()[:300])
conn2.close()
