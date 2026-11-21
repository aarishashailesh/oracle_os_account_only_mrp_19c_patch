#!/usr/bin/env bash
# =============================================================================
# lib_mrp.sh : shared functions for the 19.33 MRP (Monthly Recommended Patch)
# automation. Sourced by every script after patch.conf.
#
# MRP patches are applied IN PLACE on top of the existing 19.33 homes:
#   Grid home : GI MRP 40196150 with opatchauto (root)
#   DB home   : DB MRP 40196156 with opatch napply (DB_PATCH_METHOD=DB_MRP)
#               or GI MRP 40196150 with opatchauto -binary (DB_PATCH_METHOD=GI_MRP)
#   then datapatch -verbose on every database running from the DB home.
# =============================================================================

: "${LOG_DIR:?patch.conf must be sourced before lib_mrp.sh}"

DRY_RUN="${DRY_RUN:-false}"
START_STEP="${START_STEP:-1}"
ASSUME_YES="${ASSUME_YES:-false}"
DETACH="${DETACH:-false}"
FAILED=0
NL=$'\n'

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(ts)] $*"; }
warn() { echo "[$(ts)] WARNING: $*"; }
die()  { echo "[$(ts)] FATAL: $*"; exit 1; }
pass() { echo "[$(ts)]   OK   $*"; }
fail() { echo "[$(ts)]   FAIL $*"; FAILED=$(( FAILED + 1 )); }
step() { echo; echo "[$(ts)] -- $* --"; }
is_dry() { [[ "${DRY_RUN}" == "true" ]]; }

# plan <function> "<text>" : what a step does, printed instead of running it in --dry-run
declare -A PLAN=()
plan() { PLAN["$1"]="$2"; }

# act "<description>" <command or function> [args...]
# Logs the step; in --dry-run it prints the plan text (values already resolved) and runs nothing.
act() {
  local desc="$1"; shift
  step "${desc}"
  if is_dry; then
    local t="${PLAN[$1]:-$*}"
    while IFS= read -r l; do log "  [DRY-RUN] ${l}"; done <<< "${t}"
    return 0
  fi
  "$@"
}

should_run() { (( $1 >= START_STEP )); }

show_help() { sed -n '/^# USAGE/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^===='; }

parse_args() {
  while (( $# )); do
    case "$1" in
      --dry-run)   DRY_RUN=true; shift ;;
      --from-step) START_STEP="${2:?--from-step needs a number}"; shift 2 ;;
      --yes)       ASSUME_YES=true; shift ;;
      --detach)    DETACH=true; shift ;;
      -h|--help)   show_help; exit 0 ;;
      *)           die "Unknown argument: $1" ;;
    esac
  done
  export DRY_RUN START_STEP ASSUME_YES
}

# detach_self "$@" : with --detach, re-run this script as a transient systemd service and exit.
# Survives logout, TMOUT and KillUserProcesses on hardened hosts. Not for steps that prompt.
detach_self() {
  [[ "${DETACH}" == "true" ]] || return 0
  is_dry && { log "[DRY-RUN] would start $(basename "$0") under systemd-run"; return 0; }
  command -v systemd-run >/dev/null || die "systemd-run not found"
  local unit args=() a
  unit="mrp-$(basename "$0" .sh)"
  for a in "$@"; do [[ "$a" == "--detach" ]] || args+=("$a"); done
  systemctl stop "${unit}" 2>/dev/null || true
  systemctl reset-failed "${unit}" 2>/dev/null || true
  systemd-run --unit="${unit}" --remain-after-exit "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" "${args[@]}"
  echo "Started ${unit}. Watch: tail -f ${LOG_DIR}/$(basename "$0" .sh | sed 's/^[0-9]*_//').log ; systemctl show ${unit} -p ActiveState -p Result -p ExecMainStatus"
  echo "Remove the unit when done (audited hosts must not keep it): systemctl stop ${unit}"
  exit 0
}

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root."; }

# -----------------------------------------------------------------------------
# Phase setup, status markers
# -----------------------------------------------------------------------------
init_phase() {   # init_phase <log_name>
  PHASE_NAME="$1"
  umask 0022
  if is_dry; then
    log "=== ${PHASE_NAME} (DRY-RUN: nothing is executed, nothing is written) ==="
    dry_run_header
    return 0
  fi
  require_root
  mkdir -p "${LOG_DIR}" "${TMP_DIR}" "${STATUS_DIR}"
  chgrp "${INSTALL_GROUP}" "${LOG_DIR}" "${STATUS_DIR}" 2>/dev/null || true
  chmod 775 "${LOG_DIR}" "${STATUS_DIR}"
  chmod 1777 "${TMP_DIR}"
  PHASE_LOG="${LOG_DIR}/${PHASE_NAME}.log"
  touch "${PHASE_LOG}"
  chgrp "${INSTALL_GROUP}" "${PHASE_LOG}" 2>/dev/null || true
  chmod 664 "${PHASE_LOG}"
  exec > >(tee -a "${PHASE_LOG}") 2>&1
  log "=== ${PHASE_NAME} on $(hostname -s) ==="
}

dry_run_header() {
  local k
  echo "  Resolved configuration:"
  for k in MRP_LABEL GI_MRP_PATCH DB_MRP_PATCH DB_PATCH_METHOD GRID_HOME DB_HOME GRID_USER ORACLE_USER \
           DB_NAME PATCH_LOC LOG_DIR BACKUP_DIR UPDATE_OPATCH BASE_RU_REGEX; do
    printf '    %-22s = %s\n' "${k}" "${!k:-}"
  done
  echo
}

mark_phase_complete() {   # mark_phase_complete <n>
  is_dry && return 0
  echo "COMPLETED $(ts) by $(whoami) on $(hostname -s)" > "${STATUS_DIR}/phase$1.done"
  chmod 664 "${STATUS_DIR}/phase$1.done" 2>/dev/null || true
  log "Phase $1 success marker written."
}

require_phase_complete() {   # require_phase_complete <n> [n...]
  is_dry && return 0
  local n missing=0
  for n in "$@"; do
    if [[ ! -f "${STATUS_DIR}/phase${n}.done" ]]; then
      log "ERROR: phase ${n} has not completed (missing ${STATUS_DIR}/phase${n}.done)."
      missing=1
    fi
  done
  (( missing == 0 )) || die "Run the earlier phases first, or use --reset-status after a snapshot restore."
}

# -----------------------------------------------------------------------------
# Configuration validation (runs in orchestrator and in every phase script)
# -----------------------------------------------------------------------------
validate_conf() {
  local v bad=0
  for v in MRP_LABEL BASE_RU_REGEX GI_MRP_PATCH GI_MRP_ZIP DB_MRP_PATCH DB_MRP_ZIP \
           GRID_HOME DB_HOME GRID_USER ORACLE_USER INSTALL_GROUP PATCH_LOC LOG_DIR \
           BACKUP_DIR DB_PATCH_METHOD MIN_OPATCH_VERSION; do
    if [[ -z "${!v:-}" ]]; then log "ERROR: ${v} is empty in patch.conf"; bad=1; fi
  done
  for v in GRID_HOME DB_HOME PATCH_LOC; do
    if [[ "${!v:-}" == */ ]]; then log "ERROR: ${v} must not end with a slash: ${!v}"; bad=1; fi
  done
  [[ "${DB_PATCH_METHOD:-}" == "DB_MRP" || "${DB_PATCH_METHOD:-}" == "GI_MRP" ]] \
    || { log "ERROR: DB_PATCH_METHOD must be DB_MRP or GI_MRP (is '${DB_PATCH_METHOD:-}')"; bad=1; }
  [[ "${GRID_HOME:-}" != "${DB_HOME:-}" ]] || { log "ERROR: GRID_HOME and DB_HOME are the same path"; bad=1; }
  case "${UPDATE_OPATCH:-auto}" in auto|yes|no) ;; *) log "ERROR: UPDATE_OPATCH must be auto, yes or no"; bad=1 ;; esac
  if is_dry; then
    id "${ORACLE_USER}" >/dev/null 2>&1 || warn "OS user ${ORACLE_USER} not found on this host (dry-run)"
    id "${GRID_USER}"   >/dev/null 2>&1 || warn "OS user ${GRID_USER} not found on this host (dry-run)"
  else
    id "${ORACLE_USER}" >/dev/null 2>&1 || { log "ERROR: OS user ${ORACLE_USER} does not exist"; bad=1; }
    id "${GRID_USER}"   >/dev/null 2>&1 || { log "ERROR: OS user ${GRID_USER} does not exist"; bad=1; }
    case "${SCRIPTS_DIR}" in /root|/root/*) log "ERROR: scripts must not live under /root (grid/oracle cannot read them)"; bad=1 ;; esac
  fi
  (( bad == 0 )) || die "patch.conf validation failed."
  log "patch.conf validated (${MRP_LABEL}, DB method ${DB_PATCH_METHOD})."
}

# -----------------------------------------------------------------------------
# Running commands as the Grid / Oracle OS users
# A temp script is used so multi-line commands survive su - -c quoting.
# -----------------------------------------------------------------------------
ora_env() {   # ora_env <home> [sid]
  local home="$1" sid="${2:-}"
  printf 'unset ORACLE_BASE ORACLE_SID\n'   # a .bashrc may carry the other home's values (single-owner hosts)
  printf 'export ORACLE_HOME=%s\n' "${home}"
  [[ -n "${sid}" ]] && printf 'export ORACLE_SID=%s\n' "${sid}"
  printf '%s\n' 'export PATH=${ORACLE_HOME}/bin:${ORACLE_HOME}/OPatch:${PATH}'
}

run_as() {   # run_as <user> <commands>
  local user="$1" cmd="$2" f rc=0
  f=$(mktemp "${TMP_DIR}/cmd.XXXXXX") || return 1
  {
    echo 'unset LD_LIBRARY_PATH'
    echo "export CV_ASSUME_DISTID=${CV_ASSUME_DISTID:-OEL7.8}"
    echo 'umask 0022'
    printf '%s\n' "${cmd}"
  } > "${f}"
  chmod 755 "${f}"
  su - "${user}" -c "bash ${f}" || rc=$?
  rm -f "${f}"
  return "${rc}"
}

run_grid() { run_as "${GRID_USER}"   "$(ora_env "${GRID_HOME}")${NL}$1"; }
run_ora()  { run_as "${ORACLE_USER}" "$(ora_env "${DB_HOME}")${NL}$1"; }

# run_sql <sid> <sql text>   (DB_HOME, OS authentication as sysdba)
run_sql() {
  local sid="$1" sql="$2" f rc=0
  f=$(mktemp --suffix=.sql "${TMP_DIR}/sql.XXXXXX") || return 1
  {
    echo 'SET PAGESIZE 200 LINESIZE 200 FEEDBACK OFF HEADING ON TRIMSPOOL ON VERIFY OFF'
    echo 'WHENEVER SQLERROR EXIT FAILURE'
    printf '%s\n' "${sql}"
    echo 'EXIT'
  } > "${f}"
  chmod 644 "${f}"
  run_as "${ORACLE_USER}" "$(ora_env "${DB_HOME}" "${sid}")${NL}${DB_HOME}/bin/sqlplus -s / as sysdba @${f}" || rc=$?
  rm -f "${f}"
  return "${rc}"
}

# sql_scalar <sid> <select ...;>  prints the first non-empty line, trimmed
sql_scalar() {
  local sid="$1" sql="$2"
  run_sql "${sid}" "SET HEADING OFF PAGESIZE 0${NL}${sql}" 2>/dev/null \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | head -1
}

# -----------------------------------------------------------------------------
# Database and CRS helpers
# -----------------------------------------------------------------------------
detect_db() {
  if [[ -z "${DB_NAME:-}" ]]; then
    local list
    list=$(run_grid "${GRID_HOME}/bin/srvctl config database" 2>/dev/null | grep -v '^$' || true)
    [[ "$(echo "${list}" | wc -l)" -eq 1 && -n "${list}" ]] \
      || die "DB_NAME is empty and srvctl does not list exactly one database. Set DB_NAME in patch.conf."
    DB_NAME="${list}"
  fi
  if [[ -z "${DB_SID:-}" ]]; then
    DB_SID=$(run_grid "${GRID_HOME}/bin/srvctl status database -d ${DB_NAME}" 2>/dev/null \
             | sed -n 's/^Instance \([^ ]*\) is running.*/\1/p' | head -1 || true)
    DB_SID="${DB_SID:-${DB_NAME}}"
  fi
  log "Database ${DB_NAME}, instance ${DB_SID}"
}

wait_until() {   # wait_until <timeout_s> <interval_s> <description> <command...>
  local timeout="$1" interval="$2" desc="$3" waited=0; shift 3
  until "$@" >/dev/null 2>&1; do
    (( waited >= timeout )) && { warn "Timed out after ${timeout}s waiting for: ${desc}"; return 1; }
    sleep "${interval}"; waited=$(( waited + interval ))
  done
  log "  ${desc}: ready after ${waited}s"
}

crs_online() {
  local out; out=$(run_grid "${GRID_HOME}/bin/crsctl check crs" 2>&1 || true)
  [[ "$(echo "${out}" | grep -c 'is online')" -ge 3 ]]
}

db_open() {
  local st; st=$(sql_scalar "${DB_SID}" "select status from v\$instance;" || true)
  [[ "${st}" == "OPEN" ]]
}

db_is_cdb() { [[ "$(sql_scalar "${DB_SID}" "select cdb from v\$database;" || true)" == "YES" ]]; }

stop_listeners() { run_grid "${GRID_HOME}/bin/srvctl stop listener" || warn "srvctl stop listener returned non-zero (already stopped?)"; }
start_listeners(){ run_grid "${GRID_HOME}/bin/srvctl start listener" || warn "srvctl start listener returned non-zero (already running?)"; }
stop_database()  { run_grid "${GRID_HOME}/bin/srvctl stop database -d ${DB_NAME} -o immediate" || warn "srvctl stop database returned non-zero (already stopped?)"; }
start_database() { run_grid "${GRID_HOME}/bin/srvctl start database -d ${DB_NAME}"; }

open_pdbs() {
  db_is_cdb || return 0
  run_sql "${DB_SID}" "alter pluggable database all open;" || warn "Could not open every PDB; check v\$pdbs"
}

# -----------------------------------------------------------------------------
# OPatch / inventory helpers
# -----------------------------------------------------------------------------
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }   # $1 >= $2

home_user() { [[ "$1" == "${GRID_HOME}" ]] && echo "${GRID_USER}" || echo "${ORACLE_USER}"; }

opatch_version() {   # opatch_version <home>
  run_as "$(home_user "$1")" "$(ora_env "$1")${NL}$1/OPatch/opatch version 2>/dev/null" \
    | sed -n 's/^OPatch Version: *//p' | head -1
}

lspatches() {   # lspatches <home>  -> "id;description" lines
  run_as "$(home_user "$1")" "$(ora_env "$1")${NL}$1/OPatch/opatch lspatches 2>&1" | grep -E '^[0-9]+;' || true
}

has_patch() { lspatches "$1" | grep -q "^$2;"; }

# patch IDs = numeric sub-directories of an extracted MRP
mrp_ids() { find "$1" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' 2>/dev/null | sort -u; }

csv_to_lines() { tr ',' '\n' <<< "$1" | sed 's/[[:space:]]//g' | grep -v '^$' || true; }

GI_MRP_DIR="${PATCH_LOC}/${GI_MRP_PATCH}"
DB_MRP_DIR="${PATCH_LOC}/${DB_MRP_PATCH}"

# IDs the DB home must contain after the MRP: patch.conf value, else auto-discovered
db_expected_ids() {
  if [[ -n "${DB_HOME_EXPECTED_IDS:-}" ]]; then csv_to_lines "${DB_HOME_EXPECTED_IDS}"
  elif [[ "${DB_PATCH_METHOD}" == "DB_MRP" ]]; then mrp_ids "${DB_MRP_DIR}"
  else :; fi
}

home_has_all() {   # home_has_all <home> <id...>   (true when list is non-empty and all present)
  local home="$1"; shift
  [[ $# -gt 0 ]] || return 1
  local installed id; installed=$(lspatches "${home}")
  for id in "$@"; do grep -q "^${id};" <<< "${installed}" || return 1; done
}

# -----------------------------------------------------------------------------
# Prep helpers
# -----------------------------------------------------------------------------
extract_patch() {   # extract_patch <zip> <patch_id>
  local zip="${PATCH_LOC}/$1" id="$2" dir="${PATCH_LOC}/$2"
  [[ -f "${zip}" ]] || die "Missing ${zip}"
  if [[ -d "${dir}" && -n "$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    log "  ${dir} already extracted, skipping unzip"
  else
    unzip -oq "${zip}" -d "${PATCH_LOC}" || die "unzip failed for ${zip}"
    log "  extracted ${zip}"
  fi
  # grid / oracle must be able to read what root extracted (learned: UID of extractor is kept)
  chown -R "root:${INSTALL_GROUP}" "${dir}"
  chmod -R a+rX "${dir}"
  [[ -d "${dir}" ]] || die "${dir} not found after unzip: wrong zip?"
}

update_opatch_home() {   # update_opatch_home <home>
  local home="$1" user ver need=false
  user=$(home_user "${home}")
  ver=$(opatch_version "${home}")
  [[ -n "${ver}" ]] || die "Could not read OPatch version in ${home}"
  log "  ${home}: OPatch ${ver} (minimum ${MIN_OPATCH_VERSION})"
  case "${UPDATE_OPATCH:-auto}" in
    yes)  need=true ;;
    auto) version_ge "${ver}" "${MIN_OPATCH_VERSION}" || need=true ;;
    no)   version_ge "${ver}" "${MIN_OPATCH_VERSION}" || die "OPatch ${ver} in ${home} is older than ${MIN_OPATCH_VERSION} and UPDATE_OPATCH=no" ;;
  esac
  if [[ "${need}" == "true" ]]; then
    [[ -f "${PATCH_LOC}/${OPATCH_ZIP}" ]] || die "OPatch update needed for ${home} but ${PATCH_LOC}/${OPATCH_ZIP} is missing"
    chmod a+r "${PATCH_LOC}/${OPATCH_ZIP}"
    run_as "${user}" "set -e
old=${home}/OPatch.pre_${MRP_LABEL}_$(date +%Y%m%d%H%M%S)
mv ${home}/OPatch \${old}
unzip -oq ${PATCH_LOC}/${OPATCH_ZIP} -d ${home}
# datapatch lives in OPatch/: keep the one from the old copy if the zip does not carry it
if [ ! -x ${home}/OPatch/datapatch ] && [ -x \${old}/datapatch ]; then cp -p \${old}/datapatch ${home}/OPatch/datapatch; fi" || die "OPatch update failed in ${home}"
    ver=$(opatch_version "${home}")
    version_ge "${ver}" "${MIN_OPATCH_VERSION}" || die "OPatch in ${home} is still ${ver} after update"
    log "  ${home}: OPatch updated to ${ver} (old copy kept as OPatch.pre_*)"
  fi
}

check_ru_level() {   # check_ru_level <home> <label>
  local home="$1" label="$2" out
  out=$(lspatches "${home}")
  if grep -Eq "${BASE_RU_REGEX}" <<< "${out}"; then
    pass "${label} (${home}) is at the required RU level (${BASE_RU_REGEX})"
  else
    fail "${label} (${home}) does not show RU level matching '${BASE_RU_REGEX}' in opatch lspatches"
    [[ "${ALLOW_RU_MISMATCH:-no}" == "yes" ]] && { warn "ALLOW_RU_MISMATCH=yes, continuing"; FAILED=$(( FAILED - 1 )); }
  fi
}

space_check() {   # space_check <path> <need_gb> <label>
  local avail
  avail=$(df -Pk "$1" | awk 'NR==2{printf "%d", $4/1048576}')
  if (( avail >= $2 )); then pass "$3: ${avail} GB free in $1 (need ${2} GB)"
  else fail "$3: only ${avail} GB free in $1 (need ${2} GB)"; fi
}

backup_homes() {
  local dest="${BACKUP_DIR}/${MRP_LABEL}" h name inv
  mkdir -p "${dest}"
  for h in "${GRID_HOME}" "${DB_HOME}"; do
    name="$(basename "$(dirname "${h}")")_$(basename "${h}")"
    if [[ -s "${dest}/${name}.tgz" ]]; then log "  ${dest}/${name}.tgz exists, skipping"; continue; fi
    log "  backing up ${h} -> ${dest}/${name}.tgz (this takes a while)"
    tar --warning=no-file-changed -czpf "${dest}/${name}.tgz" -C "$(dirname "${h}")" "$(basename "${h}")" \
      || [[ $? -eq 1 ]] || die "tar failed for ${h}"
  done
  inv=$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc 2>/dev/null | head -1 || true)
  if [[ -n "${inv}" && -d "${inv}" && ! -s "${dest}/oraInventory.tgz" ]]; then
    tar -czpf "${dest}/oraInventory.tgz" -C "$(dirname "${inv}")" "$(basename "${inv}")" || warn "inventory backup failed"
  fi
  if [[ -f /etc/oratab ]]; then cp -p /etc/oratab "${dest}/oratab"; fi
  if [[ -f /etc/oracle/olr.loc ]]; then cp -p /etc/oracle/olr.loc "${dest}/olr.loc"; fi
  ls -lh "${dest}"
}

# -----------------------------------------------------------------------------
# Phase 1 steps (shared by the single-node phase1 and the Data Guard prep script)
# -----------------------------------------------------------------------------
prep_1() {
  [[ -f "${PATCH_LOC}/${GI_MRP_ZIP}" ]] || die "Missing ${PATCH_LOC}/${GI_MRP_ZIP}"
  [[ -f "${PATCH_LOC}/${DB_MRP_ZIP}" ]] || die "Missing ${PATCH_LOC}/${DB_MRP_ZIP}"
  [[ "${UPDATE_OPATCH}" == "no" || -f "${PATCH_LOC}/${OPATCH_ZIP}" ]] || warn "${OPATCH_ZIP} not staged: only fine if OPatch is already new enough"
  [[ -x "${GRID_HOME}/OPatch/opatch" ]] || die "No OPatch in ${GRID_HOME}"
  [[ -x "${DB_HOME}/OPatch/opatch"   ]] || die "No OPatch in ${DB_HOME}"
  chmod o+rx "${PATCH_LOC}" 2>/dev/null || true
  # grid and oracle must be able to read the scripts and the patches
  run_as "${GRID_USER}"   "test -r ${SCRIPT_DIR}/patch.conf && test -r ${PATCH_LOC}/${GI_MRP_ZIP}" || die "${GRID_USER} cannot read scripts or staging (is anything under /root?)"
  run_as "${ORACLE_USER}" "test -r ${SCRIPT_DIR}/patch.conf && test -r ${PATCH_LOC}/${DB_MRP_ZIP}" || die "${ORACLE_USER} cannot read scripts or staging"
  crs_online && pass "CRS stack is online" || die "CRS is not online. Start it before patching."
  detect_db
  if db_open; then pass "database ${DB_NAME} is OPEN"
  elif [[ "${DG_MODE:-no}" == "yes" ]] && instance_up; then pass "instance ${DB_SID} is up (mounted standby)"
  else die "database ${DB_NAME} is not open"; fi
}

prep_2() {
  space_check "${PATCH_LOC}" "${MIN_FREE_GB_STAGING}" "staging"
  space_check "${GRID_HOME}" "${MIN_FREE_GB_HOMES}" "Grid home file system"
  space_check "${DB_HOME}"   "${MIN_FREE_GB_HOMES}" "DB home file system"
  if [[ "${BACKUP_HOMES}" == "yes" ]]; then
    mkdir -p "${BACKUP_DIR}"
    local need=$(( ( $(du -sm "${GRID_HOME}" | cut -f1) + $(du -sm "${DB_HOME}" | cut -f1) ) * 6 / 10 / 1024 + 1 ))
    space_check "${BACKUP_DIR}" "${need}" "backup directory"
  fi
  (( FAILED == 0 )) || die "Not enough disk space."
}

prep_3() {
  extract_patch "${GI_MRP_ZIP}" "${GI_MRP_PATCH}"
  extract_patch "${DB_MRP_ZIP}" "${DB_MRP_PATCH}"
  log "  GI MRP sub-patches : $(mrp_ids "${GI_MRP_DIR}" | tr '\n' ' ')"
  log "  DB MRP sub-patches : $(mrp_ids "${DB_MRP_DIR}" | tr '\n' ' ')"
}

prep_4() { update_opatch_home "${GRID_HOME}"; update_opatch_home "${DB_HOME}"; }

prep_5() {
  check_ru_level "${GRID_HOME}" "Grid home"
  check_ru_level "${DB_HOME}" "DB home"
  run_as "${GRID_USER}" "$(ora_env "${GRID_HOME}")${NL}${GRID_HOME}/OPatch/opatch lsinventory -detail -oh ${GRID_HOME} >${TMP_DIR}/lsinv_grid.txt 2>&1" \
    && pass "lsinventory -detail OK on Grid home" || fail "lsinventory failed on Grid home (see ${TMP_DIR}/lsinv_grid.txt)"
  run_as "${ORACLE_USER}" "$(ora_env "${DB_HOME}")${NL}${DB_HOME}/OPatch/opatch lsinventory -detail -oh ${DB_HOME} >${TMP_DIR}/lsinv_db.txt 2>&1" \
    && pass "lsinventory -detail OK on DB home" || fail "lsinventory failed on DB home (see ${TMP_DIR}/lsinv_db.txt)"
  (( FAILED == 0 )) || die "Home checks failed."
}

prep_6() {
  log "  Grid home: opatchauto apply -analyze (GI readme, prerequisite 5)"
  (
    export ORACLE_HOME="${GRID_HOME}" CV_ASSUME_DISTID="${CV_ASSUME_DISTID}"
    export PATH="${GRID_HOME}/OPatch:${PATH}"; unset LD_LIBRARY_PATH
    cd "${PATCH_LOC}"
    "${GRID_HOME}/OPatch/opatchauto" apply "${GI_MRP_DIR}" -analyze -oh "${GRID_HOME}"
  ) && pass "no conflicts on Grid home" || die "opatchauto -analyze reported a problem on the Grid home. Read the output above."
  if [[ "${DB_PATCH_METHOD}" == "DB_MRP" ]]; then
    log "  DB home: opatch prereq CheckConflictAgainstOHWithDetail (DB readme, prerequisite 5)"
    run_ora "cd ${PATCH_LOC}
${DB_HOME}/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./${DB_MRP_PATCH}" \
      && pass "no conflicts on DB home" || die "Conflicts against the DB home. Resolve (request merge patches or roll back the conflicting one-offs) before the outage."
  else
    log "  DB home: opatchauto apply -binary -analyze"
    run_ora "cd ${PATCH_LOC}
${DB_HOME}/OPatch/opatchauto apply -binary ${GI_MRP_DIR} -analyze -oh ${DB_HOME} -target_type oracle_database" \
      && pass "no conflicts on DB home" || die "opatchauto -analyze reported a problem on the DB home."
  fi
}

prep_7() {
  lspatches "${GRID_HOME}" | sort > "${LOG_DIR}/pre_lspatches_grid.txt"
  lspatches "${DB_HOME}"   | sort > "${LOG_DIR}/pre_lspatches_db.txt"
  run_sql "${DB_SID}" "select name, open_mode, database_role from v\$database;
select banner_full from v\$version where rownum = 1;" | while IFS= read -r l; do log "  ${l}"; done
  if db_open; then
    local objs="dba_objects"; db_is_cdb && objs="cdb_objects"
    sql_scalar "${DB_SID}" "select count(*) from ${objs} where status='INVALID';" > "${LOG_DIR}/.invalid_baseline" || true
    log "  invalid objects before patching: $(cat "${LOG_DIR}/.invalid_baseline")"
  else log "  database not open (mounted standby): invalid object baseline skipped"; fi
}

prep_8() {
  if [[ "${BACKUP_HOMES}" == "yes" ]]; then backup_homes
  else warn "BACKUP_HOMES=no: no home backup taken. Make sure a snapshot or backup exists."; fi
  log "  Reminder: take an RMAN backup / VM snapshot of the database before phase 2."
}


# -----------------------------------------------------------------------------
# SYS.DB_DDL_ALERT_TRG: disabled before the outage, enabled afterwards.
# Non-CDB: one statement. CDB: CDB$ROOT and every open PDB via catcon.pl.
# Containers without the trigger are skipped.
# -----------------------------------------------------------------------------
ddl_trigger() {   # ddl_trigger DISABLE|ENABLE
  [[ "${DDL_TRIGGER_HANDLING:-yes}" == "yes" ]] || { log "  DDL trigger handling is off, skipping"; return 0; }
  local action="$1" body one logd out rc=0
  body=$(mktemp --suffix=.sql "${TMP_DIR}/ddl.XXXXXX"); one=$(mktemp --suffix=.sql "${TMP_DIR}/ddl1.XXXXXX")
  out=$(mktemp "${TMP_DIR}/ddlout.XXXXXX")
  cat > "${body}" <<SQLEOF
SET SERVEROUTPUT ON
DECLARE
  v_cnt PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM dba_triggers WHERE owner = 'SYS' AND trigger_name = 'DB_DDL_ALERT_TRG';
  IF v_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('DB_DDL_ALERT_TRG ' || SYS_CONTEXT('USERENV','CON_NAME') || ': not present, skipped');
  ELSE
    EXECUTE IMMEDIATE 'ALTER TRIGGER SYS.DB_DDL_ALERT_TRG ${action}';
    DBMS_OUTPUT.PUT_LINE('DB_DDL_ALERT_TRG ' || SYS_CONTEXT('USERENV','CON_NAME') || ': ${action} done');
  END IF;
END;
/
SQLEOF
  { echo "WHENEVER SQLERROR EXIT FAILURE"; cat "${body}"; echo "EXIT"; } > "${one}"
  chmod 644 "${body}" "${one}"
  if db_is_cdb; then
    logd=$(mktemp -d "${TMP_DIR}/ddllogs.XXXXXX"); chmod 777 "${logd}"
    log "  CDB: ${action} in CDB\$ROOT and all open PDBs (PDB\$SEED excluded)"
    run_as "${ORACLE_USER}" "$(ora_env "${DB_HOME}" "${DB_SID}")${NL}${DB_HOME}/perl/bin/perl ${DB_HOME}/rdbms/admin/catcon.pl -d ${TMP_DIR} -l ${logd} -b ddl_trg -C 'PDB\$SEED' $(basename "${body}")" > "${out}" 2>&1 || rc=$?
    { grep -h 'DB_DDL_ALERT_TRG' "${logd}"/*.log 2>/dev/null || true; } | sort -u | while IFS= read -r l; do log "  ${l}"; done
    if grep -lE 'ORA-[0-9]+|SP2-[0-9]+' "${logd}"/*.log >/dev/null 2>&1; then
      { grep -hE 'ORA-[0-9]+|SP2-[0-9]+' "${logd}"/*.log || true; } | sort -u | while IFS= read -r l; do log "  ERROR: ${l}"; done
      rc=1
    fi
    [[ -n "$(ls "${logd}"/*.log 2>/dev/null)" ]] || { log "  ERROR: catcon produced no logs"; rc=1; }
    rm -rf "${logd}"
  else
    run_as "${ORACLE_USER}" "$(ora_env "${DB_HOME}" "${DB_SID}")${NL}${DB_HOME}/bin/sqlplus -s / as sysdba @${one}" > "${out}" 2>&1 || rc=$?
    while IFS= read -r l; do log "  ${l}"; done < "${out}"
  fi
  rm -f "${body}" "${one}" "${out}"
  return "${rc}"
}

# -----------------------------------------------------------------------------
# Applying the MRP (in place)
# -----------------------------------------------------------------------------
db_home_patched() {
  local ids; ids=$(db_expected_ids | tr '\n' ' ')
  # shellcheck disable=SC2086
  home_has_all "${DB_HOME}" ${ids}
}

grid_home_patched() {
  local ids; ids=$(csv_to_lines "${GRID_HOME_EXPECTED_IDS:-}" | tr '\n' ' ')
  # shellcheck disable=SC2086
  home_has_all "${GRID_HOME}" ${ids}
}

apply_db_home() {
  if db_home_patched; then log "  DB home already contains the MRP patches, skipping"; return 0; fi
  if [[ "${DB_PATCH_METHOD}" == "DB_MRP" ]]; then
    log "  opatch napply ${DB_MRP_PATCH} on ${DB_HOME}"
    run_ora "cd ${PATCH_LOC}
${DB_HOME}/OPatch/opatch napply ./${DB_MRP_PATCH} -silent" \
      || die "opatch napply failed on ${DB_HOME}. Read the opatch log under ${DB_HOME}/cfgtoollogs/opatch, fix the cause, re-run phase 2 (napply is re-runnable; already applied patches are skipped)."
  else
    log "  opatchauto apply -binary ${GI_MRP_PATCH} on ${DB_HOME}"
    run_ora "cd ${PATCH_LOC}
${DB_HOME}/OPatch/opatchauto apply -binary ${GI_MRP_DIR} -oh ${DB_HOME} -target_type oracle_database" \
      || die "opatchauto -binary failed on ${DB_HOME}. See ${DB_HOME}/cfgtoollogs/opatchauto, fix the cause, re-run phase 2."
  fi
}

apply_grid_home() {
  if grid_home_patched; then log "  Grid home already contains the MRP patches, skipping"; return 0; fi
  log "  opatchauto apply ${GI_MRP_PATCH} on ${GRID_HOME} (stops and restarts the CRS stack)"
  (
    export ORACLE_HOME="${GRID_HOME}" CV_ASSUME_DISTID="${CV_ASSUME_DISTID:-OEL7.8}"
    export PATH="${GRID_HOME}/OPatch:${PATH}"
    unset LD_LIBRARY_PATH
    cd "${PATCH_LOC}"
    "${GRID_HOME}/OPatch/opatchauto" apply "${GI_MRP_DIR}" -oh "${GRID_HOME}"
  ) || die "opatchauto failed on ${GRID_HOME}. Fix the cause, then as root: ${GRID_HOME}/OPatch/opatchauto resume   (or re-run phase 2)."
}

wait_crs() { wait_until "${CRS_WAIT_SECONDS:-900}" 15 "CRS stack online" crs_online || die "CRS did not come online. Check: crsctl check crs / ${GRID_HOME}/log/$(hostname -s)/alert$(hostname -s).log"; }

run_datapatch() {
  open_pdbs
  # best effort, from the 19c patching notes: refresh the QOPATCH inventory before datapatch
  run_sql "${DB_SID}" "begin dbms_qopatch.load_xml_inventory; end;
/" >/dev/null 2>&1 || log "  (dbms_qopatch.load_xml_inventory not run: continuing)"
  log "  datapatch -verbose"
  run_ora "export ORACLE_SID=${DB_SID}
cd ${DB_HOME}/OPatch
./datapatch -verbose" || die "datapatch failed. See the sqlpatch logs under cfgtoollogs/sqlpatch in the Oracle base (path is in the output above), fix the cause, then re-run phase 2 from step 7: --phase 2 --from-step 7"
}

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
verify_binaries() {
  local ids installed id
  step "DB home ${DB_HOME}: opatch lspatches"
  installed=$(lspatches "${DB_HOME}"); echo "${installed}" | while IFS= read -r l; do log "  ${l}"; done
  for id in $(db_expected_ids); do
    if grep -q "^${id};" <<< "${installed}"; then pass "DB home has patch ${id}"; else fail "DB home is missing patch ${id}"; fi
  done
  step "Grid home ${GRID_HOME}: opatch lspatches"
  installed=$(lspatches "${GRID_HOME}"); echo "${installed}" | while IFS= read -r l; do log "  ${l}"; done
  for id in $(csv_to_lines "${GRID_HOME_EXPECTED_IDS:-}"); do
    if grep -q "^${id};" <<< "${installed}"; then pass "Grid home has patch ${id}"
    elif [[ "${GRID_VERIFY_STRICT:-no}" == "yes" ]]; then fail "Grid home is missing patch ${id}"
    else warn "Grid home does not list patch ${id} (GRID_VERIFY_STRICT=no): compare with ${LOG_DIR}/pre_lspatches_grid.txt"; fi
  done
  if [[ -s "${LOG_DIR}/pre_lspatches_grid.txt" ]]; then
    if diff -q <(sort "${LOG_DIR}/pre_lspatches_grid.txt") <(lspatches "${GRID_HOME}" | sort) >/dev/null; then
      fail "Grid home patch list is identical to the pre-patch list: the GI MRP did not change anything"
    else pass "Grid home patch list changed versus pre-patch snapshot"; fi
  fi
  step "OPatch inventory consistency"
  run_as "$(home_user "${DB_HOME}")" "$(ora_env "${DB_HOME}")${NL}${DB_HOME}/OPatch/opatch lsinventory -oh ${DB_HOME} >/dev/null 2>&1" \
    && pass "lsinventory OK on DB home" || fail "lsinventory failed on DB home"
  run_as "${GRID_USER}" "$(ora_env "${GRID_HOME}")${NL}${GRID_HOME}/OPatch/opatch lsinventory -oh ${GRID_HOME} >/dev/null 2>&1" \
    && pass "lsinventory OK on Grid home" || fail "lsinventory failed on Grid home"
}

verify_crs() {
  step "CRS"
  crs_online && pass "crsctl check crs: online" || fail "CRS is not fully online"
  run_grid "${GRID_HOME}/bin/crsctl query crs releasepatch; ${GRID_HOME}/bin/crsctl query crs softwarepatch" 2>&1 | while IFS= read -r l; do log "  ${l}"; done
  run_grid "${GRID_HOME}/bin/crsctl status resource -t" 2>&1 | while IFS= read -r l; do log "  ${l}"; done
}

verify_registry() {   # run on a PRIMARY / open database only
  local view="dba_registry_sqlpatch" objs="dba_objects" con_col="0 con_id" con_part="" bad base now
  if db_is_cdb; then view="cdb_registry_sqlpatch"; objs="cdb_objects"; con_col="con_id"; con_part="con_id, "; fi
  step "datapatch registry (latest record per patch; ROW_NUMBER ignores old rollback history)"
  bad=$(run_sql "${DB_SID}" "SET HEADING OFF
select 'con '||con_id||' patch '||patch_id||' '||action||' '||status from (
  select ${con_col}, patch_id, action, status,
         row_number() over (partition by ${con_part}patch_id order by action_time desc) rn
  from ${view}) where rn = 1 and status <> 'SUCCESS';" 2>&1 | grep -v '^$' || true)
  if [[ -z "${bad}" ]]; then pass "no sqlpatch record with a status other than SUCCESS"
  else echo "${bad}" | while IFS= read -r l; do log "  ${l}"; done; fail "sqlpatch records not in SUCCESS"; fi
  run_sql "${DB_SID}" "select patch_id, action, status, to_char(action_time,'YYYY-MM-DD HH24:MI') action_time, substr(description,1,60) description
from (select * from ${view} order by action_time desc) where rownum <= 8;" 2>&1 | while IFS= read -r l; do log "  ${l}"; done
  step "invalid objects"
  base=$(cat "${LOG_DIR}/.invalid_baseline" 2>/dev/null || echo "")
  run_sql "${DB_SID}" "@?/rdbms/admin/utlrp.sql" >/dev/null 2>&1 || warn "utlrp returned non-zero"
  now=$(sql_scalar "${DB_SID}" "select count(*) from ${objs} where status='INVALID';" || echo "")
  log "  invalid objects now: ${now:-unknown}, before patching: ${base:-unknown}"
  if [[ "${base}" =~ ^[0-9]+$ && "${now}" =~ ^[0-9]+$ && "${now}" -gt "${base}" ]]; then fail "more invalid objects than before patching (${now} > ${base})"
  else pass "invalid object count did not grow"; fi
}

# chopt: in-place patching relinks the binaries, so verify the options kept off are still off
option_value() {   # option_value <v$option parameter>
  sql_scalar "${DB_SID}" "select distinct value from v\$option where parameter = '$1';" || true
}

chopt_reconcile() {
  local o param cdb=false drift=""
  db_is_cdb && cdb=true
  for o in ${CHOPT_DISABLE:-}; do
    o="${o,,}"
    case "${o}" in
      olap) param="OLAP" ;;
      rat)  param="Real Application Testing" ;;
      partitioning)
        if [[ "${cdb}" == "true" ]]; then log "  partitioning: not touched on a CDB"; continue; fi
        param="Partitioning" ;;
      *) die "Unknown option '${o}' in CHOPT_DISABLE (allowed: olap rat partitioning)" ;;
    esac
    if [[ "$(option_value "${param}")" == "TRUE" ]]; then drift+="${o} "; warn "option ${o} is TRUE again after patching"; else pass "option ${o} is still disabled"; fi
  done
  if [[ "${PARTITIONING_REQUIRED:-no}" == "yes" ]]; then
    if [[ "$(option_value Partitioning)" == "TRUE" ]]; then pass "Partitioning is enabled, as required"
    else fail "Partitioning is not TRUE but is required (stop DB, chopt enable partitioning, start DB)"; fi
  fi
  [[ -z "${drift}" ]] && return 0
  if [[ "${CHOPT_REAPPLY:-no}" != "yes" ]]; then fail "options to disable again: ${drift}(CHOPT_REAPPLY=no). Fix per node: stop the database, as ${ORACLE_USER} run ${DB_HOME}/bin/chopt disable <option>, start the database, then re-run this check"; return 0; fi
  log "  re-applying chopt disable for: ${drift}(database restart)"
  stop_database
  for o in ${drift}; do run_ora "cd ${DB_HOME}/bin && ./chopt disable ${o}" || die "chopt disable ${o} failed"; done
  start_database
  wait_until 600 10 "database open" db_open || die "database did not open after chopt"
  open_pdbs
  if [[ " ${drift}" == *" olap "* ]]; then
    local f; f=$(mktemp --suffix=.sql "${TMP_DIR}/olap.XXXXXX"); printf 'exec sys.xoq_validate\nexec sys.aps_validate\n' > "${f}"; chmod 644 "${f}"
    if [[ "${cdb}" == "true" ]]; then
      local d; d=$(mktemp -d "${TMP_DIR}/olaplogs.XXXXXX"); chmod 777 "${d}"
      run_as "${ORACLE_USER}" "$(ora_env "${DB_HOME}" "${DB_SID}")${NL}${DB_HOME}/perl/bin/perl ${DB_HOME}/rdbms/admin/catcon.pl -d ${TMP_DIR} -l ${d} -b olap_val $(basename "${f}")" \
        || warn "catcon OLAP validation returned non-zero, check ${d}"
    else run_as "${ORACLE_USER}" "$(ora_env "${DB_HOME}" "${DB_SID}")${NL}${DB_HOME}/bin/sqlplus -s / as sysdba @${f}"; fi
    rm -f "${f}"
  fi
}

# -----------------------------------------------------------------------------
# Security re-assertion (FIPS file, extproc) after the binaries changed
# -----------------------------------------------------------------------------
harden_db_home() {
  local ldap="${DB_HOME}/ldap/admin" ext="${DB_HOME}/bin/extproc"
  mkdir -p "${ldap}"
  printf 'SSLFIPS_140=TRUE\n' > "${ldap}/fips.ora"
  chown "${ORACLE_USER}:${INSTALL_GROUP}" "${ldap}/fips.ora"; chmod 640 "${ldap}/fips.ora"
  log "  fips.ora: $(ls -l "${ldap}/fips.ora")"
  if [[ -f "${ext}" ]]; then mv -f "${ext}" "${ext}.orig"; log "  extproc renamed to extproc.orig (the MRP restored it)"
  elif [[ -f "${ext}.orig" ]]; then log "  extproc already disabled"
  else warn "extproc not found in ${DB_HOME}/bin"; fi
  [[ ! -f "${ext}" ]] && pass "extproc is disabled" || fail "extproc is active"
}

# -----------------------------------------------------------------------------
# Rollback (README section 4 of both patches)
# -----------------------------------------------------------------------------
rollback_db_home() {
  local ids="" id installed
  installed=$(lspatches "${DB_HOME}")
  for id in $(mrp_ids "${DB_MRP_DIR}"); do grep -q "^${id};" <<< "${installed}" && ids+="${id},"; done
  ids="${ids%,}"
  if [[ -z "${ids}" ]]; then log "  no MRP patch ids found in ${DB_HOME}, nothing to roll back"; return 0; fi
  if [[ "${DB_PATCH_METHOD}" == "DB_MRP" ]]; then
    log "  opatch nrollback -id ${ids}"
    run_ora "${DB_HOME}/OPatch/opatch nrollback -id ${ids} -silent" || die "nrollback failed on ${DB_HOME}"
  else
    run_ora "cd ${PATCH_LOC}
${DB_HOME}/OPatch/opatchauto rollback -binary ${GI_MRP_DIR} -oh ${DB_HOME} -target_type oracle_database" || die "opatchauto rollback -binary failed on ${DB_HOME}"
  fi
}

rollback_grid_home() {
  log "  opatchauto rollback ${GI_MRP_PATCH} on ${GRID_HOME}"
  (
    export ORACLE_HOME="${GRID_HOME}" CV_ASSUME_DISTID="${CV_ASSUME_DISTID:-OEL7.8}"
    export PATH="${GRID_HOME}/OPatch:${PATH}"
    unset LD_LIBRARY_PATH
    cd "${PATCH_LOC}"
    "${GRID_HOME}/OPatch/opatchauto" rollback "${GI_MRP_DIR}" -oh "${GRID_HOME}"
  ) || die "opatchauto rollback failed on ${GRID_HOME}"
}

print_summary() {
  echo
  echo "========================================================"
  if (( FAILED == 0 )); then echo "  RESULT: ALL CHECKS PASSED  [${PHASE_NAME:-}]"; echo "========================================================"; return 0
  else echo "  RESULT: ${FAILED} CHECK(S) FAILED  [${PHASE_NAME:-}]"; echo "  Review: ${PHASE_LOG:-the log}"; echo "========================================================"; return 1; fi
}
