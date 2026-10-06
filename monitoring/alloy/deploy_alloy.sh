#!/usr/bin/env bash
# Deploy the Alloy agent to an environment's Docker host over TLS, like
# <env>/deploy_to_env.sh. Certs: <env>/credentials (written by
# shared/init_env_gh.sh from the Jenkins $ca/$cert/$key files). Agent settings:
# the file in $ALLOY_ENV_FILE (Jenkins secret file; master copy
# <env>_env/alloy.env in openlmis-gambia-config).
# Usage: monitoring/alloy/deploy_alloy.sh <uat|prod>
set -euo pipefail

ENV_NAME="${1:?usage: $0 <uat|prod>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
: "${ALLOY_ENV_FILE:?set ALLOY_ENV_FILE to the env's alloy.env}"

# identity, ingest URLs + token, DOCKER_HOST
cp "${ALLOY_ENV_FILE}" "${HERE}/.env"
trap 'rm -f "${HERE}/.env"' EXIT
set -a; . "${HERE}/.env"; set +a

export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH="${DOCKER_CERT_PATH:-${ROOT}/${ENV_NAME}/credentials}"

cd "${HERE}"
# Classic builder: BuildKit on older daemons drops the base image's
# ENTRYPOINT from FROM+COPY images.
DOCKER_BUILDKIT=0 docker build --build-arg "ALLOY_VERSION=${ALLOY_VERSION}" \
  -t "soldevelo-monitoring-alloy:${ALLOY_VERSION}" .
docker compose up -d
docker compose ps
