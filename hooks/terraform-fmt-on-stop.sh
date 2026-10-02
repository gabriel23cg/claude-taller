#!/usr/bin/env bash
# Stop hook: al terminar el turno, `terraform fmt -recursive` sobre infra/.
#
# Se formatea al final del turno (no en cada Edit) para no romper el match exacto de
# ediciones incrementales de la herramienta Edit. Evita el CI rojo por `fmt -check`.
#
# No-op si el repo no tiene directorio infra/ o no hay terraform en el PATH
# (guarda de plugin multi-repo).
#
# Exit codes: 0 = siempre (el formateo nunca debe bloquear el cierre del turno).

set -euo pipefail

# En un worktree, CLAUDE_PROJECT_DIR puede ser la copia principal: formatearíamos el
# infra/ de OTRA copia de trabajo y no el de esta sesión (ver lib/dir-proyecto.sh).
input=$(cat 2>/dev/null || true)
dir=$(printf '%s' "$input" | "$(dirname "$0")/lib/dir-proyecto.sh")
cd "$dir"

[[ -d infra ]] || exit 0
command -v terraform >/dev/null 2>&1 || exit 0

terraform -chdir=infra fmt -recursive >/dev/null 2>&1 || true

exit 0
