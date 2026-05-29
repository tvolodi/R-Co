import http.client, json, time

# Test 1: With x-bpm-user-id header (like curl)
c = http.client.HTTPConnection("localhost", 8080)
ts = str(time.time()).replace(".", "")[-6:]
body = json.dumps({
    "name": "test-uid-" + ts,
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

# With x-bpm-user-id (like curl did)
c.request("POST", "/api/v1/definitions", body.encode(), {
    "Content-Type": "application/json",
    "x-bpm-user-id": "00000000-0000-0000-0000-000000000001"
})
r = c.getresponse()
print("Test 1 (with x-bpm-user-id): Status", r.status)
print("  Response:", r.read().decode()[:200])
c.close()

# Test 2: With Bearer token (like the E2E test does)
c2 = http.client.HTTPConnection("localhost", 8081)
c2.request("POST", "/realms/bpm-default/protocol/openid-connect/token",
    "client_id=bpm-platform-api&username=admin-user&password=admin-pass&grant_type=password",
    {"Content-Type": "application/x-www-form-urlencoded"})
token = json.loads(c2.getresponse().read().decode("utf-8-sig"))["access_token"]
c2.close()

c3 = http.client.HTTPConnection("localhost", 8080)
ts2 = str(time.time()).replace(".", "")[-6:]
body2 = json.dumps({
    "name": "test-bear-" + ts2,
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
c3.request("POST", "/api/v1/definitions", body2.encode(), {
    "Content-Type": "application/json",
    "Authorization": "Bearer " + token
})
r3 = c3.getresponse()
print("Test 2 (with Bearer): Status", r3.status)
print("  Response:", r3.read().decode()[:200])
c3.close()
