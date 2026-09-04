#!/usr/bin/env bash
# =============================================================================
# 03-setup-db.sh
#
# Prepara el PostgreSQL del HOST (NO se toca Docker aquí) para que el
# contenedor Odoo pueda conectarse:
#
#   1. Crea el rol "odoo" con CREATEDB (contraseña auto-generada).
#      IMPORTANTE: NO crea la base de datos "turingtech_crm". Esa base la
#      crea Odoo mismo desde su instalador web en el primer arranque
#      (ver README paso 4) — si la creamos aquí de antemano, Odoo se
#      encuentra una base "vacía" (sin sus tablas) y falla con
#      "database already exists".
#   2. Añade a pg_hba.conf una regla que permite al rol "odoo" autenticarse
#      contra CUALQUIER base ("all", no solo turingtech_crm) desde la subred
#      del bridge de Docker (172.17.0.0/16) — necesario porque, para poder
#      CREAR turingtech_crm, Odoo primero debe conectarse a la base
#      "postgres", que existe de antemano.
#   3. Ajusta postgresql.conf (listen_addresses) para que Postgres escuche
#      también en la IP del gateway del bridge docker0 (por defecto
#      172.17.0.1), no solo en 127.0.0.1. Esa interfaz NO es alcanzable desde
#      internet (solo desde el host y sus contenedores), así que esto no
#      expone Postgres públicamente.
#
# Uso:
#   sudo bash scripts/03-setup-db.sh
# =============================================================================
set -euo pipefail

DB_ROLE="odoo"
DOCKER_SUBNET="172.17.0.0/16"
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
ENV_EXAMPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env.example"

if [[ $EUID -ne 0 ]]; then
    echo "Este script debe ejecutarse como root (usa: sudo bash $0)" >&2
    exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "psql no encontrado. Este script asume que PostgreSQL ya está instalado y corriendo en el host." >&2
    exit 1
fi

# --- 1. Rol "odoo" -----------------------------------------------------------
echo "==> Verificando si el rol '${DB_ROLE}' ya existe..."
ROLE_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_ROLE}'")

if [[ "${ROLE_EXISTS}" == "1" ]]; then
    echo "    El rol '${DB_ROLE}' ya existe. No se modifica su contraseña (para no romper un despliegue existente)."
    echo "    Si necesitas rotar la contraseña manualmente:"
    echo "      sudo -u postgres psql -c \"ALTER ROLE ${DB_ROLE} WITH PASSWORD 'nueva_password';\""
    DB_PASSWORD=""
else
    echo "==> Creando rol '${DB_ROLE}' con CREATEDB..."
    DB_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
    sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE ${DB_ROLE} WITH LOGIN PASSWORD '${DB_PASSWORD}' CREATEDB;
SQL
    echo "    Rol '${DB_ROLE}' creado."
fi

# --- 2. pg_hba.conf ------------------------------------------------------------
PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file;")
PG_CONF=$(sudo -u postgres psql -tAc "SHOW config_file;")
echo "==> pg_hba.conf detectado en: ${PG_HBA}"
echo "==> postgresql.conf detectado en: ${PG_CONF}"

HBA_RULE="host    all    ${DB_ROLE}    ${DOCKER_SUBNET}    scram-sha-256"
if grep -qF "${DB_ROLE}    ${DOCKER_SUBNET}" "${PG_HBA}" 2>/dev/null; then
    echo "==> pg_hba.conf ya tiene una regla para '${DB_ROLE}' desde ${DOCKER_SUBNET}. No se duplica."
else
    echo "==> Añadiendo regla a pg_hba.conf (con backup previo)..."
    cp "${PG_HBA}" "${PG_HBA}.bak.$(date +%Y%m%d%H%M%S)"
    {
        echo ""
        echo "# Añadido por 03-setup-db.sh (proyecto TuringtechOdoo): permite al"
        echo "# contenedor Odoo (bridge de Docker) autenticarse como '${DB_ROLE}'."
        echo "${HBA_RULE}"
    } >> "${PG_HBA}"
    echo "    Regla añadida: ${HBA_RULE}"
fi

# --- 3. postgresql.conf: listen_addresses --------------------------------------
GATEWAY_IP=$(ip -4 addr show docker0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' || true)
if [[ -z "${GATEWAY_IP}" ]]; then
    echo "==> Aviso: no se detectó la interfaz 'docker0' (¿ya instalaste Docker con 02-install-docker.sh?)."
    echo "    Se usará el valor por defecto 172.17.0.1. Verifica con 'ip addr show docker0' tras instalar Docker."
    GATEWAY_IP="172.17.0.1"
fi
echo "==> IP del gateway del bridge de Docker: ${GATEWAY_IP}"

if grep -qE "^\s*listen_addresses\s*=.*${GATEWAY_IP}" "${PG_CONF}" 2>/dev/null; then
    echo "==> postgresql.conf ya escucha en ${GATEWAY_IP}. No se modifica."
else
    echo "==> Ajustando listen_addresses en postgresql.conf (con backup previo)..."
    cp "${PG_CONF}" "${PG_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    if grep -qE "^\s*listen_addresses\s*=" "${PG_CONF}"; then
        sed -i -E "s|^\s*listen_addresses\s*=.*|listen_addresses = 'localhost,${GATEWAY_IP}'|" "${PG_CONF}"
    else
        {
            echo ""
            echo "# Añadido por 03-setup-db.sh (proyecto TuringtechOdoo)"
            echo "listen_addresses = 'localhost,${GATEWAY_IP}'"
        } >> "${PG_CONF}"
    fi
    echo "    listen_addresses = 'localhost,${GATEWAY_IP}'"
fi

echo "==> Reiniciando PostgreSQL para aplicar listen_addresses..."
systemctl restart postgresql

echo
echo "==> Recordatorio de firewall: verifica que ufw NO tenga una regla abriendo"
echo "    el puerto 5432 a 0.0.0.0/0 (la interfaz docker0 no es alcanzable desde"
echo "    internet, así que normalmente no hace falta ninguna regla adicional):"
echo "      sudo ufw status"

if [[ -n "${DB_PASSWORD}" ]]; then
    echo
    echo "================================================================"
    echo " Credenciales generadas (guárdalas ahora, no se volverán a mostrar):"
    echo "   HOST=host.docker.internal"
    echo "   PORT=5432"
    echo "   USER=${DB_ROLE}"
    echo "   PASSWORD=${DB_PASSWORD}"
    echo "================================================================"

    if [[ ! -f "${ENV_FILE}" && -f "${ENV_EXAMPLE}" ]]; then
        echo "==> No existe .env todavía: generando uno a partir de .env.example..."
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
        sed -i "s|^PASSWORD=.*|PASSWORD=${DB_PASSWORD}|" "${ENV_FILE}"
        chmod 600 "${ENV_FILE}"
        echo "    .env creado y completado con la contraseña generada."
    else
        echo "==> Ya existe un .env (o falta .env.example): actualiza PASSWORD=... manualmente con el valor de arriba."
    fi
fi

echo
echo "Listo. Rol '${DB_ROLE}' preparado. La base de datos se crea desde el instalador web de Odoo (README paso 4)."
