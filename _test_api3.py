import urllib.request, json

data = 'client_id=bpm-platform-api&username=admin-user&password=admin-pass&grant_type=password'
req = urllib.request.Request('http://localhost:8081/realms/bpm-default/protocol/openid-connect/token', data.encode())
resp = urllib.request.urlopen(req)
token = json.loads(resp.read())['access_token']

# Test 1: Empty graph (worked before)
body1 = json.dumps({
    "name": "test-empty-graph",
    "version": "1.0.0", 
    "description": "",
    "graph": {"nodes": [], "edges": []}
})
print(f"Test 1 (empty graph): {body1}")
req = urllib.request.Request('http://localhost:8080/api/v1/definitions', 
    body1.encode(),
    {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
    method='POST')
try:
    resp = urllib.request.urlopen(req)
    print(f'  -> Status {resp.status}: {resp.read().decode()[:200]}')
except urllib.error.HTTPError as e:
    print(f'  -> Error {e.code}: {e.read().decode()[:200]}')

# Test 2: Graph with START node (label field)
body2 = json.dumps({
    "name": "test-start-node",
    "version": "1.0.0",
    "description": "",
    "graph": {"nodes": [{"id": "start", "node_type": "START", "label": None, "attributes": None}], "edges": []}
})
print(f"\nTest 2 (START node): {body2}")
req = urllib.request.Request('http://localhost:8080/api/v1/definitions', 
    body2.encode(),
    {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
    method='POST')
try:
    resp = urllib.request.urlopen(req)
    print(f'  -> Status {resp.status}: {resp.read().decode()[:200]}')
except urllib.error.HTTPError as e:
    print(f'  -> Error {e.code}: {e.read().decode()[:200]}')

# Test 3: Without stage field (maybe that's the issue)
body3 = json.dumps({
    "name": "test-no-stage",
    "version": "1.0.0",
    "description": "",
    "graph": {"nodes": [], "edges": []},
    "stage": None
})
print(f"\nTest 3 (with stage=null): {body3}")
req = urllib.request.Request('http://localhost:8080/api/v1/definitions', 
    body3.encode(),
    {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
    method='POST')
try:
    resp = urllib.request.urlopen(req)
    print(f'  -> Status {resp.status}: {resp.read().decode()[:200]}')
except urllib.error.HTTPError as e:
    print(f'  -> Error {e.code}: {e.read().decode()[:200]}')
