"""
Simulation layer seed script.

Reads all company/org/process YAML files under tests/simulation/companies/
and provisions them via the real BPM platform API.

Mapping:
  company.yaml       → POST /api/v1/onboarding  (creates tenant + admin user)
  org_structure.yaml → POST /api/v1/users        (people)
                     → POST /api/v1/admin/groups (departments as groups)
                     → POST /api/v1/admin/groups/:id/members (assignments)
  process_*.yaml     → POST /api/v1/definitions  (process definitions)

Usage:
    python tests/simulation/seed.py [--dry-run] [--company <id>] [--processes-only]

Options:
    --dry-run          Parse and validate YAML only; do not call the API.
    --company <id>     Seed only one company (swiftroute | vortex | meridian).
    --processes-only   Skip tenant/user/group creation; seed process definitions only.

Environment:
    BPM_API_URL        Base URL of the running platform  (default: http://localhost:3000)
    BPM_API_TOKEN      PLATFORM_ADMIN bearer token       (required unless --dry-run)
"""

import argparse
import os
import sys
from pathlib import Path

import yaml

try:
    import httpx
    HAS_HTTP = True
except ImportError:
    HAS_HTTP = False

COMPANIES_DIR = Path(__file__).parent / "companies"
API_URL = os.environ.get("BPM_API_URL", "http://localhost:3000")
API_TOKEN = os.environ.get("BPM_API_TOKEN", "")

# BPM platform role names (must match auth.zig constants)
ROLE_MAP = {
    "role-ceo":                "PLATFORM_ADMIN",
    "role-ops-manager":        "PROCESS_OPERATOR",
    "role-dispatcher":         "TASK_WORKER",
    "role-driver":             "TASK_WORKER",
    "role-accountant":         "TASK_WORKER",
    "role-production-manager": "PROCESS_OPERATOR",
    "role-quality-manager":    "PROCESS_OPERATOR",
    "role-quality-engineer":   "TASK_WORKER",
    "role-procurement-manager":"PROCESS_OPERATOR",
    "role-production-planner": "TASK_WORKER",
    "role-line-operator":      "TASK_WORKER",
    "role-controller":         "TASK_WORKER",
    "role-credit-analyst":     "TASK_WORKER",
    "role-credit-manager":     "PROCESS_OPERATOR",
    "role-credit-director":    "PROCESS_OPERATOR",
    "role-cro":                "PLATFORM_ADMIN",
    "role-risk-analyst":       "TASK_WORKER",
    "role-risk-manager":       "PROCESS_OPERATOR",
    "role-compliance-officer": "PROCESS_OPERATOR",
    "role-loan-ops":           "TASK_WORKER",
    "role-committee-member":   "PROCESS_OPERATOR",
}


# ── YAML helpers ──────────────────────────────────────────────────────────────

def load_yaml(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def company_dirs() -> list[Path]:
    return sorted(p for p in COMPANIES_DIR.iterdir() if p.is_dir())


# ── Validation ────────────────────────────────────────────────────────────────

def validate_company(data: dict, path: Path) -> list[str]:
    errors = []
    for field in ("id", "name", "domain", "size", "bpm_config"):
        if field not in data:
            errors.append(f"{path}: missing field '{field}'")
    cfg = data.get("bpm_config", {})
    for f in ("tenant_id",):
        if f not in cfg:
            errors.append(f"{path}: missing bpm_config.{f}")
    if "contacts" not in data or "ceo" not in data.get("contacts", {}):
        errors.append(f"{path}: missing contacts.ceo (used as admin_email for onboarding)")
    return errors


def validate_org(data: dict, path: Path) -> list[str]:
    errors = []
    if "company_id" not in data:
        errors.append(f"{path}: missing company_id")
    if not data.get("people"):
        errors.append(f"{path}: no people defined")
    actor_ids = {p["actor_id"] for p in data.get("people", []) if "actor_id" in p}
    if len(actor_ids) != len(data.get("people", [])):
        errors.append(f"{path}: duplicate or missing actor_ids in people list")
    for p in data.get("people", []):
        for field in ("id", "name", "email", "actor_id"):
            if not p.get(field):
                errors.append(f"{path}: person missing field '{field}': {p}")
    return errors


def validate_process(data: dict, path: Path) -> list[str]:
    errors = []
    for field in ("id", "company_id", "name", "bpm_primitive", "nodes", "edges"):
        if field not in data:
            errors.append(f"{path}: missing field '{field}'")
    node_ids = {n["id"] for n in data.get("nodes", []) if "id" in n}
    for edge in data.get("edges", []):
        for end in ("from", "to"):
            if edge.get(end) not in node_ids:
                errors.append(f"{path}: edge {end}='{edge.get(end)}' references unknown node")
    starts = [n for n in data.get("nodes", []) if n.get("type") == "start"]
    ends   = [n for n in data.get("nodes", []) if n.get("type") == "end"]
    if len(starts) != 1:
        errors.append(f"{path}: must have exactly 1 start node (found {len(starts)})")
    if len(ends) < 1:
        errors.append(f"{path}: must have at least 1 end node")
    return errors


def validate_all(company_filter: str | None) -> list[str]:
    all_errors: list[str] = []
    for cdir in company_dirs():
        if company_filter and cdir.name != company_filter:
            continue
        company_file = cdir / "company.yaml"
        org_file     = cdir / "org_structure.yaml"
        if not company_file.exists():
            all_errors.append(f"{cdir}: missing company.yaml")
            continue
        if not org_file.exists():
            all_errors.append(f"{cdir}: missing org_structure.yaml")
        company_data = load_yaml(company_file)
        all_errors += validate_company(company_data, company_file)
        if org_file.exists():
            all_errors += validate_org(load_yaml(org_file), org_file)
        for proc_file in sorted(cdir.glob("process_*.yaml")):
            all_errors += validate_process(load_yaml(proc_file), proc_file)
    return all_errors


# ── API helpers ───────────────────────────────────────────────────────────────

def api_headers(extra: dict | None = None) -> dict:
    h = {"Authorization": f"Bearer {API_TOKEN}", "Content-Type": "application/json"}
    if extra:
        h.update(extra)
    return h


def post(client: "httpx.Client", path: str, body: dict, idempotency_key: str | None = None) -> dict:
    url = f"{API_URL}{path}"
    headers = api_headers({"idempotency-key": idempotency_key} if idempotency_key else None)
    r = client.post(url, json=body, headers=headers, timeout=15)
    if r.status_code not in (200, 201, 409):
        raise RuntimeError(f"POST {url} → {r.status_code}: {r.text[:400]}")
    return r.json()


def patch(client: "httpx.Client", path: str, body: dict) -> dict:
    url = f"{API_URL}{path}"
    r = client.patch(url, json=body, headers=api_headers(), timeout=10)
    if r.status_code not in (200, 201):
        raise RuntimeError(f"PATCH {url} → {r.status_code}: {r.text[:400]}")
    return r.json()


# ── Seed: company (tenant onboarding) ─────────────────────────────────────────

def seed_company(client: "httpx.Client", company_data: dict) -> dict:
    """
    POST /api/v1/onboarding — creates tenant + OIDC realm + admin user.
    Returns the OnboardingResult dict.
    409 means the tenant already exists; we treat that as success.
    """
    cfg = company_data["bpm_config"]
    slug = company_data["id"]                       # e.g. "swiftroute"
    admin_email = company_data["contacts"]["ceo"]

    # Derive admin username from email local part
    admin_username = admin_email.split("@")[0].replace(".", "_")

    body = {
        "slug":               slug,
        "display_name":       company_data["name"],
        "admin_email":        admin_email,
        "admin_username":     admin_username,
        "admin_display_name": company_data["name"] + " Admin",
        "hostname":           cfg.get("hostname", f"{slug}.bpm.example"),
    }

    # Use stable idempotency key based on slug so re-runs are safe
    idem = f"seed-onboard-{slug}"
    result = post(client, "/api/v1/onboarding", body, idempotency_key=idem)
    tenant_id = result.get("tenant_id", cfg["tenant_id"])
    print(f"  tenant  {tenant_id}  (onboarding_id={result.get('onboarding_id', '?')})")
    return result


# ── Seed: org structure (users + groups) ──────────────────────────────────────

def seed_users(client: "httpx.Client", org_data: dict) -> dict[str, str]:
    """
    POST /api/v1/users for each person.
    Returns mapping actor_id → user_id.
    """
    actor_to_user: dict[str, str] = {}
    for person in org_data.get("people", []):
        # Derive a stable username from the email local part
        username = person["email"].split("@")[0].replace(".", "_")
        body = {
            "username":     username,
            "display_name": person["name"],
            "email":        person["email"],
            "status":       "ACTIVE",
        }
        result = post(client, "/api/v1/users", body)
        user_id = result.get("user_id", result.get("id", ""))
        actor_to_user[person["actor_id"]] = user_id
        print(f"    user  {username}  ({user_id})")
    return actor_to_user


def seed_groups(client: "httpx.Client", org_data: dict, actor_to_user: dict[str, str]) -> None:
    """
    POST /api/v1/admin/groups for each department, then add members.
    """
    # Build department → person list mapping
    dept_people: dict[str, list[dict]] = {}
    for person in org_data.get("people", []):
        dept_id = person.get("department_id", "dept-default")
        dept_people.setdefault(dept_id, []).append(person)

    for dept in org_data.get("departments", []):
        body = {
            "name":         dept["id"],
            "display_name": dept["name"],
            "description":  f"Department group for {dept['name']}",
        }
        result = post(client, "/api/v1/admin/groups", body)
        group_id = result.get("group_id", result.get("id", ""))
        print(f"    group {dept['name']}  ({group_id})")

        # Add department members
        for person in dept_people.get(dept["id"], []):
            user_id = actor_to_user.get(person["actor_id"])
            if not user_id:
                print(f"      WARN: no user_id for {person['actor_id']} — skipping group assignment")
                continue
            post(client, f"/api/v1/admin/groups/{group_id}/members", {"user_id": user_id})

    print(f"    groups {len(org_data.get('departments', []))} created/verified")


# ── Seed: process definitions ─────────────────────────────────────────────────

def seed_process(client: "httpx.Client", proc_data: dict) -> None:
    """
    POST /api/v1/definitions — registers a process definition then activates it.
    """
    body = {
        "name":    proc_data["name"],
        "nodes":   proc_data.get("nodes", []),
        "edges":   proc_data.get("edges", []),
        "metadata": {
            "simulation_id":  proc_data["id"],
            "company_id":     proc_data["company_id"],
            "bpm_primitive":  proc_data.get("bpm_primitive"),
            "description":    str(proc_data.get("description", "")).strip(),
            "version":        proc_data.get("version", "1.0"),
        },
    }
    result = post(client, "/api/v1/definitions", body)
    def_id = result.get("id", result.get("definition_id", "?"))
    print(f"    def   {proc_data['name']}  ({def_id})")

    # Activate if still in DRAFT
    if result.get("status") == "DRAFT":
        try:
            post(client, f"/api/v1/definitions/{def_id}/activate", {})
            print(f"          → activated")
        except RuntimeError as e:
            print(f"          → activate skipped: {e}")


# ── Orchestrate one company ───────────────────────────────────────────────────

def seed_one_company(client: "httpx.Client", cdir: Path, processes_only: bool = False) -> None:
    company_data = load_yaml(cdir / "company.yaml")
    org_data     = load_yaml(cdir / "org_structure.yaml")

    print(f"\n[{company_data['id']}] {company_data['name']}")

    if not processes_only:
        seed_company(client, company_data)
        actor_to_user = seed_users(client, org_data)
        seed_groups(client, org_data, actor_to_user)

    for proc_file in sorted(cdir.glob("process_*.yaml")):
        seed_process(client, load_yaml(proc_file))


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--dry-run",        action="store_true", help="validate only, no API calls")
    parser.add_argument("--company",        metavar="ID",        help="seed one company only")
    parser.add_argument("--processes-only", action="store_true", help="skip tenant/users/groups, seed definitions only")
    args = parser.parse_args()

    errors = validate_all(args.company)
    if errors:
        print("VALIDATION ERRORS:")
        for e in errors:
            print(f"  {e}")
        sys.exit(1)

    dirs = [d for d in company_dirs() if not args.company or d.name == args.company]
    print(f"Validation OK — {len(dirs)} company/companies")

    if args.dry_run:
        print("Dry-run mode — no API calls made.")
        return

    if not HAS_HTTP:
        print("ERROR: httpx not installed.  Run: pip install httpx pyyaml")
        sys.exit(1)

    if not API_TOKEN:
        print("ERROR: BPM_API_TOKEN environment variable is required.")
        sys.exit(1)

    with httpx.Client() as client:
        for cdir in dirs:
            seed_one_company(client, cdir, processes_only=args.processes_only)

    print("\nSeed complete.")


if __name__ == "__main__":
    main()
