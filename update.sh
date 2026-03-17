#!/usr/bin/env bash
# update.sh — Query SLURM and push job data to GitHub Pages
# Usage: ./update.sh [--metric <wandb_metric_key>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DATA_FILE="data.json"
WANDB_METRIC_OVERRIDE=""

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --metric)
            WANDB_METRIC_OVERRIDE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Activate venv if present (for wandb)
if [ -f "$SCRIPT_DIR/.venv/bin/activate" ]; then
    source "$SCRIPT_DIR/.venv/bin/activate"
fi

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

# --- Query GPU utilization via SSH for running jobs ---
GPU_SMI_OUTPUT=""
while IFS='|' read -r job_id name state partition node gres elapsed tlimit submit; do
    state_upper=$(echo "$state" | tr '[:lower:]' '[:upper:]')
    [[ "$state_upper" != "RUNNING" ]] && continue
    [[ -z "$node" ]] && continue
    echo "$gres" | grep -qi "gpu" || continue
    # SSH to node, query nvidia-smi
    gpu_data=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$node" \
        'nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits' 2>/dev/null || true)
    if [ -n "$gpu_data" ]; then
        # Format: job_id|node|line1;line2;... (each line: util,mem_util,mem_used,mem_total)
        gpu_lines=$(echo "$gpu_data" | tr '\n' ';' | sed 's/;$//')
        GPU_SMI_OUTPUT="${GPU_SMI_OUTPUT}${job_id}|${node}|${gpu_lines}"$'\n'
    fi
done <<< "$squeue_jobs"

# --- Collect log tails for all jobs ---
LOG_TAILS=""
all_job_ids=""
# Extract job IDs from squeue
while IFS='|' read -r job_id rest; do
    [ -z "$job_id" ] && continue
    all_job_ids="${all_job_ids} ${job_id}"
done <<< "$squeue_jobs"
# Extract job IDs from sacct
while IFS='|' read -r job_id rest; do
    [ -z "$job_id" ] && continue
    all_job_ids="${all_job_ids} ${job_id}"
done <<< "$sacct_jobs"

for jid in $all_job_ids; do
    stdout_path=$(scontrol show job "$jid" 2>/dev/null | grep -oP 'StdOut=\K\S+' || true)
    if [ -n "$stdout_path" ] && [ -f "$stdout_path" ]; then
        log_b64=$(tail -c 51200 "$stdout_path" 2>/dev/null | tail -100 | base64 -w0 2>/dev/null || true)
        if [ -n "$log_b64" ]; then
            LOG_TAILS="${LOG_TAILS}${jid}|${log_b64}"$'\n'
        fi
    fi
done

# --- Build JSON with Python ---
export SQUEUE_OUTPUT="$squeue_jobs"
export SACCT_OUTPUT="$sacct_jobs"
export UPDATED_AT="$UPDATED_AT"
export GPU_SMI_OUTPUT="$GPU_SMI_OUTPUT"
export LOG_TAILS="$LOG_TAILS"
export WANDB_METRIC_OVERRIDE="$WANDB_METRIC_OVERRIDE"
export WANDB_CONFIG_FILE="$SCRIPT_DIR/wandb_config.json"

python3 << 'PYEOF'
import json, os, base64
from datetime import datetime, timedelta

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

# --- Parse GPU utilization data ---
gpu_current = {}  # {job_id: [{util, mem_util, mem_used, mem_total}, ...]}
gpu_smi_raw = os.environ.get("GPU_SMI_OUTPUT", "").strip()
for line in gpu_smi_raw.splitlines():
    parts = line.split("|", 2)
    if len(parts) < 3:
        continue
    job_id, node, gpu_lines = parts[0].strip(), parts[1].strip(), parts[2].strip()
    gpus_list = []
    for gl in gpu_lines.split(";"):
        vals = [v.strip() for v in gl.split(",")]
        if len(vals) >= 4:
            gpus_list.append({
                "util": float(vals[0]),
                "mem_util": float(vals[1]),
                "mem_used": float(vals[2]),
                "mem_total": float(vals[3]),
            })
    if gpus_list:
        gpu_current[job_id] = gpus_list

# --- Update GPU history (rolling 12 samples = 1 hour at 5-min intervals) ---
HISTORY_FILE = "gpu_history.json"
MAX_SAMPLES = 12

try:
    with open(HISTORY_FILE) as f:
        gpu_history = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    gpu_history = {}

now_str = os.environ.get("UPDATED_AT", datetime.utcnow().isoformat() + "Z")
active_ids = {j["job_id"] for j in jobs}

# Append new samples
for job_id, gpus_list in gpu_current.items():
    if job_id not in gpu_history:
        gpu_history[job_id] = []
    gpu_history[job_id].append({"timestamp": now_str, "gpus": gpus_list})
    # Trim to MAX_SAMPLES
    gpu_history[job_id] = gpu_history[job_id][-MAX_SAMPLES:]

# Prune jobs no longer in active list
gpu_history = {k: v for k, v in gpu_history.items() if k in active_ids}

with open(HISTORY_FILE, "w") as f:
    json.dump(gpu_history, f, indent=2)

# --- Compute average GPU utilization per job ---
gpu_avg = {}
for job_id, samples in gpu_history.items():
    all_utils = []
    for s in samples:
        for g in s["gpus"]:
            all_utils.append(g["util"])
    if all_utils:
        gpu_avg[job_id] = round(sum(all_utils) / len(all_utils), 1)

# --- Parse log tails ---
log_tails = {}
log_raw = os.environ.get("LOG_TAILS", "").strip()
for line in log_raw.splitlines():
    parts = line.split("|", 1)
    if len(parts) < 2:
        continue
    job_id, b64 = parts[0].strip(), parts[1].strip()
    try:
        log_tails[job_id] = base64.b64decode(b64).decode("utf-8", errors="replace")
    except Exception:
        pass

# --- W&B metrics ---
wandb_data = {}  # {job_id: {run_id, url, metric_name, metric_latest, metric_history, step}}
try:
    import wandb

    config_path = os.environ.get("WANDB_CONFIG_FILE", "")
    wandb_cfg = {}
    if config_path and os.path.exists(config_path):
        with open(config_path) as f:
            wandb_cfg = json.load(f)

    entity = wandb_cfg.get("entity", "")
    project = wandb_cfg.get("project", "")
    metric_key = os.environ.get("WANDB_METRIC_OVERRIDE", "") or wandb_cfg.get("metric", "loss_metric/global_avg_loss")

    if entity and project:
        api = wandb.Api()
        # Fetch recent runs (last 24h, running or finished)
        runs = api.runs(
            f"{entity}/{project}",
            filters={"created_at": {"$gte": (datetime.utcnow() - timedelta(days=1)).isoformat()}},
            per_page=50,
        )

        # Build lookup: slurm_job_id -> run (from config), and name -> run (fallback)
        runs_by_slurm_id = {}
        runs_by_name = {}
        for run in runs:
            slurm_id = run.config.get("slurm_job_id", "")
            if slurm_id:
                runs_by_slurm_id[str(slurm_id)] = run
            runs_by_name[run.name] = run

        for j in jobs:
            jid = j["job_id"]
            jname = j["name"]
            # Match: config.slurm_job_id first, then run name contains job name
            run = runs_by_slurm_id.get(jid)
            if not run:
                run = runs_by_name.get(jname)
            if not run:
                # Fuzzy: check if any run name contains the job name or vice versa
                for rname, r in runs_by_name.items():
                    if jname in rname or rname in jname:
                        run = r
                        break
            if not run:
                continue

            try:
                # Fetch metric history (last 50 points)
                history = run.scan_history(keys=[metric_key, "_step"], page_size=50)
                points = []
                last_step = 0
                for row in history:
                    val = row.get(metric_key)
                    if val is not None:
                        points.append(round(float(val), 6))
                        last_step = row.get("_step", last_step)
                # Keep last 50 points for sparkline
                points = points[-50:]
                if points:
                    wandb_data[jid] = {
                        "run_id": run.id,
                        "url": run.url,
                        "metric_name": metric_key,
                        "metric_latest": points[-1],
                        "metric_history": points,
                        "step": last_step,
                    }
            except Exception:
                pass

        print(f"W&B: matched {len(wandb_data)} jobs to runs")
    else:
        print("W&B: skipped (no entity/project in wandb_config.json)")

except ImportError:
    print("W&B: skipped (wandb not installed)")
except Exception as e:
    print(f"W&B: error ({e})")

# --- Attach new fields to jobs ---
for j in jobs:
    jid = j["job_id"]
    j["gpu_avg_util"] = gpu_avg.get(jid)
    j["gpu_current"] = gpu_current.get(jid)
    j["log_tail"] = log_tails.get(jid)
    j["wandb"] = wandb_data.get(jid)

data = {
    "updated_at": now_str,
    "gpu_history": gpu_history,
    "jobs": jobs,
}

with open("data.json", "w") as f:
    json.dump(data, f, indent=2)
print(f"Wrote {len(jobs)} jobs to data.json")
PYEOF

# --- Git commit and push ---
GPU_HISTORY_FILE="gpu_history.json"
has_changes=false
for f in "$DATA_FILE" "$GPU_HISTORY_FILE"; do
    if [ -f "$f" ]; then
        git diff --quiet "$f" 2>/dev/null && git diff --cached --quiet "$f" 2>/dev/null || has_changes=true
    fi
done
if [ "$has_changes" = false ]; then
    echo "No changes, skipping push"
    exit 0
fi

git add "$DATA_FILE"
[ -f "$GPU_HISTORY_FILE" ] && git add "$GPU_HISTORY_FILE"
git commit -m "Update job data $(date -u +%Y-%m-%dT%H:%M:%SZ)" --allow-empty-message 2>/dev/null || true
git push origin main 2>/dev/null || git push origin master 2>/dev/null || {
    echo "ERROR: git push failed. Check your remote configuration."
    exit 1
}

echo "Pushed updated data.json"
