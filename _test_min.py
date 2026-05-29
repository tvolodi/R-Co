import urllib.request, json, time

token_url = 'http://localhost:8081/realms/bpm-default/protocol/openid-connect/token'
token_data = 'client_id=bpm-platform-api&username=admin-user&password=admin-pass&grant_type=password'
req = urllib.request.Request(token_url, token_data.encode())
resp = urllib.request.urlopen(req)
token = json.loads(resp.read().decode('utf-8-sig'))['access_token']
print('Token:', token[:30] + '...')

api_url = 'http://localhost:8080/api/v1/definitions'
ts = str(time.time()).replace('.', '')[-6:]
body = json.dumps({
    'name': 'test-empty-' + ts,
    'version': '1.0.0',
    'description': '',
    'stage': None,
    'graph': {'nodes': [], 'edges': []}
})
print('Body:', body[:200])
req = urllib.request.Request(api_url, body.encode(), {
    'Authorization': 'Bearer ' + token,
    'Content-Type': 'application/json'
}, method='POST')
try:
    resp = urllib.request.urlopen(req)
    print('OK', resp.status)
except urllib.error.HTTPError as e:
    print('Error', e.code, ':', e.read().decode()[:200])
except Exception as e:
    print('Exception:', str(e))
