#!/usr/bin/env bash
set -e

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &> /dev/null && pwd)
TARGET_ENV="${1:-}"

if [ -z "$BASE_DIR" ]; then
  echo "Error: Could not determine BASE_DIR"
  exit 1
fi

if [[ -z "$TARGET_ENV" ]]; then
  echo "Error: Could not determine TARGET_ENV."
  exit 1
fi

ENV_PATH="$BASE_DIR/$TARGET_ENV"

if [ "$KEEP_OR_RESTORE" == "restore" ]; then
  echo "Restoring database from the latest snapshot..."

  cd "$BASE_DIR/shared/restore"
  docker compose down -v
  docker compose pull
  docker compose run --rm rds-restore

  echo "Pulling latest images and starting services..."
else
  echo "Restarting services"
fi

echo "Navigating to: $ENV_PATH"
cd "$ENV_PATH"

docker compose pull
docker compose up --force-recreate -d

echo "Successfully deployed to $TARGET_ENV."
