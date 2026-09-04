# Odoo 17 en Docker — Droplet ultra-ligero (1 vCPU / 1GB RAM)

Despliegue minimalista de **Odoo 17 Community** en un único contenedor Docker,
diseñado para convivir en el mismo Droplet con un Nginx y un PostgreSQL que
**ya corren en el host** (fuera de Docker) sirviendo otro sitio (Node.js).

## Arquitectura

```
Internet ──HTTPS──▶ Cloudflare (proxy naranja, modo Flexible)
                          │ HTTP (puerto 80)
                          ▼
                 Nginx del HOST (fuera de Docker)
                 ├── sitio Node.js (ya existente, puerto 3000)
                 └── crm.turingtech.com.ec ──▶ 127.0.0.1:8069
                                                    │
                                          ┌─────────▼─────────┐
                                          │  Contenedor Odoo   │
                                          │  (workers=0)       │
                                          └─────────┬─────────┘
                                                    │ host.docker.internal
                                                    ▼
                                 PostgreSQL del HOST (127.0.0.1 + docker0)
```

Ni Postgres ni Nginx viven dentro de Docker — solo Odoo. La comunicación
Odoo → Postgres cruza la frontera del contenedor vía `host.docker.internal`
(mapeado en `docker-compose.yml` al gateway del bridge de Docker).

## Requisitos previos

- Droplet Ubuntu con Nginx y PostgreSQL ya corriendo en el host.
- Acceso `sudo` por SSH.
- El dominio `crm.turingtech.com.ec` ya apuntando (registro A, proxy naranja
  activo) al Droplet en Cloudflare.

## Paso a paso

### 1. Swap (protección de memoria)

```bash
sudo bash scripts/01-setup-swap.sh
```

Crea un swapfile de 2GB persistente y fija `vm.swappiness=10`. Con solo 1GB
de RAM real repartido entre Node, Nginx, Postgres y ahora Odoo, este swap es
una red de seguridad — **no** un sustituto de RAM real (ver nota de riesgo al
final).

### 2. Instalar Docker

```bash
sudo bash scripts/02-install-docker.sh
```

Instala Docker Engine + Compose plugin desde el repositorio APT oficial de
Docker. Si el script te añadió a un grupo `docker`, cierra sesión SSH y
vuelve a entrar (o `newgrp docker`) antes de continuar.

### 3. Preparar PostgreSQL del host

```bash
sudo bash scripts/03-setup-db.sh
```

Este script:
- Crea el rol `odoo` (con `CREATEDB`) y **genera una contraseña fuerte**
  automáticamente (se muestra una sola vez al final — guárdala).
- **No crea la base de datos.** `turingtech_crm` la crea Odoo mismo en el
  paso 4, desde su instalador web — si Postgres la creara antes, vacía, Odoo
  fallaría con "database already exists" al intentar inicializarla.
- Añade la regla necesaria a `pg_hba.conf` (rol `odoo`, cualquier base,
  desde la subred del bridge de Docker `172.17.0.0/16`).
- Ajusta `listen_addresses` en `postgresql.conf` para escuchar también en la
  IP del gateway `docker0` (normalmente `172.17.0.1`).
- Si no existe `.env`, lo genera a partir de `.env.example` con la
  contraseña ya rellenada.

Si ya tenías un `.env`, actualiza `PASSWORD=` manualmente con el valor que
imprimió el script.

### 4. Desplegar el contenedor y crear la base de datos

```bash
bash scripts/04-deploy.sh
```

Valida `.env`, descarga `odoo:17.0` y levanta el contenedor
(`127.0.0.1:8069`, no expuesto públicamente).

Luego, **crea la base de datos desde el instalador web de Odoo** (el rol
`odoo` ya tiene `CREATEDB`, pero la base en sí no existe todavía):

- Vía túnel SSH: `ssh -L 8069:127.0.0.1:8069 usuario@tu-droplet`, y abre
  `http://127.0.0.1:8069` en tu navegador local, o
- Vía el propio Nginx público, una vez completado el paso 6.

En el instalador, usa `turingtech_crm` como nombre de base (o el que hayas
elegido — mantenlo consistente con el paso 5).

### 5. Endurecimiento post-instalación

Con la base ya creada, edita [`config/odoo/odoo.conf`](config/odoo/odoo.conf)
y cambia:

```ini
list_db = False
db_name = turingtech_crm
```

Luego reinicia el contenedor:

```bash
docker compose restart odoo
```

Esto oculta el selector público `/web/database/selector` y fija Odoo a una
única base de datos — importante para no dejar expuesta la creación/borrado
de bases desde internet.

### 6. Publicar el vhost de Nginx

```bash
sudo cp config/nginx/crm.turingtech.com.ec.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/crm.turingtech.com.ec.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

El sitio Node.js existente y su vhost **no se tocan** — este archivo solo
añade un `server{}` nuevo para `crm.turingtech.com.ec`.

El archivo incluye, comentado, un bloque 443 (SSL) completo con dos opciones
(Certbot/Let's Encrypt o Cloudflare Origin CA) por si en el futuro cambias la
zona de Cloudflare a **Full/Strict** — ver los comentarios dentro del propio
archivo. Por defecto solo está activo el puerto 80 (modo Flexible).

### 7. Configuración en Cloudflare

- SSL/TLS → modo **Flexible** (el origen solo sirve HTTP; Cloudflare termina
  el HTTPS de cara al visitante).
- SSL/TLS → Edge Certificates → **Always Use HTTPS**: activado (así el
  visitante siempre llega por HTTPS, y el header `X-Forwarded-Proto: https`
  que fija Nginx hacia Odoo es siempre correcto).
- DNS → el registro de `crm.turingtech.com.ec` con proxy (nube naranja)
  activo, tal como ya lo tienes.

### 8. Verificación

```bash
# Desde el propio droplet:
curl -I http://127.0.0.1:8069/web/login

# Estado de memoria del contenedor:
docker stats odoo --no-stream

# Rol creado en Postgres:
sudo -u postgres psql -c "\du"

# Base creada por Odoo (después del paso 4):
sudo -u postgres psql -c "\l"
```

```bash
# Desde fuera:
curl -I https://crm.turingtech.com.ec/web/login
```

Debe devolver la pantalla de login de Odoo.

## ⚠️ Nota de riesgo: 1GB de RAM es muy justo

Este Droplet corre simultáneamente Node.js, Nginx, PostgreSQL, el daemon de
Docker y ahora Odoo — todo en 1GB de RAM real. La configuración de este
repo (`workers = 0`, límites de memoria conservadores, swap de 2GB) está
pensada para minimizar el footprint, pero:

- El swap es una **red de seguridad**, no una solución de rendimiento: si
  Odoo empieza a usar swap de forma sostenida, notarás lentitud notable.
- Monitorea con `free -h` y `docker stats odoo` tras el despliegue,
  especialmente bajo carga real (varios usuarios, reportes pesados).
- Si ves swapping sostenido o el contenedor golpeando `mem_limit` con
  frecuencia, considera hacer resize del Droplet a 2GB de RAM — es la
  solución de fondo, no hay mucho más margen de optimización posible a 1GB
  con Odoo en el mix.

## Estructura del repositorio

```
docker-compose.yml              # Único servicio: Odoo 17
.env.example                    # Plantilla de credenciales de Postgres
config/
  odoo/odoo.conf                # workers=0, proxy_mode, límites de memoria
  nginx/crm.turingtech.com.ec.conf  # Vhost para copiar al Nginx del host
scripts/
  01-setup-swap.sh               # Swap 2GB + vm.swappiness
  02-install-docker.sh           # Docker Engine + Compose (repo oficial)
  03-setup-db.sh                 # Rol "odoo" + pg_hba.conf + postgresql.conf
  04-deploy.sh                   # Valida .env y levanta el contenedor
addons/                          # Módulos custom de Odoo (vacío por defecto)
```
