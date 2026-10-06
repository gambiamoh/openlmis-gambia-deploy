# Grafana Alloy agent (OpenLMIS Gambia)

One Alloy agent per environment host. It collects host, container and app
metrics, container logs, the nginx log files and (optionally) PostgreSQL
metrics, and pushes them to the central
[soldevelo-monitoring](https://github.com/SolDevelo/soldevelo-monitoring)
stack at `olmis-monitoring.soldevelo.com`. It runs as its own compose project
(`soldevelo-monitoring-agents`), so app deploys do not touch it.

## Files

| File | What |
|---|---|
| `config.alloy` | The package agent config, **vendored** at the tag in `PACKAGE_VERSION`. Never edit it here. |
| `openlmis.alloy` | OpenLMIS additions: nginx access/error logs from the `nginx-log` volume. |
| `sync-from-package.sh` | Re-copies `config.alloy` for `PACKAGE_VERSION`; `--check` reports drift. |
| `deploy_alloy.sh` | Builds the image on the env's Docker daemon and starts the agent. |
| `.env.example` | The variables. Real values: `<env>_env/alloy.env` in `openlmis-gambia-config`. |

Upgrade: bump `PACKAGE_VERSION`, run `./sync-from-package.sh`, read the diff and
the package CHANGELOG, commit, deploy.

## Deploy

Manual Jenkins job `OpenLMIS-Gambia-monitoring-alloy-deploy-to-<env>`. It checks
out this repo and `openlmis-gambia-config` (into `deployment-config/`) and runs
`monitoring/alloy/deploy_alloy.sh <env>` from the workspace root.

## Scraping apps

The agent scrapes containers labelled `monitoring.scrape: "true"`, at
`monitoring.port` + `monitoring.path`, named by `monitoring.service` (see
`uat/docker-compose.yml`). Labels apply on the next app deploy. `report`
(gambia-reports) has no actuator endpoint and is not scraped.

## PostgreSQL

`postgres-exporter` runs only with `COMPOSE_PROFILES=postgres` and
`PG_EXPORTER_DSN` in `alloy.env`, as a read-only role:

```sql
CREATE ROLE olmis_monitoring LOGIN PASSWORD '...';
GRANT pg_monitor TO olmis_monitoring;
```

A UAT restore replaces the RDS instance from the prod snapshot, which has no
such role; `shared/restore/after_restore.sh` re-creates it when
`MONITORING_DB_PASSWORD` is set in `.env-restore`.

## Notes

- `network_mode: host`, not the app network, so app deploys never find a
  foreign container on `<env>_default`.
- `COMPOSE_PROJECT_NAME` must stay `soldevelo-monitoring-agents`: `config.alloy`
  drops the agent's own logs by that project name.
- Labels: `app=openlmis`, `deployment=gambia`, `environment=uat|prod`.
