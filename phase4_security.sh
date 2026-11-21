#!/usr/bin/env bash
# =============================================================================
# phase4_security.sh : re-assert FIPS file and extproc hardening after the MRP
#
# USAGE:
#   ./phase4_security.sh [--dry-run]
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/patch.conf"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib_mrp.sh"
parse_args "$@"
validate_conf
init_phase phase4_security
require_phase_complete 1 2 3

plan harden_db_home "write ${DB_HOME}/ldap/admin/fips.ora (SSLFIPS_140=TRUE); rename ${DB_HOME}/bin/extproc to extproc.orig if present"
act "fips.ora and extproc in ${DB_HOME}" harden_db_home

is_dry && exit 0
print_summary || die "Security step failed."
mark_phase_complete 4
