#!/usr/bin/env bash
# =============================================================================
# phase1_prep.sh : MRP preparation (ONLINE, no outage)
#
# USAGE:
#   ./phase1_prep.sh [--dry-run] [--from-step N]      (run as root, normally via patch_orchestrator.sh)
#
# Steps:
#   1 pre-flight (zips, homes, CRS, database)      5 RU level and inventory of both homes
#   2 disk space                                    6 conflict analysis (opatchauto -analyze, opatch prereq)
#   3 extract both MRPs                             7 pre-patch snapshots (lspatches, invalid objects)
#   4 OPatch check / update                         8 backup of both homes and the inventory
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/patch.conf"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib_mrp.sh"
parse_args "$@"
validate_conf
init_phase phase1_prep

plan prep_1 "check ${GI_MRP_ZIP}, ${DB_MRP_ZIP} in ${PATCH_LOC}; OPatch present in both homes
grid and oracle can read the scripts and staging directory
crsctl check crs (CRS online); srvctl config/status database; instance status OPEN"
plan prep_2 "free space: ${PATCH_LOC} >= ${MIN_FREE_GB_STAGING} GB, each home file system >= ${MIN_FREE_GB_HOMES} GB,
${BACKUP_DIR} >= 60% of the two home sizes (BACKUP_HOMES=${BACKUP_HOMES})"
plan prep_3 "unzip ${GI_MRP_ZIP} and ${DB_MRP_ZIP} into ${PATCH_LOC}; chown root:${INSTALL_GROUP}, chmod a+rX"
plan prep_4 "opatch version in both homes; minimum ${MIN_OPATCH_VERSION}; UPDATE_OPATCH=${UPDATE_OPATCH}
(update = move OPatch to OPatch.pre_*, unzip ${OPATCH_ZIP} as the home owner)"
plan prep_5 "opatch lspatches must match RU level '${BASE_RU_REGEX}' in both homes (ALLOW_RU_MISMATCH=${ALLOW_RU_MISMATCH})
opatch lsinventory -detail -oh for both homes"
plan prep_6 "${GRID_HOME}/OPatch/opatchauto apply ${GI_MRP_DIR} -analyze -oh ${GRID_HOME}   (as root)
DB home (${DB_PATCH_METHOD}): opatch prereq CheckConflictAgainstOHWithDetail -ph ./${DB_MRP_PATCH}   (as ${ORACLE_USER})"
plan prep_7 "save opatch lspatches of both homes and the invalid object count to ${LOG_DIR}"
plan prep_8 "tar.gz of ${GRID_HOME}, ${DB_HOME}, oraInventory, oratab, olr.loc into ${BACKUP_DIR}/${MRP_LABEL}"
should_run 1 && act "1. Pre-flight"                            prep_1
should_run 2 && act "2. Disk space"                            prep_2
should_run 3 && act "3. Extract MRP zips"                      prep_3
should_run 4 && act "4. OPatch version"                        prep_4
should_run 5 && act "5. RU level and inventory"                prep_5
should_run 6 && act "6. Conflict analysis"                     prep_6
should_run 7 && act "7. Pre-patch snapshots"                   prep_7
should_run 8 && act "8. Backups"                               prep_8

is_dry && exit 0
print_summary
mark_phase_complete 1
log "=== PHASE 1 COMPLETE. Next: phase 2 (OUTAGE) ==="
