---
id: ADM-UI-10
title: Metrics viewer
stage: F5
priority: SHOULD
status: DRAFT
type: frontend
---

# ADM-UI-10 — Metrics viewer `[SHOULD]`

> The Admin section SHOULD include a Metrics page that fetches raw Prometheus text from `GET /metrics` and renders it as a human-readable table grouped by metric family (metric name, labels, value, help text).

**See:** OBS-05 (`GET /metrics` Prometheus-format endpoint), API-12 (metrics endpoint), ADM-UI-09 (Health page — metrics viewer is a sibling sub-section)
