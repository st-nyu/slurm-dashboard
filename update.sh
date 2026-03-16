#!/usr/bin/env bash
# update.sh — Query SLURM and push job data to GitHub Pages
# Usage: ./update.sh (or via cron)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DATA_FILE="data.json"

# Get current user
SLURM_USER="${USER}"

# Timestamp
UPDATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Query active jobs (squeue) ---
# Format: JobID|Name|State|Partition|NodeList|NumGPUs|Elapsed|TimeLimit|SubmitTime
SQUEUE_FORMAT="%i|%j|%T|%P|%N|%b|%M|%l|%V"

squeue_jobs=$(squeue -u "$SLURM_USER" --noheader -o "$SQUEUE_FORMAT" 2>/dev/null || true)

# --- Query recent completed/failed jobs (sacct, last 24h) ---
SINCE=$(date -u -d "24 hours ago" +"%Y-%m-%dT%H:%M" 2>/dev/null || date -u -v-24H +"%Y-%m-%dT%H:%M" 2>/dev/null || echo "")

sacct_jobs=""
if [ -n "$SINCE" ]; then
    sacct_jobs=$(sacct -u "$SLURM_USER" \
        --starttime "$SINCE" \
        --format="JobID,JobName%40,State,Partition,NodeList,ReqGRES,Elapsed,Timelimit,Submit" \
        --noheader --parsable2 \
        --allocations 2>/dev/null || true)
fi

# --- Build JSON with Python ---
export SQUEUE_OUTPUT="$squeue_jobs"
export SACCT_OUTPUT="$sacct_jobs"
export UPDATED_AT="$UPDATED_AT"

python3 << 'PYEOF'
import json, os
from datetime import datetime

jobs = []
seen_ids = set()

squeue_raw = os.environ.get("SQUEUE_OUTPUT", "").strip()
for line in squeue_raw.splitlines():
    parts = line.split("|")
    if len(parts) < 9:
        continue
    job_id = parts[0].strip()
    if job_id in seen_ids:
        continue
    seen_ids.add(job_id)
    gres = parts[5].strip()
    gpus = "-"
    if "gpu" in gres.lower():
        gpu_parts = gres.split(":")
        gpus = gpu_parts[-1] if gpu_parts[-1].isdigit() else gres
    jobs.append({
        "job_id": job_id,
        "name": parts[1].strip(),
        "state": parts[2].strip(),
        "partition": parts[3].strip(),
        "nodes": parts[4].strip() or "-",
        "gpus": gpus,
        "elapsed": parts[6].strip(),
        "time_limit": parts[7].strip(),
        "submit_time": parts[8].strip() if parts[8].strip() != "Unknown" else None,
    })

sacct_raw = os.environ.get("SACCT_OUTPUT", "").strip()
for line in sacct_raw.splitlines():
    parts = line.split("|")
    if len(parts) < 9:
        continue
    job_id = parts[0].strip()
    state = parts[2].strip()
    if job_id in seen_ids:
        continue
    if state in ("RUNNING", "PENDING"):
        continue
    seen_ids.add(job_id)
    gres = parts[5].strip()
    gpus = "-"
    if "gpu" in gres.lower():
        gpu_parts = gres.split(":")
        gpus = gpu_parts[-1] if gpu_parts[-1].isdigit() else gres
    jobs.append({
        "job_id": job_id,
        "name": parts[1].strip(),
        "state": state,
        "partition": parts[3].strip(),
        "nodes": parts[4].strip() or "-",
        "gpus": gpus,
        "elapsed": parts[6].strip(),
        "time_limit": parts[7].strip(),
        "submit_time": parts[8].strip() if parts[8].strip() != "Unknown" else None,
    })

data = {
    "updated_at": os.environ.get("UPDATED_AT", datetime.utcnow().isoformat() + "Z"),
    "jobs": jobs,
}

with open("data.json", "w") as f:
    json.dump(data, f, indent=2)
print(f"Wrote {len(jobs)} jobs to data.json")
PYEOF

# --- Git commit and push ---
if git diff --quiet "$DATA_FILE" 2>/dev/null && git diff --cached --quiet "$DATA_FILE" 2>/dev/null; then
    echo "No changes to data.json, skipping push"
    exit 0
fi

git add "$DATA_FILE"
git commit -m "Update job data $(date -u +%Y-%m-%dT%H:%M:%SZ)" --allow-empty-message 2>/dev/null || true
git push origin main 2>/dev/null || git push origin master 2>/dev/null || {
    echo "ERROR: git push failed. Check your remote configuration."
    exit 1
}

echo "Pushed updated data.json"
