import http.client, json, time

# Get token
c = http.client.HTTPConnection("localhost", 8081)
c.request("POST", "/realms/bpm-default/protocol/openid-connect/token",
    "client_id=bpm-platform-api&username=admin-user&password=admin-pass&grant_type=password",
    {"Content-Type": "application/x-www-form-urlencoded"})
token = json.loads(c.getresponse().read().decode("utf-8-sig"))["access_token"]
c.close()
print("Token OK")

ts = str(time.time()).replace(".", "")[-6:]

# Nodes WITHOUT label/attributes fields (just id and node_type)
body = json.dumps({
    "name": "test-n-" + ts,
    "version": "1.0.0",
    "description": "",
    "stage": None,
    "graph": {
        "nodes": [
            {"id": "start", "node_type": "START"},
            {"id": "end", "node_type": "END"}
        ],
        "edges": [
            {"id": "e1", "source": "start", "target": "end", "condition": None, "is_default": False}
        ]
    }
})
print("Body:", body[:200])

c2 = http.client.HTTPConnection("localhost", 8080)
c2.request("POST", "/api/v1/definitions", body.encode(), {
    "Authorization": "Bearer " + token,
    "Content-Type": "application/json"
})
r = c2.getresponse()
print("Status:", r.status)
print("Response:", r.read().decode()[:300])
c2.close()
