# Database major upgrade (RDS PostgreSQL)

Tooling and the short procedure used for OPSD-132 (UAT 14 → 17). The long form, prechecks and
the reporting-stack detach/re-attach steps are in the OpenLMIS PostgreSQL upgrade manual
(Confluence) and in `soldevelo-reporting-stack/docs/runbook-source-upgrade.md`.

## Rule while prod and UAT run different majors

`KEEP_OR_RESTORE=restore` rebuilds UAT from the latest **prod** snapshot. Until prod is on the
same major as UAT, a restore puts UAT back on the old major (and hangs on `wait_available` when
`.env-restore` names a parameter group of the newer family). Run the UAT job with `keep` only,
and switch `DB_PARAMETER_GROUP_NAME` in `.env-restore` to the new family right after the prod
upgrade.

## Scripts

Both are parameterised by environment variables, so they work for UAT and prod alike.

### `baseline.sh <label> [out-root]` — database state for a before/after `diff`

Runs on the host (needs Docker, `psql` comes from `PSQL_IMAGE`, default `postgres:17-alpine`).
Connection from `PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD/PGSSLMODE` or, when unset, from
`SOURCE_PG_*` in `ENV_FILE` (default `/opt/reporting-stack/.env`). Writes one text file per
check into `<out-root>/baseline-<label>/`: version, size, selected settings, extensions,
collation, per-schema object counts, columns, sequences, roles, publication, replication
slots, Flyway history per schema, large objects, planner stats, row count of every table and
content checksums of the business tables (`CHECKSUM_TABLES`).

```
./baseline.sh pg14 /root/opsd-132          # before the upgrade, services still running is fine
./baseline.sh pg17 /root/opsd-132          # after the upgrade, before the services start
diff -r /root/opsd-132/baseline-pg14 /root/opsd-132/baseline-pg17
```

Expected differences: `version.txt`, `server_version` in `settings.txt`, the PostGIS line in
`extensions.txt` after `ALTER EXTENSION postgis UPDATE`, `datcollversion` in `collation.txt`
(null on 14), `slots.txt` while the Debezium slot is dropped/re-created, `size.txt` (slightly).
Everything else must be identical. The row count pass reads the whole database, which also
warms the volume after the upgrade.

### `smoke-api.sh` — API round trip through nginx

Runs anywhere with `curl` and `jq`. Required: `BASE_URL`, `ADMIN_PASS`, `PROGRAM` (name),
`FACILITY` (code). Optional: `ADMIN_USER` (default `administrator`), `CLIENT_ID`/`CLIENT_SECRET`
(UI OAuth client), `SERVICE_CLIENT_ID`/`SERVICE_CLIENT_SECRET` (adds the service-token checks),
`REQ_FACILITY` (code of the facility that requisitions, default `FACILITY`), `SUPPLYING_DEPOT` (code), `TEST_USER`/`TEST_USER_PASS` (password reset round trip),
`REPORT_PARAMS` (query string for the Jasper PDFs), `LINE_ITEM_PATCH` (jq object merged into
every requisition line item before submit), `SMOKE_WRITES=0` (read-only run), `CHECK_LOGS=1`
with `LOG_SINCE`/`COMPOSE_PROJECT` (SQL-error scan of the service containers, host only).

```
export BASE_URL=https://uat.elmis.apps.moh.gm ADMIN_PASS=... PROGRAM='...' FACILITY=...
./smoke-api.sh | tee smoke-pg14.txt       # before the upgrade: proves the test itself passes
./smoke-api.sh | tee smoke-pg17.txt       # after
diff smoke-pg14.txt smoke-pg17.txt
```

What it exercises, in order: OAuth tokens, user lookup, optional password reset; referencedata
reads and a facility update that is reverted; a requisition initiated → updated → submitted →
authorized → approved → printed → converted to an order; the order's print, PODs and
shipments; stock card summaries, a +1/−1 adjustment pair, a physical inventory draft that is
deleted, valid sources/destinations, range summaries; a notification; every common Jasper
template as PDF (5xx fails, 4xx is recorded for the diff) and the dashboard reports; CCE
inventory and catalog; BUQ lists; diagnostics version; both UIs. Exit code is non-zero when any
check fails. The test requisition and order stay in the environment on purpose.

Not covered here, done by hand after the upgrade: proof-of-delivery confirmation and the
reporting-stack checks (`make verify-cdc`, `make reconcile`), plus one `keep` deploy from
Jenkins to prove the daily path on the new major.
