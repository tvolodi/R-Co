import urllib.request, json, time

api_url = 'http://localhost:8080/api/v1/definitions'
ts = str(time.time()).replace('.', '')[-6:]

body = json.dumps({
    'name': 'test-urllib-' + ts,
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

req = urllib.request.Request(api_url, body.encode(), {
    'Content-Type': 'application/json',
    'x-bpm-user-id': '00000000-0000-0000-0000-000000000001'
}, method='POST')

try:
    resp = urllib.request.urlopen(req)
    print('OK', resp.status)
except urllib.error.HTTPError as e:
    print('Error', e.code, ':', e.read().decode()[:200])
except Exception as e:
    print('Exception:', str(e))
