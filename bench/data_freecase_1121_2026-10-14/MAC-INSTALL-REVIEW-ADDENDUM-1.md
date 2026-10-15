# Addendum 1: install and rollback recheck (mac-claude, 2026-10-14)

Addendum to MAC-INSTALL-REVIEW.md (sha 624eb505…), which is unchanged. This check covers only the files on VM100. I made no changes to VM801.

Rechecked files:

- `install-vm801.sh`: sha 2be0a80b…
- `rollback-vm801.sh`: sha 66cd822b…

## Status of earlier findings

- **R1: fixed.** `rollback:6` reads the system identifier with `pg_controldata` on `/data/pgfts/database` under `LC_ALL=C`. That works while PostgreSQL is stopped.
  - I did not confirm that `/data/pgfts/database` is VM801's data directory.
  - If the path is wrong, the guard fails closed, so the rollback stops without changing anything.
- **R2: fixed.**
  - `sha256sum -c rollback/SHA256SUMS` runs before extraction (line 7).
  - After extraction, line 14 asserts that the restored `pg_fts.so` has sha `8e165205…`.
- **R3: fixed.**
  - The idle-session check runs only when `pg_isready` reports the server up (lines 8–10).
  - An ERR trap writes `ROLLBACK_FAILED` to STATE.
  - The catalog downgrade is conditional on the current extension version (lines 18–23):
    - at 1.12.1, it runs the downgrade;
    - at 1.11.0, it does nothing, which covers an install that failed before `ALTER`;
    - any other version makes it exit with an error.
- **R4: accepted as intended.** The rollback adds the old runtime back and leaves the new SQL and bitcode files in place. With the old control file restored, those leftovers are harmless.
- **R6: fixed.** `LOAD 'pg_fts'` now runs after the restart in `install:25` and again in `rollback:24`.

## Remaining note

If the install fails before `mkdir rollback`, there is no `rollback/SHA256SUMS`, so the rollback stops at line 7. That case needs no rollback, because nothing had been changed yet.

## Verdict

I have no remaining findings. The scripts are ready from a static-review standpoint.
