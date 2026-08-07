# Bookkeeping commit timing — orchestrator.log may need a second commit

## The trap
When the TEST-DESIGNER (or any agent) workflow produces a handoff
JSON, a registry update, and an orchestrator.log append, the commit
sequence is normally:

```bash
git add handoffs/<run>/step-N-*.json handoffs/registry.json
# append log line via python (after git add!)
echo "appended log line" >> handoffs/orchestrator.log
git -c user.email=... -c user.name=... commit -m "..."
```

The `>>` redirect (or the python append) happens AFTER `git add`. Git
stages the version of the file at the moment of `git add`. The
post-`git add` modification is therefore NOT in the commit. After
`git commit`, the working tree still shows `M handoffs/orchestrator.log`
(unstaged). `git status -s` then shows:
```
M handoffs/orchestrator.log
?? memories/
```

This is not a defect — the log append is preserved on disk — but
`handoffs/orchestrator.log` is a tracked audit-trail file per
CLAUDE.md "Bookkeeping Is Not Optional" and CLAUDE.md "Workflow
artifacts are committed to git (mandatory)". Leaving the log
uncommitted leaves the run's audit trail split between the commit
and the working tree.

## Confirmed in this repo (2026-08-08, WF03-GH526 Step 4)
The single-commit pattern captured the spec, test, handoff JSON,
registry, and inner report, but NOT the log append. `git status -s`
showed `M handoffs/orchestrator.log` after the push. A second commit
fixed it:
```bash
git add handoffs/orchestrator.log
git -c user.email=... -c user.name=... commit -m "chore(WF03-GH526): append Step 4 TEST-DESIGNER COMPLETE to orchestrator.log"
git push origin feature/WF03-GH526-20260807
```

## Lesson
After any handoff completion, check `git status -s` for any tracked
file that still shows as `M` (modified but unstaged). If the only
uncommitted change is a tracked bookkeeping file like
`handoffs/orchestrator.log`, commit it before reporting PASS.
Alternative pattern: stage the log line BEFORE `git add` (use a
`tee -a` on the append), so a single commit captures everything.
The two-commit pattern is more transparent in `git log` and easier
to debug.
