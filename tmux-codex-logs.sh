#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_logs_root="${repo_root}/elixir/log/codex_sessions"
session_name="symphony-codex-logs"
logs_root="${default_logs_root}"
refresh_seconds=2
watch_internal=0
watcher_window="_watcher"
status_window="status"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--session NAME] [--logs-root PATH] [--refresh SECONDS]

Create or attach to a tmux session that tails each Symphony Codex agent-output log in its own tmux window.

Options:
  --session NAME       tmux session name (default: ${session_name})
  --logs-root PATH     root containing <issue>/current.log files (default: ${default_logs_root})
  --refresh SECONDS    scan interval for new logs (default: ${refresh_seconds})
  --help               show this help
EOF
}

while (($# > 0)); do
  case "$1" in
    --session)
      session_name="${2:?missing value for --session}"
      shift 2
      ;;
    --logs-root)
      logs_root="${2:?missing value for --logs-root}"
      shift 2
      ;;
    --refresh)
      refresh_seconds="${2:?missing value for --refresh}"
      shift 2
      ;;
    --watch-internal)
      watch_internal=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required" >&2
  exit 1
fi

if ! [[ "${refresh_seconds}" =~ ^[0-9]+$ ]] || [ "${refresh_seconds}" -le 0 ]; then
  echo "--refresh must be a positive integer" >&2
  exit 1
fi

mkdir -p "${logs_root}"

resolve_logs_root() {
  local requested_root="$1"
  local candidate

  for candidate in \
    "${requested_root}" \
    "${requested_root}/codex_sessions" \
    "${requested_root}/log/codex_sessions"
  do
    if [ -d "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  if [[ "${requested_root}" == */codex_sessions ]]; then
    printf '%s\n' "${requested_root}"
  else
    printf '%s\n' "${requested_root}/log/codex_sessions"
  fi
}

logs_root="$(resolve_logs_root "${logs_root}")"
mkdir -p "${logs_root}"

sanitize_window_name() {
  local issue="$1"
  local sanitized

  sanitized="$(printf '%s' "${issue}" | tr -c '[:alnum:]._-' '_')"
  sanitized="${sanitized#_}"
  sanitized="${sanitized%_}"

  if [ -z "${sanitized}" ]; then
    sanitized="unknown"
  fi

  printf 'log:%s' "${sanitized:0:48}"
}

window_exists() {
  local session="$1"
  local window_name="$2"

  tmux list-windows -t "${session}" -F '#W' 2>/dev/null | grep -Fx -- "${window_name}" >/dev/null 2>&1
}

first_log_window() {
  local session="$1"

  tmux list-windows -t "${session}" -F '#W' 2>/dev/null \
    | grep '^log:' \
    | sort \
    | head -n 1
}

ensure_status_window() {
  local session="$1"
  local command

  if window_exists "${session}" "${status_window}"; then
    return 0
  fi

  command="$(printf '%q' "clear; printf 'Watching %s for Symphony agent logs\n\n' '${logs_root}'; printf 'No active current.log files yet.\n'; printf 'This window will disappear once logs are detected.\n'; exec sleep infinity")"
  tmux new-window -d -t "${session}:" -n "${status_window}" "bash -lc ${command}"
}

reset_visible_windows() {
  local session="$1"
  local window_name

  while IFS= read -r window_name; do
    if [ "${window_name}" = "${watcher_window}" ]; then
      continue
    fi

    if [[ "${window_name}" == log:* ]] || [ "${window_name}" = "${status_window}" ]; then
      tmux kill-window -t "${session}:${window_name}"
    fi
  done < <(tmux list-windows -t "${session}" -F '#W' 2>/dev/null || true)
}

spawn_log_window() {
  local session="$1"
  local log_path="$2"
  local issue window_name command

  issue="$(basename "$(dirname "${log_path}")")"
  window_name="$(sanitize_window_name "${issue}")"

  if window_exists "${session}" "${window_name}"; then
    return 0
  fi

  command="$(printf '%q' "clear; printf 'Tailing Symphony agent output for %s\n%s\n\n' '${issue}' '${log_path}'; exec tail -n +1 -F '${log_path}'")"

  tmux new-window -d -t "${session}:" -n "${window_name}" "bash -lc ${command}"
}

prune_stale_log_windows() {
  local session="$1"
  shift
  local active_windows=("$@")
  local window_name

  while IFS= read -r window_name; do
    if [[ "${window_name}" != log:* ]]; then
      continue
    fi

    if [[ " ${active_windows[*]} " == *" ${window_name} "* ]]; then
      continue
    fi

    tmux kill-window -t "${session}:${window_name}"
  done < <(tmux list-windows -t "${session}" -F '#W' 2>/dev/null || true)
}

sync_log_windows() {
  local session="$1"
  local found=0
  local target_window
  local active_windows=()
  local issue window_name

  while IFS= read -r log_path; do
    found=1
    issue="$(basename "$(dirname "${log_path}")")"
    window_name="$(sanitize_window_name "${issue}")"
    active_windows+=("${window_name}")
    spawn_log_window "${session}" "${log_path}"
  done < <(find "${logs_root}" -mindepth 2 -maxdepth 2 -type f \( -name current.log -o -name current.ndjson \) | sort)

  prune_stale_log_windows "${session}" "${active_windows[@]}"

  if [ "${found}" -eq 0 ]; then
    ensure_status_window "${session}"
  else
    if window_exists "${session}" "${status_window}"; then
      tmux kill-window -t "${session}:${status_window}"
    fi

    target_window="$(first_log_window "${session}")"

    if [ -n "${target_window}" ]; then
      tmux select-window -t "${session}:${target_window}"
    fi
  fi
}

run_internal_watcher() {
  while tmux has-session -t "${session_name}" 2>/dev/null; do
    sync_log_windows "${session_name}"
    sleep "${refresh_seconds}"
  done
}

if [ "${watch_internal}" -eq 1 ]; then
  run_internal_watcher
  exit 0
fi

if ! tmux has-session -t "${session_name}" 2>/dev/null; then
  tmux new-session -d -s "${session_name}" -n "${watcher_window}" \
    "bash -lc $(printf '%q' "exec \"$0\" --watch-internal --session \"$session_name\" --logs-root \"$logs_root\" --refresh \"$refresh_seconds\"")"
fi

reset_visible_windows "${session_name}"
sync_log_windows "${session_name}"

if ! tmux list-windows -t "${session_name}" -F '#W' | grep -q '^log:'; then
  ensure_status_window "${session_name}"
  tmux select-window -t "${session_name}:${status_window}"
fi

if [ -n "${TMUX:-}" ]; then
  exec tmux switch-client -t "${session_name}"
else
  exec tmux attach-session -t "${session_name}"
fi
