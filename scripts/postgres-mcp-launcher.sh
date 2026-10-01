#!/usr/bin/env bash
# Launcher con guarda para los MCP de Postgres del plugin.
#
# Uso (desde .mcp.json): postgres-mcp-launcher.sh PROD|DEV "${DATABASE_URL_PROD}"
#
# Comprueba la URL ANTES de arrancar postgres-mcp: si el repo/máquina no define la
# variable, falla al instante con un mensaje accionable (sin spawn de uvx ni intento
# de conexión), en vez del error confuso de conexión que daría postgres-mcp con un
# literal '${...}' sin expandir.
#
# La URL llega por dos vías (cinturón y tirantes):
#   1. Argumento $2, ya expandido por Claude Code desde el env de la sesión
#      (sesiones interactivas: el `env` de settings del repo funciona).
#   2. Si el argumento vino vacío o sin expandir (p. ej. `claude -p` headless, donde
#      el env de settings no llega a la expansión), se lee DATABASE_URL_{PROD|DEV}
#      del entorno del propio proceso.

set -euo pipefail

tier="${1:?uso: postgres-mcp-launcher.sh PROD|DEV <url>}"
url="${2:-}"
var="DATABASE_URL_${tier}"

# Argumento vacío o literal sin expandir → prueba el entorno del proceso.
case "$url" in
  ''|*'${'*) url="${!var:-}" ;;
esac

if [[ -z "$url" || "$url" == *'${'* ]]; then
  cat >&2 <<EOF
[taller] postgres-${tier} no configurado en este repo: falta ${var}.

Defínela en el .claude/ del repo y reinicia la sesión:
  - PROD: settings.local.json (gitignored) -> {"env": {"DATABASE_URL_PROD": "postgresql://<rol-lectura>:...@<fqdn>:5432/<bd>?sslmode=require"}}
  - DEV:  settings.json (versionado)       -> {"env": {"DATABASE_URL_DEV": "postgresql://...@localhost:.../<bd>"}}

Si este repo no tiene esa BD (p. ej. sin entorno dev), ignora este aviso: el server
queda como no disponible y no molesta. Detalle en el README del plugin.
EOF
  exit 1
fi

exec uvx --from postgres-mcp --with 'mcp<2' postgres-mcp --access-mode=restricted "$url"
