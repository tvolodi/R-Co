#!/usr/bin/env bash
#
# run-test-integration.sh — Run `zig build test-integration` with the -j cap from
# BPM_TEST_INTEGRATION_JOB_CAP applied. Required because Zig 0.16 removed
# Step.setJobs() — the build-runner's -j flag is the only mechanism that
# actually constrains concurrency.
#
# Usage:
#     ./scripts/run-test-integration.sh                  # default cap = 8
#     BPM_TEST_INTEGRATION_JOB_CAP=4 ./scripts/run-test-integration.sh
#
# Override at the call site with --jobs <N> (env var wins if both are set):
#     ./scripts/run-test-integration.sh --jobs 4
#
# The -j flag is also accepted by `zig build` itself; if you invoke
# `zig build test-integration` directly without this wrapper, supply
# -j8 (or your preferred cap) explicitly. This wrapper exists to make
# the env-var knob actually take effect by default.
#
# ISS-0692 / GH-752 (REWORK 1). Authoritative reference:
# docs/guides/test_developer_guide.md §10.2.
#
# SPDX-License-Identifier: same as parent project.

set -u

CAP_OVERRIDE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs)
            shift
            if [[ $# -lt 1 ]] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
                echo "[run-test-integration] --jobs requires a positive integer argument" >&2
                exit 2
            fi
            CAP_OVERRIDE="$1"
            shift
            ;;
        --jobs=*)
            CAP_OVERRIDE="${1#--jobs=}"
            if ! [[ "$CAP_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
                echo "[run-test-integration] --jobs value must be a positive integer (got '$CAP_OVERRIDE')" >&2
                exit 2
            fi
            shift
            ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "[run-test-integration] unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# Resolve cap: --jobs flag > BPM_TEST_INTEGRATION_JOB_CAP > 4 (default).
# Default lowered 8 -> 4 by REWORK 2 (ISS-0692): empirical sweep on this host
# showed -j4 gives a far better failure-rate/wall-time tradeoff than -j8 when
# 30+ binaries all queue on pg_advisory_lock('bpm_test_migrations_public').
# See tests/reports/ISS-0692-step03-rework2-sweep.md for the data.
if [[ "$CAP_OVERRIDE" -gt 0 ]]; then
    cap="$CAP_OVERRIDE"
else
    raw="${BPM_TEST_INTEGRATION_JOB_CAP:-4}"
    if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
        cap="$raw"
    else
        echo "[run-test-integration] BPM_TEST_INTEGRATION_JOB_CAP='$raw' is not a positive integer; falling back to default 4." >&2
        cap=4
    fi
fi

if [[ "$cap" -lt 1 ]]; then
    cap=1
fi

echo "[run-test-integration] using -j$cap (BPM_TEST_INTEGRATION_JOB_CAP=${BPM_TEST_INTEGRATION_JOB_CAP:-})"

zig build test-integration --summary all "-j$cap"
exit $?