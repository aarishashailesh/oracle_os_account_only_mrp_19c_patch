# MRP 19.33: single node CRS, one OS owner (oracle)

MRP 19.33.0.0.261117 applied **in place** on the existing 19.33 homes. Companion of `oracle_os_account_only_automation_oop_patch`.

- Grid home: GI MRP 40196150 with `opatchauto` (root)
- DB home: DB MRP 40196156 with `opatch napply` (`DB_PATCH_METHOD=GI_MRP` switches to `opatchauto -binary`). Never both on one home.
- Then `datapatch -verbose`. Users: `oracle` owns Grid and the database (`GRID_USER=oracle`). Options kept off: `CHOPT_DISABLE="olap rat partitioning"`.
- Every command sets `ORACLE_HOME` and `PATH` explicitly and unsets `ORACLE_BASE`/`ORACLE_SID`, so the Grid variables in `.bashrc` do not leak into DB commands.

## Setup

1. Copy this directory to the host outside `/root`, edit `patch.conf` (`GRID_HOME`, `DB_HOME` without trailing slash, `DB_NAME`, `PATCH_LOC`, `LOG_DIR`, `BACKUP_DIR`). Defaults are placeholders.
2. Put `p40196150_1933000DBRU_Linux-x86-64.zip`, `p40196156_1933000DBRU_Linux-x86-64.zip` (and `p6880880_190000_Linux-x86-64.zip` if OPatch is older than 12.2.0.1.52) in `PATCH_LOC`.
3. Take a VM snapshot or RMAN backup. Run everything as root.

## Run

```bash
./patch_orchestrator.sh --phase 1 --dry-run   # resolved config and commands, nothing executed
./patch_orchestrator.sh --phase 1             # prep (online): zips, OPatch, RU level, conflicts, backups
./patch_orchestrator.sh --phase 2             # OUTAGE: stop, patch both homes, start, datapatch
./patch_orchestrator.sh --phase 3             # verify: patches, CRS, sqlpatch registry, invalid objects, options
./patch_orchestrator.sh --phase 4             # optional: fips.ora, extproc
./patch_orchestrator.sh --phase 5             # optional, last: AIDE baseline
./patch_orchestrator.sh --rollback --yes      # rollback (readme section 4)
```

Extra options: `--from-step N`, `--full` (phases 1 to 5), `--reset-status`, `--detach` (runs the phase as a `systemd-run` unit `mrp-p<n>` for hardened hosts; `systemctl stop` it afterwards).

## Files

| File | Purpose |
|---|---|
| `patch.conf` | all settings |
| `patch_orchestrator.sh` | master script |
| `phase1_prep.sh` to `phase5_aide.sh` | the phases |
| `rollback_mrp.sh` | rollback |
| `lib_mrp.sh` | shared functions |

Phase 2 is re-runnable: a home that already shows the MRP patches is skipped. See the repository README for the readme discrepancies (GI MRP says RU 19.32, DB MRP says 19.33) and the cut-off patch tables in the PDFs.
