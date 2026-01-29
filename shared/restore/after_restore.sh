#!/usr/bin/env bash
set -e

: ${DB_HOST:?"Need to set DB_HOST"}
: ${DB_PORT:?"Need to set DB_PORT"}
: ${DB_NAME:?"Need to set DB_NAME"}
: ${POSTGRES_USER:?"Need to set POSTGRES_USER"}
: ${POSTGRES_PASSWORD:?"Need to set POSTGRES_PASSWORD"}
: ${ENCODED_USER_PASSWORD:?"Need to set ENCODED_USER_PASSWORD"}
: ${SUPERSET_SECRET:?"Need to set SUPERSET_SECRET"}
: ${CLIENT_REDIRECT_URI:?"Need to set CLIENT_REDIRECT_URI"}

: ${DASHBOARD_URL_PATTERN:?"Need to set DASHBOARD_URL_PATTERN"}
: ${REPLACE_FROM:?"Need to set REPLACE_FROM"}
: ${REPLACE_TO:?"Need to set REPLACE_TO"}

sql=$(cat <<EOF
UPDATE auth.auth_users SET password = '${ENCODED_USER_PASSWORD}';
UPDATE notification.user_contact_details SET email = NULL, phonenumber = NULL, allownotify = false;
UPDATE auth.oauth_client_details SET redirecturi = '${CLIENT_REDIRECT_URI}' WHERE clientid = 'superset';
UPDATE report.dashboard_reports SET url = replace(url, '${REPLACE_FROM}', '${REPLACE_TO}') WHERE url LIKE '${DASHBOARD_URL_PATTERN}';
EOF
)

echo "Connecting to Host: ${DB_HOST}, Port: ${DB_PORT}, DB: ${DB_NAME} as ${POSTGRES_USER}"
echo "Executing clearing sensitive data..."

PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -d "${DB_NAME}" \
    -U "${POSTGRES_USER}" \
    -c "$sql"

echo "Success: Sensitive data cleared."