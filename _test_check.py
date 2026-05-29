import json

# Test with the same format as _test_hm.py
body = json.dumps({
    'name': 'test-ht-xxx',
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
print("JSON body:")
print(body)
print()
# Parse it back to see the structure
parsed = json.loads(body)
print("attributes value type:", type(parsed['graph']['nodes'][1]['attributes']))
print("attributes value:", parsed['graph']['nodes'][1]['attributes'])
