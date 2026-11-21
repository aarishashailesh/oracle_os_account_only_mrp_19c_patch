#!/usr/bin/env bash
# =============================================================================
# phase3_verify.sh : post-patch validation (ONLINE)
#
# USAGE:
#   ./phase3_verify.sh [--dry-run] [--from-step N]
#
# Steps: 1 patches in both homes and inventory   3 datapatch registry, invalid objects
#        2 CRS and resources                     4 database options (chopt) and PDB status
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/patch.conf"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib_mrp.sh"
parse_args "$@"
validate_conf
init_phase phase3_verify
require_phase_complete 1 2
is_dry || detect_db

s4() {
  chopt_reconcile
  run_sql "${DB_SID}" "select con_id, name, open_mode from v\$pdbs order by con_id;" 2>/dev/null | while IFS= read -r l; do log "  ${l}"; done || true
  run_grid "${GRID_HOME}/bin/srvctl status database -d ${DB_NAME}; ${GRID_HOME}/bin/srvctl status listener" 2>&1 | while IFS= read -r l; do log "  ${l}"; done
}

plan verify_binaries "opatch lspatches on both homes; expected DB ids: ${DB_HOME_EXPECTED_IDS:-auto}; Grid ids: ${GRID_HOME_EXPECTED_IDS:-none}
Grid patch list must differ from the pre-patch snapshot; opatch lsinventory on both homes"
plan verify_crs "crsctl check crs, query crs releasepatch/softwarepatch, status resource -t"
plan verify_registry "latest dba_registry_sqlpatch / cdb_registry_sqlpatch row per patch must be SUCCESS; utlrp; invalid objects must not grow"
plan s4 "v\$option check for CHOPT_DISABLE='${CHOPT_DISABLE}' (CHOPT_REAPPLY=${CHOPT_REAPPLY}); PARTITIONING_REQUIRED=${PARTITIONING_REQUIRED}; PDB open modes; srvctl status"
should_run 1 && act "1. Patches in both homes"        verify_binaries
should_run 2 && act "2. CRS and resources"            verify_crs
should_run 3 && act "3. datapatch registry"           verify_registry
should_run 4 && act "4. Options and PDBs"             s4

is_dry && exit 0
print_summary || die "Verification failed. Phase 3 marker NOT written."
mark_phase_complete 3
log "=== PHASE 3 COMPLETE. Optional: phase 4 (security), phase 5 (AIDE) ==="
