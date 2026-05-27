import json, os, sys

retro_dir = "docs/metrics/retrospectives"
target_fnames = [f for f in os.listdir(retro_dir) if "oidc" in f and f.endswith(".json")]

prev_results = {}

for fname in sorted(target_fnames):
    with open(os.path.join(retro_dir, fname), encoding="utf-8-sig") as f:
        r = json.load(f)
    diff = r.get("difficulty")
    print(f"\n--- {fname} (difficulty={diff}) ---")
    for s in r.get("steps", []):
        v = s.get("variance_pct", 0)
        step_label = f"{s.get('step','?')} {s.get('agent','?')}"
        est = s.get("estimated_minutes", "?")
        act = s.get("actual_minutes", "?")
        if abs(v) > 25:
            print(f"  {step_label}: variance={v:.1f}% est={est} actual={act}")
        # Track for consecutive run check
        if diff == 4:
            key = s.get("agent", "?")
            if key not in prev_results:
                prev_results[key] = []
            prev_results[key].append(abs(v) > 25)

print("\n\n=== Consecutive difficulty-4 runs with >25% variance ===")
for agent, results in prev_results.items():
    consecutive = 0
    for r in results:
        if r:
            consecutive += 1
        else:
            consecutive = 0
        if consecutive >= 2:
            print(f"  {agent}: {consecutive} consecutive runs with >25% variance (last run)")
