#!/usr/bin/env bash
# =============================================================================
# phase2_apply.sh : apply the MRPs in place (OUTAGE)
#
# USAGE:
#   ./phase2_apply.sh [--dry-run] [--from-step N]     (run as root, normally via patch_orchestrator.sh)
#
# Steps:
#   1 disable SYS.DB_DDL_ALERT_TRG            6 wait for CRS, start listener and database
#   2 stop listener and database              7 datapatch -verbose
#   3 DB home: apply MRP                      8 enable SYS.DB_DDL_ALERT_TRG
#   4 Grid home: opatchauto apply GI MRP
#   5 (opatchauto restarts the CRS stack)
# Re-runnable: a home that already contains the MRP patches is skipped.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/patch.conf"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib_mrp.sh"
parse_args "$@"
validate_conf
init_phase phase2_apply
require_phase_complete 1
is_dry || detect_db

s1() { db_open || { log "  database is not open: trigger left as is"; return 0; }; ddl_trigger DISABLE || die "Could not disable SYS.DB_DDL_ALERT_TRG. Nothing was stopped yet."; }
s2() {
  if db_home_patched && grid_home_patched; then log "  both homes already contain the MRP patches: nothing to stop (re-run after a failed datapatch?)"; return 0; fi
  stop_listeners; stop_database; log "  listener and database stopped"
}
s3() { apply_db_home; }
s4() { apply_grid_home; }
s5() { wait_crs; }
s6() {
  start_listeners
  start_database
  wait_until 900 10 "database ${DB_NAME} open" db_open || die "Database did not open. Check the alert log and srvctl status database -d ${DB_NAME}."
  open_pdbs
}
s7() { run_datapatch; }
s8() { ddl_trigger ENABLE || die "Could not enable SYS.DB_DDL_ALERT_TRG. Enable it by hand in the root and every PDB, then re-run: $0 --from-step 8"; }

plan s1 "alter trigger SYS.DB_DDL_ALERT_TRG disable (root and open PDBs; skipped when absent), DDL_TRIGGER_HANDLING=${DDL_TRIGGER_HANDLING}"
plan s2 "srvctl stop listener (as ${GRID_USER}); srvctl stop database -d ${DB_NAME} -o immediate"
plan s3 "$( [[ "${DB_PATCH_METHOD}" == "DB_MRP" ]] && echo "cd ${PATCH_LOC}; ${DB_HOME}/OPatch/opatch napply ./${DB_MRP_PATCH} -silent   (as ${ORACLE_USER})" || echo "${DB_HOME}/OPatch/opatchauto apply -binary ${GI_MRP_DIR} -oh ${DB_HOME} -target_type oracle_database   (as ${ORACLE_USER})" )
skipped when the DB home already shows the MRP patches"
plan s4 "${GRID_HOME}/OPatch/opatchauto apply ${GI_MRP_DIR} -oh ${GRID_HOME}   (as root; stops and restarts the CRS stack)
skipped when the Grid home already shows the MRP patches"
plan s5 "poll crsctl check crs up to ${CRS_WAIT_SECONDS}s"
plan s6 "srvctl start listener; srvctl start database -d ${DB_NAME}; wait for OPEN; alter pluggable database all open (CDB)"
plan s7 "dbms_qopatch.load_xml_inventory (best effort); cd ${DB_HOME}/OPatch; ./datapatch -verbose   (as ${ORACLE_USER})"
plan s8 "alter trigger SYS.DB_DDL_ALERT_TRG enable"
should_run 1 && act "1. Disable SYS.DB_DDL_ALERT_TRG"          s1
should_run 2 && act "2. Stop listener and database (OUTAGE)"   s2
should_run 3 && act "3. DB home: apply MRP"                    s3
should_run 4 && act "4. Grid home: opatchauto apply GI MRP"    s4
should_run 5 && act "5. Wait for CRS"                          s5
should_run 6 && act "6. Start listener and database"           s6
should_run 7 && act "7. datapatch -verbose"                    s7
should_run 8 && act "8. Enable SYS.DB_DDL_ALERT_TRG"           s8

is_dry && exit 0
mark_phase_complete 2
log "=== PHASE 2 COMPLETE. Next: phase 3 (verify) ==="
