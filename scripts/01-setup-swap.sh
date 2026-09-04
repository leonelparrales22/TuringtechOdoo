#!/usr/bin/env bash
# =============================================================================
# 01-setup-swap.sh
#
# Crea (si no existe) un swapfile de 2GB y fija vm.swappiness=10.
#
# El Droplet tiene 1 vCPU / 1GB RAM y ya corre Node.js + Nginx + Postgres en
# el host; sumarle Odoo en Docker deja la máquina muy justa de memoria. Este
# swap NO sustituye a la RAM real (sigue siendo mucho más lento), pero actúa
# como red de seguridad contra un OOM-kill si hay un pico de memoria puntual.
#
# Uso:
#   sudo bash scripts/01-setup-swap.sh
# =============================================================================
set -euo pipefail

SWAP_FILE="/swapfile"
SWAP_SIZE="2G"
SYSCTL_FILE="/etc/sysctl.d/99-swap.conf"

if [[ $EUID -ne 0 ]]; then
    echo "Este script debe ejecutarse como root (usa: sudo bash $0)" >&2
    exit 1
fi

echo "==> Verificando swap existente..."
if swapon --show=NAME --noheadings | grep -qx "${SWAP_FILE}"; then
    echo "    ${SWAP_FILE} ya está activo como swap. Nada que hacer."
else
    if [[ -f "${SWAP_FILE}" ]]; then
        echo "    ${SWAP_FILE} ya existe en disco pero no está activo. Activando..."
        chmod 600 "${SWAP_FILE}"
        swapon "${SWAP_FILE}"
    else
        echo "==> Creando swapfile de ${SWAP_SIZE} en ${SWAP_FILE}..."
        # fallocate es rápido; si el filesystem no lo soporta (algunos casos con
        # btrfs/overlay), se cae a dd como respaldo.
        if ! fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}" 2>/dev/null; then
            echo "    fallocate no disponible, usando dd (más lento)..."
            dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=2048 status=progress
        fi
        chmod 600 "${SWAP_FILE}"
        mkswap "${SWAP_FILE}"
        swapon "${SWAP_FILE}"
    fi
fi

echo "==> Persistiendo en /etc/fstab..."
if grep -qE "^\s*${SWAP_FILE}\s" /etc/fstab; then
    echo "    Ya existe una entrada para ${SWAP_FILE} en /etc/fstab."
else
    echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
    echo "    Entrada añadida a /etc/fstab."
fi

echo "==> Fijando vm.swappiness=10 (persistente)..."
cat > "${SYSCTL_FILE}" <<'EOF'
# Con solo 1GB de RAM real, mantenemos swappiness bajo: preferimos usar RAM
# hasta el último momento y recurrir al swap (mucho más lento) solo cuando
# sea estrictamente necesario.
vm.swappiness=10
EOF
sysctl --system >/dev/null

echo "==> Estado final:"
free -h
swapon --show

echo
echo "Listo. Swap de ${SWAP_SIZE} activo y persistente, vm.swappiness=10."
