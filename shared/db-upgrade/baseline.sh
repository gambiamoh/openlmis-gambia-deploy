#!/usr/bin/env bash
# Database baseline for a before/after major-upgrade comparison:
#   baseline.sh pg14 /root/opsd-132; <upgrade>; baseline.sh pg17 /root/opsd-132
#   diff -r /root/opsd-132/baseline-pg14 /root/opsd-132/baseline-pg17
# Connection: PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD/PGSSLMODE, or SOURCE_PG_* read from
# ENV_FILE (default: the reporting stack's .env on the UAT host). psql runs from PSQL_IMAGE,
# like psql_rds in <env>/deploy_to_env.sh, so the host's own psql version does not matter.
set -uo pipefail

LABEL=${1:?usage: baseline.sh <label> [out-root]}
OUT=${2:-$PWD}/baseline-$LABEL
ENV_FILE=${ENV_FILE:-/opt/reporting-stack/.env}
PSQL_IMAGE=${PSQL_IMAGE:-postgres:17-alpine}
# Content checksums are limited to the business tables; counting every row of the multi-GB
# Javers tables is done in rowcounts.txt, hashing them would take too long on a t3.medium.
CHECKSUM_TABLES=${CHECKSUM_TABLES:-"auth.auth_users referencedata.facilities referencedata.orderables referencedata.programs referencedata.role_assignments referencedata.users requisition.requisitions requisition.requisition_line_items requisition.status_changes fulfillment.orders fulfillment.order_line_items fulfillment.proofs_of_delivery stockmanagement.stock_cards stockmanagement.stock_card_line_items stockmanagement.physical_inventories report.jasper_templates"}

get_env() { grep "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-; }
PGHOST=${PGHOST:-$(get_env SOURCE_PG_HOST)}
PGPORT=${PGPORT:-$(get_env SOURCE_PG_PORT)}
PGDATABASE=${PGDATABASE:-$(get_env SOURCE_PG_DB)}
PGUSER=${PGUSER:-$(get_env SOURCE_PG_USER)}
PGPASSWORD=${PGPASSWORD:-$(get_env SOURCE_PG_PASSWORD)}
PGSSLMODE=${PGSSLMODE:-$(get_env SOURCE_PG_SSLMODE)}
: "${PGHOST:?set PGHOST or SOURCE_PG_HOST in $ENV_FILE}"
: "${PGPASSWORD:?set PGPASSWORD or SOURCE_PG_PASSWORD in $ENV_FILE}"
export PGPASSWORD

q() {
  docker run --rm -e PGPASSWORD "$PSQL_IMAGE" \
    psql "host=$PGHOST port=${PGPORT:-5432} dbname=${PGDATABASE:-open_lmis} user=${PGUSER:-postgres} sslmode=${PGSSLMODE:-require}" \
    -At -v ON_ERROR_STOP=0 "$@" </dev/null 2>&1
}
log() { echo "[$(date -u +%FT%TZ)] $*" >&2; }

mkdir -p "$OUT"
docker pull -q "$PSQL_IMAGE" >/dev/null || { echo "cannot pull $PSQL_IMAGE" >&2; exit 1; }
[ "$(q -c 'select 1')" = 1 ] || { log "cannot connect to ${PGUSER:-postgres}@$PGHOST/${PGDATABASE:-open_lmis}: $(q -c 'select 1' | head -1)"; exit 1; }
log "baseline $LABEL of ${PGUSER:-postgres}@$PGHOST/${PGDATABASE:-open_lmis} -> $OUT"

log "version, size, settings"
q -c "select version()" > "$OUT/version.txt"
q -c "select pg_size_pretty(pg_database_size(current_database()))" > "$OUT/size.txt"
q -c "select name, setting from pg_settings where name in ('server_version','wal_level','max_replication_slots','max_wal_senders','max_slot_wal_keep_size','wal_sender_timeout','max_connections','password_encryption','rds.force_ssl','rds.logical_replication','rds.rds_reserved_connections','shared_buffers','work_mem','effective_cache_size','random_page_cost') order by 1" > "$OUT/settings.txt"

log "extensions, collation"
q -c "select name, installed_version, default_version from pg_available_extensions where installed_version is not null order by 1" > "$OUT/extensions.txt"
# datcollversion exists since PG 15; to_jsonb keeps the query valid on 14 (null there)
q -c "select datcollate, datctype, to_jsonb(d)->>'datcollversion', (select pg_collation_actual_version(oid) from pg_collation where collname in ('en_US.utf8','en_US') order by collname limit 1) from pg_database d where datname = current_database()" > "$OUT/collation.txt"

log "schema objects, columns, sequences, roles"
q -c "select n.nspname, (select count(*) from pg_indexes i where i.schemaname = n.nspname) indexes, (select count(*) from pg_constraint c where c.connamespace = n.oid and c.contype = 'p') pk, (select count(*) from pg_constraint c where c.connamespace = n.oid and c.contype = 'f') fk, (select count(*) from pg_constraint c where c.connamespace = n.oid and c.contype = 'u') uq, (select count(*) from pg_constraint c where c.connamespace = n.oid and c.contype = 'c') ck, (select count(*) from pg_proc p where p.pronamespace = n.oid) funcs, (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid where c.relnamespace = n.oid and not t.tgisinternal) triggers from pg_namespace n where n.nspname not in ('pg_catalog','information_schema','pg_toast') and n.nspname not like 'pg_temp_%' and n.nspname not like 'pg_toast_temp_%' order by 1" > "$OUT/schema_objects.txt"
q -c "select table_schema, table_name, column_name, data_type, is_nullable, character_maximum_length, numeric_precision from information_schema.columns where table_schema not in ('information_schema','pg_catalog') order by 1,2,ordinal_position" > "$OUT/columns.txt"
q -c "select schemaname, sequencename, last_value from pg_sequences order by 1,2" > "$OUT/sequences.txt"
q -c "select rolname, rolcanlogin, rolreplication, rolsuper from pg_roles where rolname not like 'pg_%' and rolname not like 'rds%' order by 1" > "$OUT/roles.txt"

log "CDC: publication, slots"
q -c "select p.pubname, p.puballtables, t.schemaname||'.'||t.tablename from pg_publication p left join pg_publication_tables t on t.pubname = p.pubname order by 1,3" > "$OUT/publication.txt"
q -c "select slot_name, plugin, slot_type, active, wal_status from pg_replication_slots order by 1" > "$OUT/slots.txt"

log "flyway history per schema, large objects, planner stats"
q -c "select table_schema||'.'||table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*)||''|''||max(installed_rank)||''|''||count(*) filter (where not success) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_name in ('schema_version','flyway_schema_history') order by 1" > "$OUT/flyway.txt"
q -c "select count(*) from pg_largeobject_metadata" > "$OUT/lob.txt"
q -c "select 'tables_with_stats', count(distinct schemaname||'.'||tablename) from pg_stats where schemaname not in ('pg_catalog','information_schema') union all select 'tables_never_analyzed', count(*) from pg_stat_user_tables where last_analyze is null and last_autoanalyze is null union all select 'invalid_indexes', count(*) from pg_index where not indisvalid" > "$OUT/stats.txt"

log "row counts of every table (reads the whole database, warms the volume)"
q -c "select table_schema||'.'||table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_schema not in ('information_schema','pg_catalog') and table_type = 'BASE TABLE' order by 1" > "$OUT/rowcounts.txt"

log "content checksums of $(echo "$CHECKSUM_TABLES" | wc -w) business tables"
: > "$OUT/table_checksums.txt"
for t in $CHECKSUM_TABLES; do
  echo "$t|$(q -c "select count(*)||'|'||coalesce(md5(string_agg(h, '' order by h)), 'empty') from (select md5(x::text) h from $t x) s")" >> "$OUT/table_checksums.txt"
done

log "done: $(ls "$OUT" | wc -l) files in $OUT"
