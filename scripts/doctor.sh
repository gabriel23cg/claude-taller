#!/usr/bin/env bash
# Comprueba la configuración que el plugin necesita en un repo y en esta máquina: los MCP
# (URLs de Postgres, máquina de salto, uvx, Docker, az) y las herramientas de los hooks
# (jq, gh, uv, terraform). Casi todo eso falla en silencio —un MCP que no arranca solo se ve
# en /plugin → Errors, y un hook sin su herramienta no hace nada—, así que no basta con
# documentarlo: hay que comprobarlo.
#
# Dos modos:
#   doctor.sh [dir]           repaso completo; lo corre la skill /taller:doctor. Incluye red
#                             (SSH a la máquina de salto y conexión real a la BD con el mismo
#                             launcher que usa el MCP) y, para lo que falta, la forma exacta
#                             de ponerlo: qué variable, en qué fichero y con qué formato.
#   doctor.sh --inicio [dir]  lo llama el hook de SessionStart. Sin red y en milisegundos, y
#                             SOLO lo que está configurado pero roto. Lo que falta y puede
#                             faltar a propósito (DATABASE_URL_DEV en un repo sin BD de dev)
#                             no avisa nunca al arrancar: un aviso que salta en cada sesión
#                             sin motivo se acaba ignorando, y con él el que importa.
#                             Calla si no hay nada roto.
#
# Niveles: FALLO (configurado pero roto, o falta una herramienta para algo que el repo usa),
# AVISO (falta algo que este repo probablemente necesita), INFO (opcional) y OK.
#
# Nunca imprime una URL: llevan la clave. Exit 0 siempre: diagnostica, no bloquea.
# Compatible con el bash 3.2 de macOS.

set -uo pipefail

aqui=$(cd "$(dirname "$0")" && pwd)
modo=completo
if [[ "${1:-}" == --inicio ]]; then modo=inicio; shift; fi
cd "${1:-.}" 2>/dev/null || exit 0

# shellcheck source=lib/pg-url.sh
. "$aqui/lib/pg-url.sh"

LOCAL=.claude/settings.local.json
COMPARTIDO=.claude/settings.json
n_fallos=0 n_avisos=0 rotos=''

tiene() { command -v "$1" >/dev/null 2>&1; }
seccion() { [[ $modo == completo ]] && printf '\n== %s\n' "$1"; return 0; }
# informe <nivel> <mensaje> [cómo arreglarlo, puede ser multilínea]
informe() {
  case $1 in
    FALLO) n_fallos=$((n_fallos + 1)); rotos="${rotos:+$rotos; }$2" ;;
    AVISO) n_avisos=$((n_avisos + 1)) ;;
  esac
  [[ $modo == completo ]] || return 0
  printf '%-6s %s\n' "$1" "$2"
  if [[ -n "${3:-}" ]]; then printf '%s\n' "$3" | sed 's/^/       /'; fi
  return 0
}

# Valor de una variable y de dónde sale. Manda el entorno de la sesión, que es lo que ve el
# MCP; si no está ahí, se busca en los settings del repo (definida, pero la sesión no la ve).
de_fichero() { [[ -f "$1" ]] && tiene jq && jq -r --arg v "$2" '.env[$v] // empty' "$1" 2>/dev/null; return 0; }
leer() {
  VAL=${!1:-} ORIGEN=sesión
  [[ -n "$VAL" ]] && return 0
  VAL=$(de_fichero "$LOCAL" "$1") ORIGEN=$LOCAL
  [[ -n "$VAL" ]] && return 0
  VAL=$(de_fichero "$COMPARTIDO" "$1") ORIGEN=$COMPARTIDO
  [[ -n "$VAL" ]] && return 0
  ORIGEN=''
}

plantilla_url() {
  if [[ $1 == PROD ]]; then
    cat <<'EOF'
Añádela en .claude/settings.local.json (no se versiona), dentro de "env":
  "DATABASE_URL_PROD": "postgresql://<rol-lectura>:<clave>@<servidor>:5432/<bd>?sslmode=require"
Con un rol de solo lectura, nunca el admin. Si la BD solo se alcanza por una máquina de salto:
  "DATABASE_SSH_JUMP_PROD": "<alias de ~/.ssh/config>"
Después, reinicia la sesión: el MCP lee las variables al arrancar.
EOF
  else
    cat <<'EOF'
Si el repo tiene BD local de dev, añádela en .claude/settings.json (se versiona: es la
credencial local de compose, no un secreto), dentro de "env":
  "DATABASE_URL_DEV": "postgresql://<usuario>:<clave>@localhost:<puerto>/<bd>"
Si no hay BD de dev, no hace falta. Después, reinicia la sesión.
EOF
  fi
}
plantilla_alias() {
  cat <<EOF
Define el alias en ~/.ssh/config:
  Host $1
    HostName <ip-o-dns-de-la-máquina-de-salto>
    User <usuario>
    IdentityFile ~/.ssh/<clave>
    IdentitiesOnly yes
EOF
}
arreglo_ssh() {
  cat <<EOF
El MCP no tiene terminal: tiene que entrar sin pedir passphrase, 2FA ni confirmar la huella.
  1. Prueba a mano en tu terminal: ssh $1 true  (lo que pregunte es lo que falla)
  2. Carga la clave en el agente: ssh-add ~/.ssh/<clave>
     (macOS: ssh-add --apple-use-keychain ~/.ssh/<clave>, y en ~/.ssh/config, dentro del
     Host: UseKeychain yes y AddKeysToAgent yes, para que sobreviva al reinicio)
  3. Si es la primera vez que entras en esa máquina, acepta su huella en esa prueba a mano.
EOF
}

# --- Señales del repo -----------------------------------------------------------------------
usa_ruff=false; [[ -f pyproject.toml ]] && grep -q '^\[tool\.ruff\]' pyproject.toml && usa_ruff=true
hay_infra=false; [[ -d infra ]] && hay_infra=true
en_github=false; git remote -v 2>/dev/null | grep -q 'github\.com' && en_github=true
usa_pg=false
if [[ -f alembic.ini ]] || { [[ -f pyproject.toml ]] && grep -qiE 'psycopg|asyncpg|sqlalchemy|alembic' pyproject.toml; }; then
  usa_pg=true
fi

# --- Herramientas de los hooks --------------------------------------------------------------
seccion "Herramientas de los hooks"
if tiene jq; then informe OK "jq"
else informe FALLO "falta jq: los hooks del plugin leen su entrada con jq y, sin él, no hacen nada" \
  "macOS: brew install jq · Debian/Ubuntu: sudo apt install jq"; fi
if $en_github; then
  if ! tiene gh; then
    informe FALLO "falta gh: los hooks de issues y PRs no pueden comprobar nada" \
      "macOS: brew install gh · otros: https://cli.github.com · después: gh auth login"
  elif ! gh auth token >/dev/null 2>&1; then
    informe FALLO "gh no tiene sesión: los hooks de issues y PRs no pueden comprobar nada" "gh auth login"
  else informe OK "gh con sesión"; fi
fi
if $usa_ruff; then
  if tiene uv; then informe OK "uv (los hooks de ruff)"
  else informe FALLO "falta uv: el pyproject declara [tool.ruff] y los hooks de ruff lo lanzan con uv run" \
    "macOS: brew install uv · otros: https://docs.astral.sh/uv/getting-started/installation/"; fi
fi
if $hay_infra; then
  if tiene terraform; then informe OK "terraform (fmt de infra/)"
  else informe FALLO "falta terraform: hay infra/ y terraform-fmt-on-stop no hace nada sin él" \
    "macOS: brew install hashicorp/tap/terraform · otros: https://developer.hashicorp.com/terraform/install"; fi
fi

# --- Postgres -------------------------------------------------------------------------------
comprobar_pg() {
  local tier=$1 vurl="DATABASE_URL_$1" vsalto="DATABASE_SSH_JUMP_$1"
  local server; server="postgres-$(printf '%s' "$tier" | tr 'A-Z' 'a-z')"
  seccion "Postgres: $server"
  leer "$vurl"; local url=$VAL origen=$ORIGEN
  leer "$vsalto"; local salto=$VAL

  if [[ -z "$url" ]]; then
    if [[ -n "$salto" ]]; then
      informe FALLO "$vsalto está definida pero falta $vurl: sin URL no hay túnel que abrir" "$(plantilla_url "$tier")"
    elif [[ $tier == PROD ]] && $usa_pg; then
      informe AVISO "falta $vurl: $server no arrancará" "$(plantilla_url PROD)"
    elif [[ $tier == PROD ]]; then
      informe INFO "sin $vurl: este repo no parece tener BD (ni alembic.ini ni dependencias de Postgres)" "$(plantilla_url PROD)"
    else
      informe INFO "sin $vurl: $server no arrancará. Si el repo no tiene BD de dev, no hace falta" "$(plantilla_url DEV)"
    fi
    return 0
  fi

  case "$url" in
    *'${'*) informe FALLO "$vurl tiene un \${...} sin expandir: el MCP recibiría el texto tal cual" "$(plantilla_url "$tier")"; return 0 ;;
    postgres://*|postgresql://*) ;;
    *) informe FALLO "$vurl no es una URL de Postgres (debe empezar por postgresql://)" "$(plantilla_url "$tier")"; return 0 ;;
  esac
  if [[ $tier == PROD && -n "$(de_fichero "$COMPARTIDO" "$vurl")" ]] \
    && git ls-files --error-unmatch "$COMPARTIDO" >/dev/null 2>&1; then
    informe FALLO "$vurl está en $COMPARTIDO, que se versiona, y lleva la clave de prod" \
      "Muévela a $LOCAL (no se versiona). Si ya se subió a git, cambia la clave."
  fi
  if [[ $origen != sesión ]]; then
    informe INFO "$vurl está en $origen, pero esta sesión no la tiene: reinicia la sesión para que el MCP la vea"
  fi
  if ! tiene uvx; then
    informe FALLO "falta uvx: $server arranca con uvx" \
      "macOS: brew install uv · otros: https://docs.astral.sh/uv/getting-started/installation/"
    return 0
  fi
  if [[ -n "$salto" ]]; then
    if ! pg_url_partes "$url"; then
      informe FALLO "$vurl no vale para la máquina de salto: $PG_MOTIVO" \
        "Con salto, la URL tiene que ser de un solo host: postgresql://<usuario>:<clave>@<servidor>:5432/<bd>?sslmode=require"
      return 0
    fi
    if ! tiene ssh; then informe FALLO "falta ssh y hay máquina de salto ($vsalto)"; return 0; fi
  fi
  [[ $modo == completo ]] || return 0

  # A partir de aquí, con red: solo en el repaso completo.
  if [[ -n "$salto" ]]; then
    local nombre err
    nombre=$(ssh -G "$salto" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')
    if [[ "$salto" != *@* && "$salto" != *.* && "$nombre" == "$salto" ]]; then
      informe AVISO "$vsalto=$salto no está definido como alias en ~/.ssh/config" "$(plantilla_alias "$salto")"
    fi
    if ! err=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$salto" true </dev/null 2>&1); then
      informe FALLO "no se entra en la máquina de salto sin preguntar (ssh $salto: $(printf '%s' "$err" | tail -1))" "$(arreglo_ssh "$salto")"
      return 0
    fi
    informe OK "máquina de salto: ssh $salto entra sin preguntar"
  fi
  local salida linea
  if salida=$(TALLER_PG_COMPROBAR=1 "$aqui/postgres-mcp-launcher.sh" "$tier" "$url" "$salto" 2>&1); then
    linea=$(printf '%s\n' "$salida" | grep '^rol=' | tail -1)
    informe OK "conecta${salto:+ por $salto} ($linea)"
    if [[ $tier == PROD ]]; then
      case "$linea" in *superusuario=True*|*crea_en_bd=True*)
        informe AVISO "el rol de prod puede escribir ($linea): el plugin espera uno de solo lectura" \
          "Usa un rol de lectura en $vurl. Solo el repo que administra el propio servidor puede usar el admin, y lo documenta ese repo." ;;
      esac
      case "$linea" in *ssl=False*)
        informe AVISO "la conexión a prod va sin TLS" "Añade sslmode=require (o verify-full) a $vurl." ;;
      esac
    fi
  else
    informe FALLO "no conecta con $vurl${salto:+ por $salto}" \
      "$(printf '%s\n' "$salida" | grep -v 'túnel por' | grep -v '^$' | tail -4)"
  fi
}
comprobar_pg PROD
comprobar_pg DEV

# --- MCP terraform y azure-mcp (con red o demonios: solo en el repaso completo) -------------
if [[ $modo == completo ]]; then
  tfs=$(find . -maxdepth 3 -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null)
  if [[ -n "$tfs" ]]; then
    seccion "MCP terraform y azure-mcp"
    if ! tiene docker; then
      informe AVISO "falta Docker: el MCP terraform corre en un contenedor" "macOS: Docker Desktop u OrbStack · Linux: https://docs.docker.com/engine/install/"
    elif ! docker info >/dev/null 2>&1; then
      informe AVISO "Docker no está arrancado: el MCP terraform no arrancará" "Arranca Docker Desktop (macOS) o el servicio docker."
    else informe OK "Docker en marcha (MCP terraform)"; fi
    azure=false
    while IFS= read -r f; do grep -qs azurerm "$f" && { azure=true; break; }; done <<EOF
$tfs
EOF
    if $azure; then
      tiene npx || informe AVISO "falta npx (Node): azure-mcp arranca con npx" "macOS: brew install node"
      if ! tiene az; then
        informe AVISO "falta az: azure-mcp se autentica con la sesión de Azure CLI" "macOS: brew install azure-cli"
      elif cuenta=$(az account show --query name -o tsv 2>/dev/null); then
        informe OK "sesión de az ($cuenta)"
      else informe AVISO "az no tiene sesión: azure-mcp no podrá autenticarse" "az login"; fi
    fi
  fi
fi

# --- Salida ---------------------------------------------------------------------------------
if [[ $modo == inicio ]]; then
  [[ $n_fallos -gt 0 ]] || exit 0
  msg="[taller] Hay configuración rota: $rotos. Pide /taller:doctor para revisarla y arreglarla."
  # JSON a mano: jq puede ser justo lo que falta.
  esc=${msg//\\/\\\\}; esc=${esc//\"/\\\"}
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc" "$esc"
  exit 0
fi
printf '\nResumen: %d fallo(s), %d aviso(s).\n' "$n_fallos" "$n_avisos"
exit 0
