#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="tcp://uat.elmis.apps.moh.gm:2376"
export DOCKER_CERT_PATH="${SCRIPT_DIR}/credentials"

$SCRIPT_DIR/../shared/restart_or_restore.sh "uat"
