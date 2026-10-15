#!/usr/bin/env bash
# Launcher con guarda para los MCP de Postgres del plugin.
#
# Uso (desde .mcp.json):
#   postgres-mcp-launcher.sh PROD|DEV "${DATABASE_URL_PROD}" "${DATABASE_SSH_JUMP_PROD:-}"
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
#
# Máquina de salto (opcional, $3): si DATABASE_SSH_JUMP_{PROD|DEV} trae un destino SSH
# (un alias de ~/.ssh/config o usuario@host), la BD no se alcanza directamente: se abre
# `ssh -L` a través de esa máquina hasta el host:puerto de la URL y postgres-mcp conecta
# por el túnel. Llega por las mismas dos vías que la URL. La URL se define igual que sin
# salto, con el host real del server: aquí solo cambia el puerto por el local del túnel y
# se añade hostaddr=127.0.0.1. libpq conecta a hostaddr pero valida el certificado (y manda
# el SNI) con host, así que sslmode=verify-full sigue valiendo; y el nombre del server, que
# puede ser privado, lo resuelve la máquina de salto, no este equipo.

set -euo pipefail

# shellcheck source=lib/pg-url.sh
. "$(dirname "$0")/lib/pg-url.sh"

tier="${1:?uso: postgres-mcp-launcher.sh PROD|DEV <url> [destino-ssh-de-salto]}"
url="${2:-}"
salto="${3:-}"
var="DATABASE_URL_${tier}"
var_salto="DATABASE_SSH_JUMP_${tier}"

# Argumento vacío o literal sin expandir → prueba el entorno del proceso.
case "$url" in
  ''|*'${'*) url="${!var:-}" ;;
esac
case "$salto" in
  ''|*'${'*) salto="${!var_salto:-}" ;;
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

no_soportada() {
  cat >&2 <<EOF
[taller] postgres-${tier}: con ${var_salto} la URL tiene que ser de la forma
  postgresql://[usuario[:clave]@]host[:puerto][/bd][?parámetros]
con un solo host y sin host/hostaddr/port en los parámetros ($1).
EOF
  exit 1
}

# Hay algo escuchando en 127.0.0.1:$1. /dev/tcp es de bash (también el 3.2 de macOS).
puerto_ocupado() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

abrir_tunel() {
  pg_url_partes "$url" || no_soportada "$PG_MOTIVO"
  local esquema=$PG_ESQUEMA usuario=$PG_USUARIO host=$PG_HOST puerto=$PG_PUERTO resto=$PG_RESTO

  local dir=${TMPDIR:-/tmp}
  local ctl="${dir%/}/taller-pg-${tier}-$$.sock" err="${dir%/}/taller-pg-${tier}-$$.err"
  local intento local_port rc
  for intento in 1 2 3 4 5; do
    local_port=$((20000 + RANDOM % 40000))
    puerto_ocupado "$local_port" && continue
    # -f vuelve en cuanto el reenvío local está escuchando (o sale con error): con
    # ExitOnForwardFailure, un puerto ocupado es un fallo y no un túnel a medias.
    # BatchMode: el MCP no tiene terminal, así que una passphrase o un 2FA colgarían el
    # arranque; mejor fallar con un mensaje. El master de control sirve para cerrarlo.
    rc=0
    ssh -f -N \
      -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=15 \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -o ControlMaster=yes -o ControlPath="$ctl" \
      -L "127.0.0.1:${local_port}:${host}:${puerto}" "$salto" \
      </dev/null >/dev/null 2>"$err" || rc=$?
    if [[ $rc -eq 0 ]]; then
      rm -f "$err"
      # Cierra el túnel cuando acabe este proceso, que con el exec de abajo pasa a ser
      # postgres-mcp: así no quedan túneles huérfanos al cerrar la sesión. Sin heredar
      # stdout, que es el canal del protocolo MCP.
      (
        while kill -0 "$$" 2>/dev/null; do sleep 2; done
        ssh -S "$ctl" -O exit "$salto"
      ) </dev/null >/dev/null 2>&1 &
      local parametro=hostaddr=127.0.0.1
      case "$resto" in
        *'?'*) resto="${resto}&${parametro}" ;;
        *) resto="${resto}?${parametro}" ;;
      esac
      url="${esquema}${usuario}${host}:${local_port}${resto}"
      echo "[taller] postgres-${tier}: túnel por ${salto} hasta ${host}:${puerto} (local 127.0.0.1:${local_port})" >&2
      return 0
    fi
    # Puerto cogido entre la comprobación y el bind: otro intento con otro puerto.
    grep -qiE 'address already in use|cannot listen|could not request local forwarding' "$err" 2>/dev/null && continue
    break
  done

  cat >&2 <<EOF
[taller] postgres-${tier}: no se pudo abrir el túnel por ${salto} (ssh salió con ${rc}).
$(tail -n 3 "$err" 2>/dev/null)

Comprueba que entra sin preguntar nada:  ssh -o BatchMode=yes ${salto} true
El MCP no tiene terminal: la clave tiene que estar en el agente (ssh-add), sin passphrase
ni 2FA. ${var_salto} admite un alias de ~/.ssh/config o usuario@host.
EOF
  rm -f "$err"
  exit 1
}

[[ -n "$salto" ]] && abrir_tunel

# postgres-mcp prefiere DATABASE_URI al argumento: la URL que manda es la del contrato
# (y, con salto, la del túnel), no una variable que el entorno arrastre por casualidad.
unset DATABASE_URI

# Modo comprobación (lo usa scripts/doctor.sh): misma URL y mismo túnel que el MCP, pero en
# vez de arrancar postgres-mcp abre una conexión de verdad e imprime una línea con el rol.
# Así el doctor prueba exactamente el camino que usará el MCP, sin duplicar el túnel.
if [[ "${TALLER_PG_COMPROBAR:-}" == 1 ]]; then
  exec uvx --quiet --with 'psycopg[binary]' python -c '
import sys, psycopg
with psycopg.connect(sys.argv[1], connect_timeout=10) as c:
    rol, su, crea = c.execute(
        "select current_user, rolsuper, has_database_privilege(current_user, current_database(), %s)"
        " from pg_roles where rolname = current_user", ("CREATE",)).fetchone()
    print(f"rol={rol} superusuario={su} crea_en_bd={crea} ssl={c.info.pgconn.ssl_in_use}")
' "$url"
fi

exec uvx --from postgres-mcp --with 'mcp<2' postgres-mcp --access-mode=restricted "$url"
