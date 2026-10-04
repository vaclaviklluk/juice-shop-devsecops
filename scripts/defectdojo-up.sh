#!/usr/bin/env bash
# Starts the throwaway DefectDojo (defectdojo/docker-compose.yml) on 127.0.0.1:${DD_PORT:-8080}
# with credentials generated for this run, and waits until it serves the API.
# The admin password is written to $DD_ENV_FILE (mode 600) for the later steps.
set -euo pipefail
compose_file=$(dirname "$(realpath "$0")")/../defectdojo/docker-compose.yml
env_file=${DD_ENV_FILE:-${RUNNER_TEMP:-/tmp}/defectdojo.env}
url=http://127.0.0.1:${DD_PORT:-8080}

DD_ADMIN_PASSWORD=$(openssl rand -hex 24)
DD_SECRET_KEY=$(openssl rand -hex 32)
DD_CREDENTIAL_AES_256_KEY=$(openssl rand -hex 16)
DD_DATABASE_PASSWORD=$(openssl rand -hex 24)
export DD_ADMIN_PASSWORD DD_SECRET_KEY DD_CREDENTIAL_AES_256_KEY DD_DATABASE_PASSWORD
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  for value in "$DD_ADMIN_PASSWORD" "$DD_SECRET_KEY" "$DD_CREDENTIAL_AES_256_KEY" "$DD_DATABASE_PASSWORD"; do
    echo "::add-mask::$value"
  done
fi
(umask 077 && printf 'DD_ADMIN_PASSWORD=%s\n' "$DD_ADMIN_PASSWORD" > "$env_file")

docker compose -f "$compose_file" up -d --quiet-pull

# uwsgi starts only after the initializer has run the migrations and created the
# admin user, so a served login page means the API is ready too.
for _ in $(seq 1 120); do
  if curl -fsS -o /dev/null "$url/login" 2>/dev/null; then
    echo "DefectDojo is up"
    exit 0
  fi
  sleep 5
done
echo "DefectDojo did not become ready in 10 minutes" >&2
docker compose -f "$compose_file" ps >&2
docker compose -f "$compose_file" logs --tail 50 initializer uwsgi >&2
exit 1
