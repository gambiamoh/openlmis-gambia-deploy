#!/usr/bin/env bash

WIPE_MSG="Will WIPE data!"
KEEP_MSG="Will keep data."

docker-compose kill
docker-compose down

export KEEP_OR_WIPE="keep"
if [ "$KEEP_OR_WIPE" == "wipe" ]; then
  echo "$WIPE_MSG"
  unset spring_profiles_active
  docker-compose up --build --force-recreate -d
else
  echo "$KEEP_MSG";
  export spring_profiles_active="production"
  docker-compose up --build --force-recreate -d
fi