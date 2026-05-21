---
id: ADM-UI-09
title: Health dashboard
stage: F5
priority: MUST
status: DRAFT
type: frontend
---

# ADM-UI-09 — Health dashboard `[MUST]`

> The Admin section SHALL include a Health page that displays the results of `GET /health/ready`: database connectivity, DB query latency, scheduler status, and service uptime. The page SHALL auto-refresh every 15 seconds.

**See:** OBS-01 (`GET /health/ready` endpoint), OBS-02 (scheduler status included), API-11 (health endpoint specification), FNFR-02 (visible indicator during refresh)
