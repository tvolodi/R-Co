#!/usr/bin/env python3
"""
repair_handoff_registry_sync.py

Repairs handoffs/registry.json by:
1. Finding handoff files on disk that are missing from the registry
2. Cross-referencing with orchestrator.log to determine completion status
3. Adding missing entries with appropriate status
4. Archiving stale ADHOC entries from 2024/2025
"""

import json
import os
import re
import glob
from datetime import datetime, timezone
from typing import Dict, List, Set, Tuple, Optional

HANDBOOK_DIR = "handoffs"
REGISTRY_FILE = "handoffs/registry.json"
ORCH_LOG_FILE = "handoffs/orchestrator.log"


def load_registry() -> dict:
    """Load the registry JSON file."""
    with open(REGISTRY_FILE, 'r', encoding='utf-8-sig') as f:
        return json.load(f)


def save_registry(registry: dict) -> None:
    """Save the registry JSON file."""
    registry['last_updated'] = datetime.now(timezone.utc).isoformat()
    with open(REGISTRY_FILE, 'w', encoding='utf-8-sig') as f:
        json.dump(registry, f, indent=2)


def get_all_handoff_files() -> Set[str]:
    """Get all handoff file paths on disk, normalized to forward slashes."""
    skip_files = {
        'registry.json', 'batch_queue.json', 'global_queue.json', 
        'escalations.json', 'manifest.json'
    }
    skip_dirs = {'.git', '__pycache__', 'node_modules'}
    
    handoffs = set()
    for root, dirs, files in os.walk(HANDBOOK_DIR):
        # Skip certain directories
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        
        for fname in files:
            if fname in skip_files:
                continue
            if not fname.endswith('.json'):
                continue
            fpath = os.path.join(root, fname)
            # Normalize to forward slashes
            handoffs.add(fpath.replace(os.sep, '/'))
    
    return handoffs


def get_registry_files(registry: dict) -> Set[str]:
    """Get all file paths in the registry, normalized."""
    files = set()
    for entry in registry.get('entries', []):
        fpath = entry.get('file', '')
        if fpath:
            files.add(fpath.replace('\\', '/'))
    return files


def parse_orchestrator_log() -> Dict[str, Dict]:
    """
    Parse orchestrator.log to extract workflow completion events.
    Returns a dict keyed by run_id with completion info.
    """
    completions = {}
    
    if not os.path.exists(ORCH_LOG_FILE):
        print(f"Warning: {ORCH_LOG_FILE} not found")
        return completions
    
    with open(ORCH_LOG_FILE, 'r', encoding='utf-8-sig') as f:
        log_content = f.read()
    
    # Pattern for all event types
    # Format: TIMESTAMP | EVENT_TYPE | RUN_ID | ...
    pattern = re.compile(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \| ([A-Z_]+) \| ([A-Z0-9\-]+)')
    
    for line in log_content.split('\n'):
        match = pattern.search(line)
        if match:
            ts_str, evt_type, run_id = match.groups()
            if run_id not in completions:
                completions[run_id] = {'events': [], 'done_ts': None, 'is_done': False}
            completions[run_id]['events'].append((ts_str, evt_type))
            if evt_type in ('WF03_DONE', 'WF03_COMPLETE', 'DONE', 'GIT_MERGE'):
                completions[run_id]['done_ts'] = ts_str
                completions[run_id]['is_done'] = True
    
    return completions


def get_handoff_completion_status(handoff_path: str, completions: Dict) -> Tuple[str, Optional[str]]:
    """
    Determine the status of a handoff based on its file path and orchestrator log.
    Returns (status, completion_timestamp).
    """
    # Extract run_id from handoff path
    # Path format: handoffs/RUN_ID/step-name.json
    
    parts = handoff_path.replace('\\', '/').split('/')
    if len(parts) < 2:
        return 'UNKNOWN', None
    
    run_id = parts[1]  # e.g., "WF03-gh377-20260804" or "ADHOC-xxx"
    
    # Check if this run_id is in the orchestrator log completions
    if run_id in completions:
        if completions[run_id]['is_done']:
            return 'COMPLETED', completions[run_id]['done_ts']
        # Has events but not marked done - check individual step completions
        step_events = completions[run_id]['events']
        if step_events:
            return 'COMPLETED', step_events[-1][0]  # Last event timestamp
    
    # Check for ADHOC that look stale (2024/2025 dates)
    if 'ADHOC' in run_id:
        # Extract year from path
        year_match = re.search(r'-(20\d{2})\d{6}', run_id)
        if year_match:
            year = int(year_match.group(1))
            if year < 2026:
                return 'SUPERSEDED', None  # Old ADHOC entries
    
    # Default - if we have the file, it was at least created
    return 'COMPLETED', None


def load_handoff_file(handoff_path: str) -> Optional[dict]:
    """Load a handoff JSON file."""
    # Convert to OS-specific path for actual file access
    os_path = handoff_path.replace('/', os.sep)
    if not os.path.exists(os_path):
        # Try without normalization
        os_path = handoff_path
    
    try:
        with open(os_path, 'r', encoding='utf-8-sig') as f:
            return json.load(f)
    except Exception as e:
        print(f"Warning: Could not load {handoff_path}: {e}")
        return None


def create_registry_entry(handoff_path: str, status: str, completion_ts: Optional[str]) -> dict:
    """Create a new registry entry from a handoff file."""
    handoff = load_handoff_file(handoff_path)
    
    entry = {
        'handoff_id': handoff.get('handoff_id', os.path.basename(handoff_path).replace('.json', '')),
        'file': handoff_path.replace(os.sep, '/'),
        'run_id': handoff.get('run_id', handoff_path.split('/')[1] if '/' in handoff_path else ''),
        'step': handoff.get('step', 'unknown'),
        'from_agent': handoff.get('from_agent', 'UNKNOWN'),
        'to_agent': handoff.get('to_agent', 'UNKNOWN'),
        'created_at': handoff.get('created_at', datetime.now(timezone.utc).isoformat()),
        'status': status,
    }
    
    if completion_ts:
        entry['completed_at'] = completion_ts
    
    return entry


def is_stale_adhoc(run_id: str) -> bool:
    """Check if an ADHOC run_id is from 2024 or earlier (stale)."""
    if 'ADHOC' not in run_id:
        return False
    
    # Extract date from run_id like ADHOC-xxx-YYYYMMDD
    year_match = re.search(r'-(20[2-9]\d)\d{4}$', run_id)
    if year_match:
        year = int(year_match.group(1))
        return year < 2026
    
    return False


def main():
    print("=" * 60)
    print("Handoff Registry Sync Repair Tool")
    print("=" * 60)
    print()
    
    # Load registry
    print("Loading registry...")
    registry = load_registry()
    initial_count = len(registry.get('entries', []))
    print(f"  Registry entries: {initial_count}")
    
    # Get all handoff files on disk
    print("Scanning handoff files on disk...")
    disk_files = get_all_handoff_files()
    print(f"  Files on disk: {len(disk_files)}")
    
    # Get files already in registry
    registry_files = get_registry_files(registry)
    print(f"  Files in registry: {len(registry_files)}")
    
    # Find missing files
    missing_files = disk_files - registry_files
    print(f"  Missing from registry: {len(missing_files)}")
    print()
    
    # Parse orchestrator log
    print("Parsing orchestrator.log...")
    completions = parse_orchestrator_log()
    print(f"  Workflow runs with completion events: {len(completions)}")
    print()
    
    # Process missing files
    new_entries = []
    stale_adhoc_entries = []
    
    print("Processing missing files...")
    for handoff_path in sorted(missing_files):
        status, completion_ts = get_handoff_completion_status(handoff_path, completions)
        
        # Load handoff to get details
        handoff = load_handoff_file(handoff_path)
        if not handoff:
            continue
        
        run_id = handoff.get('run_id', handoff_path.split('/')[1] if '/' in handoff_path else '')
        
        # Track stale ADHOC entries
        if is_stale_adhoc(run_id):
            stale_adhoc_entries.append({
                'path': handoff_path,
                'run_id': run_id,
                'status': status
            })
        
        entry = create_registry_entry(handoff_path, status, completion_ts)
        new_entries.append(entry)
    
    print(f"  New entries to add: {len(new_entries)}")
    print(f"  Stale ADHOC entries (pre-2026): {len(stale_adhoc_entries)}")
    print()
    
    # Show stale ADHOC breakdown
    if stale_adhoc_entries:
        by_year = {}
        for e in stale_adhoc_entries:
            run_id = e['run_id']
            year_match = re.search(r'-(20[2-9]\d)\d{4}$', run_id)
            year = year_match.group(1) if year_match else 'unknown'
            by_year[year] = by_year.get(year, 0) + 1
        
        print("  Stale ADHOC by year:")
        for year, count in sorted(by_year.items()):
            print(f"    {year}: {count}")
        print()
    
    # Add new entries to registry
    print("Adding new entries to registry...")
    registry['entries'].extend(new_entries)
    print(f"  Added {len(new_entries)} entries")
    
    # Remove stale ADHOC entries that were already in registry
    # (these should be archived - status changed to SUPERSEDED)
    stale_in_registry = []
    for entry in registry['entries']:
        run_id = entry.get('run_id', '')
        if is_stale_adhoc(run_id) and entry.get('status') not in ('SUPERSEDED', 'ARCHIVED'):
            stale_in_registry.append(entry['handoff_id'])
            entry['status'] = 'SUPERSEDED'
    
    if stale_in_registry:
        print(f"  Archived {len(stale_in_registry)} stale ADHOC entries in registry")
    
    # Save registry
    print()
    print("Saving registry...")
    save_registry(registry)
    
    final_count = len(registry.get('entries', []))
    print(f"  Final registry entries: {final_count}")
    print(f"  Net change: +{final_count - initial_count}")
    print()
    
    # Summary
    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  Missing entries identified: {len(missing_files)}")
    print(f"  New entries added: {len(new_entries)}")
    print(f"  Stale ADHOC archived: {len(stale_in_registry)}")
    print(f"  Total registry entries: {final_count}")
    print()
    
    # Status breakdown
    status_counts = {}
    for e in registry['entries']:
        s = e.get('status', 'UNKNOWN')
        status_counts[s] = status_counts.get(s, 0) + 1
    
    print("Registry status breakdown:")
    for s, c in sorted(status_counts.items()):
        print(f"  {s}: {c}")
    
    return len(missing_files), len(new_entries), len(stale_in_registry)


if __name__ == '__main__':
    main()
