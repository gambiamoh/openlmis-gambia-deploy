#!/usr/bin/env sh
export PREFIX="$(date +"%m-%d-%y")_backup"

docker exec uat_db_1 pg_dump -U postgres open_lmis > "$PREFIX".sql