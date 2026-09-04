#!/usr/bin/env bash
# =============================================================================
# 02-install-docker.sh
#
# Instalación oficial y limpia de Docker Engine + Compose plugin en Ubuntu,
# siguiendo el método documentado por Docker (repositorio APT propio con
# clave GPG), NO el script de conveniencia get.docker.com (curl|bash).
#
# Uso:
#   sudo bash scripts/02-install-docker.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Este script debe ejecutarse como root (usa: sudo bash $0)" >&2
    exit 1
fi

if command -v docker >/dev/null 2>&1; then
    echo "==> Docker ya está instalado ($(docker --version)). Nada que hacer."
    exit 0
fi

echo "==> Desinstalando paquetes conflictivos antiguos (si existen)..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done

echo "==> Instalando dependencias..."
apt-get update
apt-get install -y ca-certificates curl gnupg

echo "==> Añadiendo la clave GPG oficial de Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "==> Añadiendo el repositorio APT oficial de Docker..."
. /etc/os-release
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

echo "==> Instalando Docker Engine + Compose plugin..."
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Habilitando e iniciando el servicio Docker..."
systemctl enable --now docker

# Añade al grupo "docker" al usuario que invocó sudo (si aplica), para poder
# correr `docker`/`docker compose` sin sudo. Requiere cerrar sesión y volver a
# entrar (o `newgrp docker`) para que surta efecto.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "==> Añadiendo '${SUDO_USER}' al grupo docker..."
    usermod -aG docker "${SUDO_USER}"
    echo "    Cierra sesión y vuelve a entrar (o ejecuta 'newgrp docker') para que aplique."
fi

echo "==> Verificando instalación..."
docker --version
docker compose version

echo
echo "Docker instalado correctamente."
