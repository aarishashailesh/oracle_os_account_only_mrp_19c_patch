#!/usr/bin/env bash
# =============================================================================
# rollback_mrp.sh : roll the MRPs back (OUTAGE). Never part of a normal run.
#
# USAGE:
#   ./rollback_mrp.sh --yes [--dry-run]
#
# Follows section 4 "Deinstallation" of both readmes: stop listener and database, DB home
# opatch nrollback (or opatchauto rollback -binary), Grid home opatchauto rollback, start,
# datapatch -verbose. Afterwards the phase 1 to 3 markers are cleared.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/patch.conf"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib_mrp.sh"
parse_args "$@"
validate_conf
init_phase rollback_mrp
if ! is_dry && [[ "${ASSUME_YES}" != "true" ]]; then die "Rollback is an outage. Re-run with --yes to confirm."; fi
is_dry || detect_db

rb_start() {
  start_listeners; start_database
  wait_until 900 10 "database open" db_open || die "Database did not open after rollback"
}

rb_stop() { stop_listeners; stop_database; }
plan rb_stop "srvctl stop listener; srvctl stop database -d ${DB_NAME}"
plan rollback_db_home "DB home: opatch nrollback -id <installed MRP sub-patch ids> -silent (or opatchauto rollback -binary for GI_MRP)"
plan rollback_grid_home "${GRID_HOME}/OPatch/opatchauto rollback ${GI_MRP_DIR} -oh ${GRID_HOME}"
plan rb_start "srvctl start listener; srvctl start database -d ${DB_NAME}"
plan run_datapatch "datapatch -verbose from ${DB_HOME}/OPatch"
act "Stop listener and database"        rb_stop
act "DB home rollback"                  rollback_db_home
act "Grid home rollback"                rollback_grid_home
act "Wait for CRS"                      wait_crs
act "Start listener and database"       rb_start
act "datapatch -verbose"                run_datapatch

is_dry && exit 0
rm -f "${STATUS_DIR}"/phase[1-5].done
log "=== ROLLBACK COMPLETE. Phase markers cleared. Check: opatch lspatches in both homes ==="
