import urllib.request, json

# Step 1: Get token
token_url = 'http://localhost:8081/realms/bpm-default/protocol/openid-connect/token'
token_data = 'client_id=bpm-platform-api&username=admin-user&password=admin-pass&grant_type=password'
print("Getting token from:", token_url)
req = urllib.request.Request(token_url, token_data.encode())
resp = urllib.request.urlopen(req)
token = json.loads(resp.read().decode('utf-8-sig'))["access_token"]
print("Token obtained:", token[:20] + "...")

# Step 2: POST
api_url = 'http://localhost:8080/api/v1/definitions'
body = json.dumps({
    "name": "test-debug",
    "version": "1.0.0",
    "description": "",
    "stage": None,
    "graph": {
        "nodes": [
            {"id": "start", "node_type": "START", "label": None, "attributes": None},
            {"id": "end", "node_type": "END", "label": None, "attributes": None}
        ],
        "edges": [
            {"id": "e1", "source": "start", "target": "end", "condition": None, "is_default": False}
        ]
    }
})
print("POSTing to:", api_url)
print("Body:", body[:150] + "...")

req = urllib.request.Request(api_url, body.encode(), {"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method="POST")
try:
    resp = urllib.request.urlopen(req)
    print("OK Status:", resp.status)
    print("Response:", resp.read().decode()[:200])
except urllib.error.HTTPError as e:
    print("HTTP Error:", e.code)
    print("Response:", e.read().decode()[:200])
except Exception as e:
    print("Exception:", str(e))
