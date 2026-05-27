import json, datetime, os

run_id = 'WF02-oidc09-20260527'
requirement_ids = ['OIDC-09']
difficulty = 3
rationale = 'New JIT provisioning orchestration layer: wires OIDC-08 IdentityContext into existing createOrGetJitOidcUser service, touches auth middleware, oidc module, and identity service'
surface = 'medium'
surface_why = 'Touches src/oidc/ (new module), src/identity/service.zig (extend createOrGetJitOidcUser callers), and src/api/middleware/auth.zig (wire JIT after token verification)'
surcharge = {'low': 0.0, 'medium': 0.25, 'high': 0.50}[surface]

steps = ['code-designer', 'backend-dev', 'test-designer', 'test-runner', 'release-validator', 'doc-updater']

with open('docs/metrics/estimation_rules.json') as f:
    rules = json.load(f)

idx = difficulty - 1
step_mins = rules['step_estimates_minutes']
estimated = {s: round(step_mins[s][idx] * (1 + surcharge)) for s in steps if s in step_mins}
estimated['total'] = sum(v for k, v in estimated.items() if k != 'total')

estimation = {
    'run_id': run_id,
    'created_at': datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'rules_version': rules['version'],
    'requirement_ids': requirement_ids,
    'difficulty': difficulty,
    'difficulty_rationale': rationale,
    'integration_surface': surface,
    'integration_surface_rationale': surface_why,
    'steps': steps,
    'estimated_minutes': estimated
}

os.makedirs('handoffs/' + run_id, exist_ok=True)
with open('handoffs/' + run_id + '/estimation.json', 'w') as f:
    json.dump(estimation, f, indent=2)

total_min = estimated['total']
ts = datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ')
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(ts + ' | ESTIMATE | ' + run_id + ' | D' + str(difficulty) + '/' + surface + ' | ~' + str(total_min) + 'min | OIDC-09\n')

print('Estimation created: ~' + str(total_min) + 'min total')
print('Steps: ' + str(estimated))
