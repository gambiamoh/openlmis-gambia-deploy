#!/usr/bin/env bash

export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="tcp://uat.elmis.report.apps.moh.gm:2376"
export DOCKER_CERT_PATH="${PWD}/credentials"

docker-compose down -v --remove-orphans
docker-compose build --no-cache
docker-compose up -d
