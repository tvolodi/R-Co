import urllib.request, json

data = 'client_id=bpm-platform-api&username=admin-user&password=admin-pass&grant_type=password'
req = urllib.request.Request('http://localhost:8081/realms/bpm-default/protocol/openid-connect/token', data.encode())
resp = urllib.request.urlopen(req)
token = json.loads(resp.read())['access_token']

# Test with label and attributes as string
body = json.dumps({
    "name": "test-real",
    "version": "1.0.0",
    "description": "",
    "graph": {
        "nodes": [
            {"id": "start", "node_type": "START", "label": None, "attributes": None},
            {"id": "task-1", "node_type": "HUMAN_TASK", "label": "Review Task",
             "attributes": '{"assignee_type":"user","assignee_ref":"admin-user"}'},
            {"id": "end", "node_type": "END", "label": None, "attributes": None}
        ],
        "edges": [
            {"id": "e1", "source": "start", "target": "task-1", "condition": None, "is_default": False},
            {"id": "e2", "source": "task-1", "target": "end", "condition": None, "is_default": False}
        ]
    }
})
print(f"Body: {body[:200]}...")
req = urllib.request.Request('http://localhost:8080/api/v1/definitions', 
    body.encode(),
    {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
    method='POST')
try:
    resp = urllib.request.urlopen(req)
    print(f'Status {resp.status}: OK - {resp.read().decode()[:300]}')
except urllib.error.HTTPError as e:
    print(f'Error {e.code}: {e.read().decode()[:300]}')
