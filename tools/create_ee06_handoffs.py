import json, datetime, os

run_id = 'WF02-ee06-20260522'
os.makedirs(f'handoffs/{run_id}', exist_ok=True)

now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

handoffs = []

# Step 01 — CODE-DESIGNER
h01 = {
    'handoff_id': 'ee060001-2605-4000-8006-202605220001',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '01',
    'from_agent': 'ORCH',
    'to_agent': 'CODE-DESIGNER',
    'created_at': now,
    'started_at': None,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 — Execution Engine',
        'requirement_ids': ['EE-06'],
        'related_handoff_ids': [
            'ee050001-2605-4000-8005-202605220001'
        ],
        'artifacts_in': [
            'docs/BPM_Platform_Functional_Requirements.md',
            'docs/guides/backend_developer_guide.md',
            'src/design/engine.md',
            'src/engine/transition.zig'
        ]
    },
    'task': {
        'description': (
            "Append an EE-06 design section to `src/design/engine.md` for Parallel Gateway (split).\n\n"
            "EE-06 requirement summary:\n"
            "- A PARALLEL_GATEWAY SHALL activate all outgoing edges simultaneously, creating concurrent execution tokens. Each token progresses independently.\n"
            "- GIVEN the execution token reaches a PARALLEL_GATEWAY with N outgoing edges, WHEN evaluated, THEN N independent execution tokens are created simultaneously, one per outgoing edge.\n"
            "- Each token progresses independently; task completions on one branch do not block other branches.\n"
            "- The split event MUST be recorded in the event log.\n"
            "- All N tokens are created in a single transaction (DB-03).\n\n"
            "First read `src/design/engine.md` in full — it already contains EE-01 through EE-05 sections. Also read `src/engine/transition.zig` to understand the current token model and the `EngineState` / `Token` structures already in use.\n\n"
            "The new EE-06 design section MUST cover:\n\n"
            "1. **Parallel split algorithm in `transition.zig`** — extend `processNodeEntry` for `PARALLEL_GATEWAY`:\n"
            "   a. Collect all outgoing edges of the current PARALLEL_GATEWAY node from the definition snapshot.\n"
            "   b. Remove the arriving token from `state.tokens`.\n"
            "   c. For each outgoing edge, create a new `Token` with a unique ID (e.g. uuid4()), the target node ID, and the current instance variable snapshot.\n"
            "   d. Append all new tokens to `state.tokens`.\n"
            "   e. Append a `PARALLEL_SPLIT` event to `state.pending_events` capturing: source node ID, list of target node IDs, count of new tokens, and the instance variable snapshot.\n"
            "   f. For each new token, call `processNodeEntry` recursively on the target node to activate it (task nodes become TASK_ACTIVATED; gateway nodes recurse as needed).\n"
            "   g. The entire operation completes within the single DB transaction opened by the caller (DB-03 compliance is the caller's responsibility, not transition.zig's).\n\n"
            "2. **Token uniqueness guarantee** — describe how each new token gets a globally unique ID (UUIDv4 generated at split time). Token IDs must be stored so that EE-07 (join) can count distinct arriving tokens.\n\n"
            "3. **`PARALLEL_SPLIT` event schema** in the event store:\n"
            "   ```\n"
            "   {\n"
            '     "type": "PARALLEL_SPLIT",\n'
            '     "source_node_id": "<gateway-node-id>",\n'
            '     "token_ids": ["<tok-1>", "<tok-2>", ...],\n'
            '     "target_node_ids": ["<node-1>", "<node-2>", ...],\n'
            '     "edge_count": N\n'
            "   }\n"
            "   ```\n\n"
            "4. **Updated `EngineState` / `Token` structures** (if needed):\n"
            "   - Describe any additions required (e.g. a `parent_split_node_id` field on `Token` so EE-07 can group tokens by their originating split).\n"
            "   - If the existing `Token` struct already supports this, state that explicitly.\n\n"
            "5. **Traceability table** — map each EE-06 acceptance criterion to the design element:\n"
            "   | AC | Design element |\n"
            "   |---|---|\n"
            "   | N tokens created for N outgoing edges | For-loop over outgoing edges in PARALLEL_GATEWAY handler |\n"
            "   | Each token progresses independently | Separate Token entries in state.tokens; recursive processNodeEntry per token |\n"
            "   | Split event recorded in event log | PARALLEL_SPLIT event appended to state.pending_events |\n"
            "   | All N tokens in single transaction | Caller holds DB transaction; transition.zig is pure (no I/O) |\n\n"
            "Append the new section as `## Section EE-06: Parallel Gateway — Split` after the `## Section EE-05` section in `src/design/engine.md`.\n\n"
            "Do NOT write any Zig implementation code — design only.\n"
            "Do NOT modify existing EE-01 through EE-05 sections.\n\n"
            "Before completing this handoff, verify all 5 design elements above are present and the traceability table covers all 4 EE-06 acceptance criteria, then complete the handoff."
        ),
        'acceptance_criteria': [
            'src/design/engine.md contains an EE-06 section covering all 5 design elements',
            'Parallel split algorithm is fully specified with steps a-g',
            'PARALLEL_SPLIT event schema is specified',
            'Token uniqueness guarantee is described',
            'Traceability table maps all 4 EE-06 acceptance criteria',
            'No Zig implementation code in the design file',
            'Existing EE-01 through EE-05 sections are not modified'
        ],
        'functions_to_call': [
            'fn:validate-completeness',
            'fn:register-inner-report',
            'fn:complete-handoff'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}
handoffs.append(('step-01-code-designer.json', h01))

# Step 02 — BACKEND-DEV
h02 = {
    'handoff_id': 'ee060002-2605-4000-8006-202605220002',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '02',
    'from_agent': 'ORCH',
    'to_agent': 'BACKEND-DEV',
    'created_at': now,
    'started_at': None,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 — Execution Engine',
        'requirement_ids': ['EE-06'],
        'related_handoff_ids': [
            'ee060001-2605-4000-8006-202605220001'
        ],
        'artifacts_in': [
            'src/design/engine.md',
            'src/engine/transition.zig',
            'docs/BPM_Platform_Functional_Requirements.md'
        ]
    },
    'task': {
        'description': (
            "Implement EE-06 — Parallel Gateway (split) per the design section `## Section EE-06` in `src/design/engine.md`.\n\n"
            "Read the design file in full before starting. Then read `src/engine/transition.zig` to understand the current implementation of `processNodeEntry` (EXCLUSIVE_GATEWAY handler is already there from EE-05).\n\n"
            "Implementation steps:\n\n"
            "1. In `src/engine/transition.zig`, add a `.PARALLEL_GATEWAY` branch to `processNodeEntry` that implements the parallel split algorithm from the design:\n"
            "   a. Collect all outgoing edges for the current gateway node from `snapshot.edges`.\n"
            "   b. Remove the arriving token from the engine state tokens list.\n"
            "   c. For each outgoing edge, create a new `Token` with a fresh UUIDv4 ID, the target node, and the current variable snapshot.\n"
            "   d. Append each new token to the state tokens list.\n"
            "   e. Append a `PARALLEL_SPLIT` event to `state.pending_events` with: source node ID, list of new token IDs, list of target node IDs, and edge count.\n"
            "   f. For each new token, call `processNodeEntry` recursively on the target node.\n\n"
            "2. If `Token` struct needs a `parent_split_node_id` field (as described in the design), add it. Update all existing Token construction sites to include the new field (null for non-split tokens).\n\n"
            "3. Add unit tests in `src/engine/transition.zig` (in the `test` block):\n"
            "   - TC-EE-06-01: PARALLEL_GATEWAY with 2 outgoing edges -> 2 tokens created; 1 PARALLEL_SPLIT event appended.\n"
            "   - TC-EE-06-02: PARALLEL_GATEWAY with 3 outgoing edges -> 3 tokens created with unique IDs.\n"
            "   - TC-EE-06-03: Original token is removed after split (state.tokens has N not N+1).\n"
            "   - TC-EE-06-04: Each new token targets the correct next node per the definition edges.\n"
            "   - TC-EE-06-05: PARALLEL_SPLIT event records correct source_node_id, token_ids, target_node_ids, edge_count.\n\n"
            "Validation (ALL must pass):\n"
            "```\n"
            "zig build\n"
            "zig build test\n"
            "```\n\n"
            "Self-review checklist:\n"
            "- [ ] `src/engine/transition.zig` has zero I/O (pure function — absolute rule)\n"
            "- [ ] No SQL string interpolation of user data\n"
            "- [ ] All allocating functions accept std.mem.Allocator\n"
            "- [ ] `zig build` exits 0\n"
            "- [ ] `zig build test` exits 0\n"
        ),
        'acceptance_criteria': [
            'PARALLEL_GATEWAY handler implemented in processNodeEntry',
            'N tokens created for N outgoing edges with unique UUIDv4 IDs',
            'Original arriving token removed from state',
            'PARALLEL_SPLIT event appended to state.pending_events',
            'processNodeEntry called recursively for each new token target',
            'All 5 unit tests (TC-EE-06-01 through TC-EE-06-05) pass',
            'zig build exits 0',
            'zig build test exits 0',
            'transition.zig has zero I/O'
        ],
        'functions_to_call': [
            'fn:validate-completeness',
            'fn:register-inner-report',
            'fn:complete-handoff'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}
handoffs.append(('step-02-backend-dev.json', h02))

# Step 03 — TEST-DESIGNER
h03 = {
    'handoff_id': 'ee060003-2605-4000-8006-202605220003',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '03',
    'from_agent': 'ORCH',
    'to_agent': 'TEST-DESIGNER',
    'created_at': now,
    'started_at': None,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 — Execution Engine',
        'requirement_ids': ['EE-06'],
        'related_handoff_ids': [
            'ee060002-2605-4000-8006-202605220002'
        ],
        'artifacts_in': [
            'src/engine/transition.zig',
            'src/design/engine.md',
            'docs/BPM_Platform_Functional_Requirements.md',
            'docs/guides/test_developer_guide.md'
        ]
    },
    'task': {
        'description': (
            "Write a test specification for EE-06 — Parallel Gateway (split).\n\n"
            "Read the test guide, the EE-06 requirement in the functional requirements doc, and the implementation in `src/engine/transition.zig`.\n\n"
            "Produce `tests/specs/EE-06.md` covering:\n"
            "1. All 4 EE-06 acceptance criteria mapped to test cases\n"
            "2. Happy-path: 2-way split, 3-way split\n"
            "3. Edge case: PARALLEL_GATEWAY with 1 outgoing edge (degenerate split)\n"
            "4. Edge case: parallel split where one branch immediately hits a task node (TASK_ACTIVATED event), other hits another gateway\n"
            "5. Token uniqueness: all token IDs in a split are distinct\n"
            "6. Event log: PARALLEL_SPLIT event contains correct metadata\n\n"
            "Also verify the unit tests already in `src/engine/transition.zig` (TC-EE-06-01 through TC-EE-06-05) pass by reading their assertions and confirming they cover the spec.\n\n"
            "Do NOT run any terminal commands — write the spec file only."
        ),
        'acceptance_criteria': [
            'tests/specs/EE-06.md exists and covers all 4 EE-06 acceptance criteria',
            'All 6 scenario categories above are addressed',
            'Spec references TC-EE-06-01 through TC-EE-06-05 from transition.zig'
        ],
        'functions_to_call': [
            'fn:validate-completeness',
            'fn:register-inner-report',
            'fn:complete-handoff'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}
handoffs.append(('step-03-test-designer.json', h03))

# Step 04 — TEST-RUNNER
h04 = {
    'handoff_id': 'ee060004-2605-4000-8006-202605220004',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '04',
    'from_agent': 'ORCH',
    'to_agent': 'TEST-RUNNER',
    'created_at': now,
    'started_at': None,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 — Execution Engine',
        'requirement_ids': ['EE-06'],
        'related_handoff_ids': [
            'ee060003-2605-4000-8006-202605220003'
        ],
        'artifacts_in': [
            'tests/specs/EE-06.md',
            'src/engine/transition.zig'
        ]
    },
    'task': {
        'description': (
            "Run all unit tests and verify EE-06 test cases pass.\n\n"
            "Commands to run:\n"
            "```\n"
            "zig build test\n"
            "```\n\n"
            "Capture full output. Write a structured test report to `tests/reports/WF02-ee06-20260522-test-run.json`.\n\n"
            "Report format: { run_id, timestamp, command, exit_code, tests_run, tests_passed, tests_failed, failed_tests: [...], issues: [...] }\n\n"
            "If any test fails, set result.status to FAIL and list each failing test name and error in result.issues."
        ),
        'acceptance_criteria': [
            'zig build test exits 0',
            'TC-EE-06-01 through TC-EE-06-05 all pass',
            'Test report written to tests/reports/WF02-ee06-20260522-test-run.json'
        ],
        'functions_to_call': [
            'fn:run-tests',
            'fn:register-inner-report',
            'fn:complete-handoff'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}
handoffs.append(('step-04-test-runner.json', h04))

# Step 05 — RELEASE-VALIDATOR
h05 = {
    'handoff_id': 'ee060005-2605-4000-8006-202605220005',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '05',
    'from_agent': 'ORCH',
    'to_agent': 'RELEASE-VALIDATOR',
    'created_at': now,
    'started_at': None,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 — Execution Engine',
        'requirement_ids': ['EE-06'],
        'related_handoff_ids': [
            'ee060004-2605-4000-8006-202605220004'
        ],
        'artifacts_in': [
            'tests/reports/WF02-ee06-20260522-test-run.json',
            'docs/BPM_Platform_Functional_Requirements.md',
            'docs/status/requirement_status.json'
        ]
    },
    'task': {
        'description': (
            "Validate that EE-06 (Parallel Gateway split) meets all MUST acceptance criteria and is ready for release.\n\n"
            "Checks to perform:\n"
            "1. Read the test report from `tests/reports/WF02-ee06-20260522-test-run.json` — all tests must pass.\n"
            "2. Verify `zig build` exits 0.\n"
            "3. Verify the 4 EE-06 acceptance criteria are each addressed by passing tests:\n"
            "   - N tokens created for N outgoing edges simultaneously\n"
            "   - Each token progresses independently\n"
            "   - Split event recorded in event log\n"
            "   - All N tokens created in a single transaction (purity of transition.zig means no I/O — verify no DB calls in transition.zig)\n"
            "4. If all checks pass, write the release decision to `docs/status/release-EE06-20260522.json` with status RELEASED.\n"
            "5. Update `docs/status/requirement_status.json`: set EE-06 status to RELEASED."
        ),
        'acceptance_criteria': [
            'All EE-06 unit tests pass (zig build test exits 0)',
            'zig build exits 0',
            'All 4 EE-06 acceptance criteria verified',
            'docs/status/release-EE06-20260522.json created with RELEASED status',
            'docs/status/requirement_status.json updated: EE-06 = RELEASED'
        ],
        'functions_to_call': [
            'fn:check-zig-build',
            'fn:validate-acceptance-criteria',
            'fn:register-inner-report',
            'fn:complete-handoff'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}
handoffs.append(('step-05-release-validator.json', h05))

# Step 06 — DOC-UPDATER
h06 = {
    'handoff_id': 'ee060006-2605-4000-8006-202605220006',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '06',
    'from_agent': 'ORCH',
    'to_agent': 'DOC-UPDATER',
    'created_at': now,
    'started_at': None,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 — Execution Engine',
        'requirement_ids': ['EE-06'],
        'related_handoff_ids': [
            'ee060005-2605-4000-8006-202605220005'
        ],
        'artifacts_in': [
            'docs/status/release-EE06-20260522.json',
            'CHANGELOG.md',
            'docs/status/requirement_status.json',
            'handoffs/WF02-ee06-20260522/estimation.json'
        ]
    },
    'task': {
        'description': (
            "Update documentation after successful release of EE-06 — Parallel Gateway (split).\n\n"
            "Tasks:\n"
            "1. Append an entry to `CHANGELOG.md` under the current date with: requirement EE-06 RELEASED, "
            "description of what was implemented (parallel split in transition.zig, PARALLEL_SPLIT event, N-token creation).\n"
            "2. Confirm `docs/status/requirement_status.json` has EE-06 = RELEASED (RELEASE-VALIDATOR should have set this; verify and fix if not).\n"
            "3. Run the retrospective for run WF02-ee06-20260522 per `docs/agents/metrics.md section 6`:\n"
            "   - Read `handoffs/WF02-ee06-20260522/estimation.json`\n"
            "   - Compute actual work time per step from started_at / completed_at in each step handoff\n"
            "   - Compare estimated vs actual, compute variance_pct per step and overall\n"
            "   - If |variance_pct| > 25% for a step across >= 2 consecutive runs at same difficulty, adjust `docs/metrics/estimation_rules.json`\n"
            "   - Write `docs/metrics/retrospectives/WF02-ee06-20260522.json`\n"
            "4. Complete this handoff."
        ),
        'acceptance_criteria': [
            'CHANGELOG.md updated with EE-06 entry',
            'docs/status/requirement_status.json: EE-06 = RELEASED',
            'docs/metrics/retrospectives/WF02-ee06-20260522.json written',
            'Handoff marked COMPLETED'
        ],
        'functions_to_call': [
            'fn:update-changelog',
            'fn:update-requirement-status',
            'fn:register-inner-report',
            'fn:complete-handoff'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}
handoffs.append(('step-06-doc-updater.json', h06))

# Write all handoff files
run_dir = f'handoffs/{run_id}'
for fname, h in handoffs:
    fpath = os.path.join(run_dir, fname)
    with open(fpath, 'w') as f:
        json.dump(h, f, indent=2)
    print('Created:', fpath)

# Update registry
with open('handoffs/registry.json') as f:
    registry = json.load(f)

for fname, h in handoffs:
    registry['entries'].append({
        'handoff_id': h['handoff_id'],
        'file': f'handoffs/{run_id}/{fname}',
        'run_id': run_id,
        'step': h['step'],
        'from_agent': h['from_agent'],
        'to_agent': h['to_agent'],
        'created_at': h['created_at'],
        'status': h['status'],
        'stage': 'Stage 3 — Execution Engine'
    })

with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)
print('Registry updated.')

# Log to orchestrator.log
with open('handoffs/orchestrator.log', 'a') as f:
    for fname, h in handoffs:
        f.write(now + ' | ROUTE | ' + run_id + ' | ' + h['handoff_id'][:8] + ' | ORCH -> ' + h['to_agent'] + ' | PENDING\n')
    f.write(now + ' | ESTIMATE | ' + run_id + ' | D4 | ~140min | EE-06\n')
print('Orchestrator log updated.')
