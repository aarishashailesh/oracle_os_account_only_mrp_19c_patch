#!/usr/bin/env bash
# =============================================================================
# patch_orchestrator.sh : MRP 19.33.0.0.261117 master script (run as root)
#
# USAGE:
#   ./patch_orchestrator.sh --phase <1-5> [--dry-run] [--from-step N] [--detach]
#   ./patch_orchestrator.sh [--from-phase <n>] [--full] [--dry-run]
#   ./patch_orchestrator.sh --rollback --yes
#   ./patch_orchestrator.sh --reset-status
#
# Options:
#   --phase <n>       run only phase n
#   --from-phase <n>  run from phase n to the end of the default range (1 to 3)
#   --full            run phases 1 to 5 (adds security and AIDE)
#   --dry-run         print the resolved configuration and every command, execute nothing
#   --from-step <n>   with --phase: resume inside a phase at step n
#   --detach          start the run as a transient systemd service (survives logout and
#                     TMOUT / KillUserProcesses on hardened hosts); needs --phase
#   --rollback --yes  roll the MRPs back (outage)
#   --reset-status    clear the phase markers (after a snapshot restore)
#
# Phases:
#   1 phase1_prep.sh      prerequisites, extract, OPatch, conflicts, backups   (online)
#   2 phase2_apply.sh     apply MRPs in place + datapatch                      (OUTAGE)
#   3 phase3_verify.sh    validation                                           (online)
#   4 phase4_security.sh  fips.ora + extproc                                   (optional)
#   5 phase5_aide.sh      AIDE baseline reset, run last                        (optional)
# =============================================================================
set -euo pipefail
umask 0022
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")

START=1; END=3; ONE=""; DRY=false; FROM_STEP=""; DETACH=false; ROLLBACK=false; YES=false; RESET=false
while (( $# )); do
  case "$1" in
    --phase)       ONE="$2"; START="$2"; END="$2"; shift 2 ;;
    --from-phase)  START="$2"; shift 2 ;;
    --full)        END=5; shift ;;
    --dry-run)     DRY=true; shift ;;
    --from-step)   FROM_STEP="$2"; shift 2 ;;
    --detach)      DETACH=true; shift ;;
    --rollback)    ROLLBACK=true; shift ;;
    --yes)         YES=true; shift ;;
    --reset-status) RESET=true; shift ;;
    -h|--help)     sed -n '/^# USAGE/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^===='; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -f "${SCRIPT_DIR}/patch.conf" ]] || { echo "ERROR: ${SCRIPT_DIR}/patch.conf not found"; exit 1; }
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/patch.conf"
export DRY_RUN="${DRY}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib_mrp.sh"

if [[ "${DETACH}" == "true" && "${DRY}" != "true" ]]; then
  [[ -n "${ONE}" || "${ROLLBACK}" == "true" ]] || die "--detach needs --phase <n> (or --rollback), one unit per phase."
  command -v systemd-run >/dev/null || die "systemd-run not found"
  unit="mrp-p${ONE:-rollback}"
  systemctl stop "${unit}" 2>/dev/null || true
  systemctl reset-failed "${unit}" 2>/dev/null || true
  args=(); for a in "${ORIG_ARGS[@]}"; do [[ "$a" == "--detach" ]] || args+=("$a"); done
  systemd-run --unit="${unit}" --remain-after-exit "${SCRIPT_DIR}/patch_orchestrator.sh" "${args[@]}"
  echo "Started ${unit}. Watch with:"
  echo "  tail -n 50 ${LOG_DIR}/master_patch.log"
  echo "  systemctl show ${unit} -p ActiveState -p Result -p ExecMainStatus   # success: Result=success ExecMainStatus=0"
  echo "When finished and reviewed, remove the unit (audited hosts must not keep it):  systemctl stop ${unit}"
  exit 0
fi

if [[ "${DRY}" != "true" ]]; then
  require_root
  mkdir -p "${LOG_DIR}"
  exec > >(tee -a "${LOG_DIR}/master_patch.log") 2>&1
fi

validate_conf

if [[ "${RESET}" == "true" ]]; then
  [[ "${DRY}" == "true" ]] || rm -f "${STATUS_DIR}"/phase*.done
  log "Phase markers cleared."
  exit 0
fi

ARGS=()
[[ "${DRY}" == "true" ]] && ARGS+=(--dry-run)
[[ -n "${FROM_STEP}" ]] && ARGS+=(--from-step "${FROM_STEP}")

if [[ "${ROLLBACK}" == "true" ]]; then
  [[ "${YES}" == "true" ]] && ARGS+=(--yes)
  exec bash "${SCRIPT_DIR}/rollback_mrp.sh" "${ARGS[@]}"
fi

declare -A SCRIPT=( [1]=phase1_prep.sh [2]=phase2_apply.sh [3]=phase3_verify.sh [4]=phase4_security.sh [5]=phase5_aide.sh )
declare -A DESC=( [1]="Preparation (online)" [2]="Apply MRPs in place (OUTAGE)" [3]="Verification (online)" [4]="Security re-assertion" [5]="AIDE baseline reset" )

log "MRP ${MRP_LABEL}: phases ${START} to ${END}, dry run: ${DRY}"
for n in $(seq "${START}" "${END}"); do
  log "-------- PHASE ${n}: ${DESC[$n]} --------"
  t0=$SECONDS
  bash "${SCRIPT_DIR}/${SCRIPT[$n]}" "${ARGS[@]}" || die "Phase ${n} FAILED after $(( SECONDS - t0 ))s. Fix the cause and re-run: $0 --phase ${n}  (or add --from-step N)"
  log "PHASE ${n} finished in $(( SECONDS - t0 ))s"
done
log "Done."
