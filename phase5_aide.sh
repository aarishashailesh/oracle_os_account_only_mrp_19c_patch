#!/usr/bin/env bash
# =============================================================================
# phase5_aide.sh : reset the AIDE baseline after patching (run last)
#
# USAGE:
#   ./phase5_aide.sh [--dry-run]
#
# aide --init when no master database exists, aide --update otherwise; the new database
# is then promoted to the master. aide --update exits non-zero when files differ, which is
# normal after patching, so the result is judged by the output file.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/patch.conf"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib_mrp.sh"
parse_args "$@"
validate_conf
init_phase phase5_aide
require_phase_complete 1 2 3 4

aide_reset() {
  command -v aide >/dev/null 2>&1 || { warn "aide is not installed, skipping (dnf install -y aide)"; return 0; }
  local new="/var/lib/aide/aide.db.new.gz" master="/var/lib/aide/aide.db.gz" mode="--init" elapsed=0 pid
  if [[ -s "${master}" ]]; then mode="--update"; rm -f "${new}"; fi
  log "  aide ${mode} (30 to 60 minutes expected)"
  aide "${mode}" &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    sleep 30; elapsed=$(( elapsed + 30 ))
    (( elapsed % 300 == 0 )) && log "  aide still running, ${elapsed}s"
    (( elapsed >= 7200 )) && { kill "${pid}" 2>/dev/null || true; die "aide timed out after 7200s"; }
  done
  wait "${pid}" 2>/dev/null || true
  [[ -s "${new}" ]] || die "${new} is missing or empty; see /var/log/aide/aide.log"
  cp -f "${new}" "${master}"; chmod 600 "${master}"
  log "  new baseline promoted: ${master} ($(stat -c%s "${master}") bytes)"
}

plan aide_reset "aide --init (no master) or aide --update, then promote /var/lib/aide/aide.db.new.gz to aide.db.gz"
act "AIDE baseline reset" aide_reset

is_dry && exit 0
mark_phase_complete 5
