import json

for fname in ['WF02-oidc01-20260527.json', 'WF02-oidc02-20260527.json']:
    with open(f'docs/metrics/retrospectives/{fname}', encoding='utf-8-sig') as f:
        r = json.load(f)
    print(f'--- {fname} ---')
    print(f'  difficulty={r.get("difficulty")}')
    for step_name, data in r.get('steps', {}).items():
        var = data.get('variance_pct', 0)
        if abs(var) > 25:
            print(f'  {step_name}: variance={var:.1f}% (est={data.get("estimated_min")}, actual={data.get("actual_min")})')
