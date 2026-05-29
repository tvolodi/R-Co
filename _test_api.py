import urllib.request, json

data = 'client_id=bpm-platform-api&username=admin-user&password=admin-pass&grant_type=password'
req = urllib.request.Request('http://localhost:8081/realms/bpm-default/protocol/openid-connect/token', data.encode())
resp = urllib.request.urlopen(req)
token = json.loads(resp.read())['access_token']

tests = [
    ("Only name+ver", json.dumps({"name": "test-bare-1", "version": "1.0.0"})),
    ("All null", json.dumps({"name": "test-bare-2", "version": "1.0.0", "description": None, "graph": None, "stage": None})),
    ("Empty graph", json.dumps({"name": "test-bare-3", "version": "1.0.0", "description": "", "graph": {"nodes": [], "edges": []}, "stage": None})),
]

for label, body in tests:
    print(f"\n{label}: {body[:80]}...")
    req = urllib.request.Request('http://localhost:8080/api/v1/definitions', 
        body.encode(),
        {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
        method='POST')
    try:
        resp = urllib.request.urlopen(req)
        print(f'  -> Status {resp.status}: OK - {resp.read().decode()[:200]}')
    except urllib.error.HTTPError as e:
        print(f'  -> Error {e.code}: {e.read().decode()[:200]}')
