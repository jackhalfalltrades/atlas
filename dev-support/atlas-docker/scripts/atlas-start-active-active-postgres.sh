#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/docker-compose.atlas-active-active.yml" ]]; then
  ROOT_DIR="${SCRIPT_DIR}"
elif [[ -f "${SCRIPT_DIR}/../docker-compose.atlas-active-active.yml" ]]; then
  ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  echo "[ERROR] Could not locate docker-compose.atlas-active-active.yml from ${SCRIPT_DIR}" >&2
  exit 1
fi
cd "${ROOT_DIR}"

COMPOSE_FILE="docker-compose.atlas-active-active.yml"
ENV_BASE=".env"
ENV_AA=".env.active-active"
SCHEMA_SQL="../../graphdb/janusgraph-rdbms/src/main/resources/META-INF/postgres/create_schema.sql"

if [[ ! -f "${ENV_BASE}" || ! -f "${ENV_AA}" ]]; then
  echo "[ERROR] Missing ${ENV_BASE} or ${ENV_AA} in ${ROOT_DIR}" >&2
  exit 1
fi

if [[ ! -f "${SCHEMA_SQL}" ]]; then
  echo "[ERROR] Missing Atlas Postgres schema file: ${SCHEMA_SQL}" >&2
  exit 1
fi

if ! docker image inspect atlas-base:latest >/dev/null 2>&1; then
  echo "[0/8] atlas-base:latest not found. Building base image..."
  export DOCKER_BUILDKIT=1
  export COMPOSE_DOCKER_CLI_BUILD=1
  docker compose --env-file "${ENV_BASE}" -f docker-compose.atlas-base.yml build atlas-base
fi

echo "[1/8] Switching backend to Postgres in ${ENV_AA}..."
if grep -q '^ATLAS_BACKEND=' "${ENV_AA}"; then
  sed -i '' 's/^ATLAS_BACKEND=.*/ATLAS_BACKEND=postgres/' "${ENV_AA}"
else
  printf "\nATLAS_BACKEND=postgres\n" >> "${ENV_AA}"
fi

echo "[2/8] Starting infrastructure..."
docker compose --env-file "${ENV_BASE}" --env-file "${ENV_AA}" \
  -f "${COMPOSE_FILE}" up -d \
  atlas-hadoop atlas-zk atlas-kafka atlas-solr atlas-backend atlas-db

echo "[3/8] Initializing Postgres users/databases/schema..."
docker run --rm --network atlasnw \
  -e POSTGRES_HOST=atlas-db \
  -e POSTGRES_PORT=5432 \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_PASSWORD=atlasR0cks! \
  -e HIVE_DB_PASSWORD=atlasR0cks! \
  -e ATLAS_DB_PASSWORD=atlasR0cks! \
  -e ATLAS_SCHEMA_FILE=/tmp/create_schema.sql \
  -v "${ROOT_DIR}/config/init_postgres.sh:/tmp/init_postgres.sh:ro" \
  -v "${ROOT_DIR}/${SCHEMA_SQL}:/tmp/create_schema.sql:ro" \
  postgres:13.21 /bin/bash /tmp/init_postgres.sh

echo "[4/8] Running initializer..."
docker compose --env-file "${ENV_BASE}" --env-file "${ENV_AA}" \
  -f "${COMPOSE_FILE}" up -d --force-recreate atlas-initializer

echo "[5/8] Starting active-active Atlas services..."
docker compose --env-file "${ENV_BASE}" --env-file "${ENV_AA}" \
  -f "${COMPOSE_FILE}" up -d --force-recreate \
  --scale atlas-metadata-server=2 --scale atlas-notification-proc=2 \
  atlas-metadata-server atlas-notification-proc atlas-lb

echo "[6/8] Service status:"
docker compose -f "${COMPOSE_FILE}" ps

echo "[7/8] Atlas admin status via LB:"
wget -q -S -O- http://localhost:21000/api/atlas/admin/status 2>&1 | tail -20 || true

echo
echo "[DONE] Active-active Atlas started in Postgres mode."
