#!/usr/bin/env bash
# PreToolUse (Bash): bloquea `terraform apply|destroy` en local — el
# apply corre SOLO por CI (workflow_dispatch action=apply con plan_run_id, sobre main).
#
# Excepción: comandos que mencionan `bootstrap` (el módulo de tfstate con estado local
# se aplica en local una vez por entorno; es la excepción documentada en cada repo).
#
# Origen: hook inline del .claude/settings.json de un repo de infra, factorizado al plugin
# porque todos los repos que usan el mismo flujo plan/apply con tfplan cifrado lo necesitan.
#
# Exit codes: 0 = continuar; 2 = bloquear (stderr se envía al modelo).

set -euo pipefail

cmd=$(jq -r '.tool_input.command // empty')

if printf '%s' "$cmd" | grep -Eq 'terraform([[:space:]]+-chdir=[^[:space:]]+)?[[:space:]]+(apply|destroy)' \
  && ! printf '%s' "$cmd" | grep -q 'bootstrap'; then
  cat >&2 <<'EOF'
BLOQUEADO: apply/destroy de la infra principal solo por CI (workflow_dispatch
action=apply con plan_run_id, sobre main). Ver CLAUDE.md del repo. (bootstrap
sí se aplica en local: es la excepción documentada, una vez por entorno.)
EOF
  exit 2
fi

exit 0
