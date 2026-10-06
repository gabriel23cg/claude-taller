#!/usr/bin/env bash
# Stop hook: al terminar el turno del agente, aplica `ruff format` + `ruff check --fix`
# sobre los .py cambiados.
#
# Aquí vive el autofix que no corre por-edición (ver ruff-on-edit.sh): hacerlo una sola
# vez al final evita borrar imports sin usar a mitad de un refactor multi-edición (lo que
# causaba cascadas de `F821`). Da el mismo feedback en sesión —evita el ciclo
# "commit -> pre-commit falla -> arreglar"— sin pelear con las ediciones incrementales.
#
# Ámbito: solo los .py modificados respecto a HEAD (staged+unstaged) y los no rastreados,
# para no reformatear todo el árbol ni tocar ficheros ajenos al turno.
#
# No-op en repos sin ruff (guarda de plugin multi-repo: los hay de Terraform puro).
# Compatibilidad: sin `mapfile` (el bash 3.2 de macOS no lo tiene).
#
# Exit codes:
#   0 = silencioso (todo OK o nada que hacer).
#   2 = ruff check sigue reportando issues no-autofixables (stderr al modelo, que sigue
#       trabajando para arreglarlos antes de parar de verdad).

set -euo pipefail

# El input del hook trae stop_hook_active=true cuando este Stop ya es la continuación
# forzada por un exit 2 nuestro anterior: se usa abajo para no re-bloquear en bucle.
input=$(cat 2>/dev/null || true)
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)

# En un worktree, CLAUDE_PROJECT_DIR puede ser la copia principal: formatearíamos los
# .py cambiados de OTRA copia de trabajo, quizá con trabajo a medias (ver
# lib/dir-proyecto.sh).
dir=$(printf '%s' "$input" | "$(dirname "$0")/lib/dir-proyecto.sh")
cd "$dir"

# Solo en proyectos Python con ruff configurado.
[[ -f pyproject.toml ]] || exit 0
grep -q '^\[tool\.ruff\]' pyproject.toml || exit 0

# .py cambiados respecto a HEAD + no rastreados (cubre lo editado/creado en el turno).
changed=$(
  {
    git diff --name-only --diff-filter=ACMR HEAD -- '*.py' 2>/dev/null || true
    git ls-files --others --exclude-standard -- '*.py' 2>/dev/null || true
  } | sort -u
)
[[ -z "$changed" ]] && exit 0

# Filtra a los que existen de verdad (un borrado/rename podría colarse en la lista).
files=()
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] && files+=("$f")
done <<< "$changed"
[[ ${#files[@]} -eq 0 ]] && exit 0

uv run ruff format "${files[@]}" >/dev/null 2>&1 || true

if ! check_output=$(uv run ruff check --fix "${files[@]}" 2>&1); then
  # Solo bloqueamos UNA vez por Stop: si ya venimos de un bloqueo nuestro
  # (stop_hook_active) y los issues siguen sin ser arreglables, re-bloquear crearía un
  # bucle infinito de Stops. Pre-commit + CI quedan como backstop.
  [[ "$stop_active" == "true" ]] && exit 0
  cat >&2 <<EOF
ruff check (tras --fix) sigue reportando issues en los .py cambiados:

$check_output
EOF
  exit 2
fi

exit 0
