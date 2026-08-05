#!/usr/bin/env python3
"""Print the current time as an ISO-8601 UTC instant. The only sanctioned way
to obtain a timestamp for a handoff, the registry, or orchestrator.log.

Why a tool for one line of code
-------------------------------
The pipeline's timestamp rule was never ambiguous -- CLAUDE.md mandates
`(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")` in five places.
It still produced 149 handoffs whose completed_at precedes their started_at,
because the *near-miss* variants are visually identical in their output:

    (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")  -> 06:25:12Z  correct
    (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")                    -> 11:25:12Z  local, labelled Z
    datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ")         -> 11:25:12Z  local, labelled Z

Drop one method call and you get local time wearing a UTC suffix. Nothing in
the string says which one you ran. The 2026-08-05 analysis found the resulting
inversions cluster at whole-hour offsets (4h x27, 5h x18, 11h x25) -- the
signature of timezone drift, not of invented timestamps, and it happens *within
a single run* when ORCH and its subagents resolve the clock differently.

This tool removes the footgun: there is no argument you can omit that silently
downgrades it to local time.

Usage:
    python3 tools/utcnow.py            # 2026-08-05T06:25:12Z
    python3 tools/utcnow.py --check ISO8601
                                       # exit 0 if the given stamp is within
                                       # --tolerance of now; exit 1 otherwise
    python3 tools/utcnow.py --offset   # report this host's UTC offset

Exit codes: 0 ok, 1 check failed, 2 bad invocation.
"""

from __future__ import annotations

import argparse
import datetime
import sys

ISO_FMT = "%Y-%m-%dT%H:%M:%SZ"


def utcnow() -> datetime.datetime:
    """Timezone-aware current UTC. Never returns naive local time."""
    return datetime.datetime.now(datetime.timezone.utc)


def format_utc(moment: datetime.datetime) -> str:
    return moment.strftime(ISO_FMT)


def parse_stamp(text: str) -> datetime.datetime | None:
    try:
        naive = datetime.datetime.strptime(text.strip(), ISO_FMT)
    except ValueError:
        return None
    return naive.replace(tzinfo=datetime.timezone.utc)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Print or validate an ISO-8601 UTC timestamp for pipeline bookkeeping."
    )
    parser.add_argument(
        "--check",
        metavar="ISO8601",
        help="verify a timestamp is genuine UTC (within --tolerance of now)",
    )
    parser.add_argument(
        "--tolerance",
        type=int,
        default=3600,
        help="seconds of allowed drift for --check (default 3600)",
    )
    parser.add_argument(
        "--offset",
        action="store_true",
        help="print this host's local-to-UTC offset and exit",
    )
    args = parser.parse_args(argv[1:])

    if args.offset:
        local = datetime.datetime.now().astimezone()
        offset = local.utcoffset() or datetime.timedelta(0)
        hours = offset.total_seconds() / 3600.0
        print(f"local={local.strftime('%Y-%m-%dT%H:%M:%S')} {local.tzname()}")
        print(f"utc  ={format_utc(utcnow())}")
        print(f"offset={hours:+.1f}h")
        if abs(hours) > 0.01:
            print(
                "note: this host is NOT on UTC. A timestamp that omits the UTC "
                f"conversion will be wrong by {hours:+.1f}h while still ending in 'Z'."
            )
        return 0

    if args.check:
        stamp = parse_stamp(args.check)
        if stamp is None:
            print(f"INVALID: {args.check!r} is not {ISO_FMT}", file=sys.stderr)
            return 1
        drift = abs((utcnow() - stamp).total_seconds())
        if drift > args.tolerance:
            hours = drift / 3600.0
            print(
                f"SUSPECT: {args.check} is {hours:.1f}h from now "
                f"({format_utc(utcnow())}). If this host is not on UTC, the stamp was "
                "probably taken from local time and labelled 'Z'. "
                "Re-run: python3 tools/utcnow.py",
                file=sys.stderr,
            )
            return 1
        print(f"OK: {args.check} is within {args.tolerance}s of now")
        return 0

    print(format_utc(utcnow()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
