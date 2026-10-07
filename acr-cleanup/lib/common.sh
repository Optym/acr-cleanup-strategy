#!/usr/bin/env bash
# Shared helpers for the acr-cleanup module. Source before any other lib.
#
# Every executable sets its own `set -euo pipefail`; this file only provides
# logging, tool checks and small utilities so it stays safe to source anywhere.

ACR_CLEANUP_LOG_SCOPE="${ACR_CLEANUP_LOG_SCOPE:-acr-cleanup}"

# `local -n` (config.sh) needs 4.3; empty-array expansion under set -u needs 4.4.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  printf 'ERROR: bash 4.4 or newer required, found %s\n' "${BASH_VERSION}" >&2
  exit 1
fi

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# All diagnostics go to stderr so stdout stays clean for JSON output.
log() { printf '[%s] [%s] %s\n' "$(_ts)" "$ACR_CLEANUP_LOG_SCOPE" "$*" >&2; }

warn() { printf '[%s] [%s] WARNING: %s\n' "$(_ts)" "$ACR_CLEANUP_LOG_SCOPE" "$*" >&2; }

fail() {
  printf '[%s] [%s] ERROR: %s\n' "$(_ts)" "$ACR_CLEANUP_LOG_SCOPE" "$*" >&2
  exit 1
}

require_tool() {
  local tool missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]} > 0)); then
    fail "required tool(s) not found on PATH: ${missing[*]}"
  fi
}

# sha256 of stdin. Linux agents have sha256sum, macOS has shasum.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Stage banners and timings. The orchestrator wraps every stage in
# stage_begin / stage_end so the log shows what is running, and each stage's
# wall clock and headline numbers land in <work-dir>/timings.json for the
# report (section 1) and for tuning parallelism later.
STAGE_CURRENT=""
STAGE_STARTED_AT=0
STAGE_TIMINGS_FILE=""

stage_begin() {
  local work_dir="$1" stage="$2"
  STAGE_CURRENT="$stage"
  STAGE_STARTED_AT="$(date -u +%s)"
  STAGE_TIMINGS_FILE="${work_dir}/timings.json"
  [[ -f "$STAGE_TIMINGS_FILE" ]] || printf '{"stages":[]}\n' > "$STAGE_TIMINGS_FILE"
  log "==================== stage ${stage}: start ===================="
}

# stage_end <status> [detail]  - status is ok, failed or skipped
stage_end() {
  local status="$1" detail="${2:-}"
  local seconds=$(( $(date -u +%s) - STAGE_STARTED_AT ))
  local tmp="${STAGE_TIMINGS_FILE}.tmp"
  jq -c --arg stage "$STAGE_CURRENT" --arg status "$status" --arg detail "$detail" \
     --argjson seconds "$seconds" --arg at "$(_ts)" \
     '.stages += [{ stage: $stage, status: $status, seconds: $seconds, detail: $detail, finished_at: $at }]' \
     "$STAGE_TIMINGS_FILE" > "$tmp" && mv "$tmp" "$STAGE_TIMINGS_FILE"
  log "==================== stage ${STAGE_CURRENT}: ${status} in ${seconds}s${detail:+ (${detail})} ===================="
  STAGE_CURRENT=""
}

# Ctrl+C would otherwise leave the forked workers running: in a non-interactive
# shell, background subshells ignore SIGINT, and so does every curl they exec.
# The parent died on Ctrl+C while dozens of inventory workers kept going. On
# INT or TERM the parent kills its whole descendant tree and exits 130. Each
# worker is signalled before its own children: a worker whose curl died first
# would otherwise run on to its next command in the gap before its own signal
# arrived. Only descendants are signalled, never the process group, which
# under a pipeline agent may be shared with the agent worker itself.
_kill_descendants() {
  local parent="$1" table="$2" pid ppid
  while read -r pid ppid; do
    [[ "$ppid" == "$parent" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
    _kill_descendants "$pid" "$table"
  done <<<"$table"
}

_on_interrupt() {
  trap - INT TERM
  _kill_descendants "$BASHPID" "$(ps -axo pid=,ppid=)"
  warn "interrupted; background workers stopped"
  exit 130
}

install_interrupt_handler() {
  trap _on_interrupt INT TERM
}

# Human-readable byte count for log lines.
human_bytes() {
  local bytes="${1:-0}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || { printf 'n/a'; return; }
  awk -v b="$bytes" 'BEGIN { split("B KiB MiB GiB TiB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.1f %s", b, u[i] }'
}

# Copies this run's result.json and lock-ledger.json into <previous-dir>, so the
# NEXT invocation against the same --work-dir (the common local pattern: rerun
# the same ./.acr-cleanup-work repeatedly) automatically has continuity for the
# "delta vs previous run" report section and for the lock reconciler's
# wait_days_before_unlocking clock. Without this, --previous-dir only ever gets
# populated by something external (the pipeline's DownloadPipelineArtifact
# step), and a local run never sees its own history.
#
# Safe to call unconditionally: mkdir -p covers a first run, and a missing
# source file (lock-ledger.json when the run never reached stage 4) is skipped.
carry_forward_to_previous() {
  local work_dir="$1" previous_dir="$2"
  mkdir -p "$previous_dir"
  local carried=()
  if [[ -f "${work_dir}/result.json" ]]; then
    cp "${work_dir}/result.json" "${previous_dir}/result.json"
    carried+=("result.json")
  fi
  if [[ -f "${work_dir}/lock-ledger.json" ]]; then
    cp "${work_dir}/lock-ledger.json" "${previous_dir}/lock-ledger.json"
    carried+=("lock-ledger.json")
  fi
  if ((${#carried[@]} > 0)); then
    log "carried forward to ${previous_dir}: ${carried[*]}"
  fi
}
