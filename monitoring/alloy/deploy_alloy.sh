#!/usr/bin/env bash
# Deploy the Alloy agent to an environment's Docker host over TLS, like
# <env>/deploy_to_env.sh. Run from the Jenkins workspace root with
# openlmis-gambia-config checked out in deployment-config/; reads
# <env>_env/alloy.env (identity, ingest token, DOCKER_HOST) and
# <env>_env/credentials from it.
# Usage: monitoring/alloy/deploy_alloy.sh <uat|prod>
set -euo pipefail

ENV_NAME="${1:?usage: $0 <uat|prod>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(pwd)/deployment-config}/${ENV_NAME}_env"

cp "${CONFIG_DIR}/alloy.env" "${HERE}/.env"
trap 'rm -f "${HERE}/.env"' EXIT
set -a; . "${HERE}/.env"; set +a

export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH="${CONFIG_DIR}/credentials"

cd "${HERE}"
# Classic builder: BuildKit on older daemons drops the base image's
# ENTRYPOINT from FROM+COPY images.
DOCKER_BUILDKIT=0 docker build --build-arg "ALLOY_VERSION=${ALLOY_VERSION}" \
  -t "soldevelo-monitoring-alloy:${ALLOY_VERSION}" .
docker compose up -d
docker compose ps
