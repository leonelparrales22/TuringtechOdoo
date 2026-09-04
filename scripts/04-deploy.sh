#!/usr/bin/env bash
# =============================================================================
# 04-deploy.sh
#
# Valida .env y levanta el contenedor de Odoo.
#
# Uso:
#   bash scripts/04-deploy.sh
# (No requiere sudo si tu usuario ya está en el grupo "docker" — ver
#  02-install-docker.sh. Si no, ejecuta con sudo.)
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
REQUIRED_VARS=(HOST PORT USER PASSWORD)

cd "${PROJECT_DIR}"

echo "==> Verificando .env..."
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "No existe ${ENV_FILE}. Copia .env.example a .env y complétalo (o corre primero scripts/03-setup-db.sh)." >&2
    exit 1
fi

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

missing=0
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" || "${!var:-}" == "changeme" ]]; then
        echo "    Falta o no está configurada la variable: ${var}" >&2
        missing=1
    fi
done
if [[ "${missing}" -eq 1 ]]; then
    echo "Completa las variables faltantes en ${ENV_FILE} antes de desplegar." >&2
    exit 1
fi
echo "    .env OK (HOST=${HOST}, PORT=${PORT}, USER=${USER})"

echo "==> Validando docker-compose.yml..."
docker compose config >/dev/null

echo "==> Descargando imagen odoo:17.0..."
docker compose pull

echo "==> Levantando el contenedor..."
docker compose up -d

echo "==> Esperando a que Odoo responda en 127.0.0.1:8069..."
ATTEMPTS=30
until curl -sf -o /dev/null "http://127.0.0.1:8069/web/login"; do
    ATTEMPTS=$((ATTEMPTS - 1))
    if [[ "${ATTEMPTS}" -le 0 ]]; then
        echo "Odoo no respondió a tiempo. Revisa los logs con: docker compose logs -f odoo" >&2
        exit 1
    fi
    sleep 2
done

echo
echo "Odoo está arriba y respondiendo en http://127.0.0.1:8069/web/login"
echo "Siguientes pasos (ver README):"
echo "  1. Entra por túnel SSH o Nginx y crea la base 'turingtech_crm' desde el instalador web."
echo "  2. Endurece config/odoo/odoo.conf (list_db=False, db_name=turingtech_crm) y 'docker compose restart odoo'."
echo "  3. Publica el vhost de Nginx (config/nginx/crm.turingtech.com.ec.conf)."
