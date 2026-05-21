# fn:register-inner-report

**Category:** CTRL  
**Used by:** ALL agents — **MANDATORY before every `fn:complete-handoff` call**  
**Calls:** —

```
PURPOSE: Log what the agent did, what it changed, and what the next agent needs to know.
         This is the permanent audit trail. The handoff result field is for ORCH routing;
         the inner report is for human review and debugging.

INPUT: agent_id, run_id, step, summary, files_changed[], tests_run[], issues_found[], next_steps[]

1. Collect:
   - List of every file created or modified during this task
   - Summary of tests run and their pass/fail status
   - Any issues found (even MINOR — include everything)
   - Recommended next steps for the Orchestrator

2. Build the report object:
   {
     ""report_id"": ""<run_id>-step-<step>-<agent_id_slug>"",
     ""agent_id"": ""<AGENT_ID>"",
     ""run_id"": ""<run_id>"",
     ""step"": ""<step>"",
     ""created_at"": ""<ISO8601 UTC>"",
     ""summary"": ""<one paragraph: what was done, what passed, what failed>"",
     ""files_created"": [""<relative path>"", ...],
     ""files_modified"": [""<relative path>"", ...],
     ""tests_run"": [{""name"": ""<test>"", ""status"": ""pass|fail|skip"", ""detail"": ""...""}],
     ""issues_found"": [{""severity"": ""BLOCKER|MAJOR|MINOR"", ""description"": ""...""}],
     ""next_steps"": [""<recommended action>"", ...],
     ""blockers"": [""<description if any>""]
   }

3. Write to: docs/issue-reports/<run_id>-step-<step>-<agent_id_slug>-INNER-REPORT.json

4. Return report_id and file path
```

**Rule:** An agent that completes without calling `fn:register-inner-report` has violated the workflow. The handoff result `summary` field is NOT a substitute for this report.
