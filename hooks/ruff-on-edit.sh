#!/usr/bin/env bash
# PostToolUse hook: tras editar un .py, aplica SOLO `ruff format` (idempotente y NO
# destructivo).
#
# El `ruff check --fix` vive en el hook `Stop` (ruff-fix-on-stop.sh): correr el autofix
# en CADA edición borraba imports sin usar (F401) a mitad de un refactor multi-edición
# (añadir un import en una edición y su uso en la siguiente → el import se borraba entre
# medias → `F821`). Pre-commit + CI siguen siendo el backstop.
#
# No-op en repos sin ruff: si el pyproject.toml del proyecto no declara [tool.ruff]
# (p. ej. uno de Terraform puro), el hook sale sin hacer nada.
#
# Exit codes:
#   0 = siempre (format no falla de forma accionable; reporta a CI/Stop si algo queda).

set -euo pipefail

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')

# Solo nos importan archivos .py existentes.
case "$file_path" in
  *.py) ;;
  *) exit 0 ;;
esac
[[ -f "$file_path" ]] || exit 0

# En un worktree, CLAUDE_PROJECT_DIR es la copia principal: la guarda leería el pyproject
# de otra copia de trabajo y `uv run` usaría su entorno (ver lib/dir-proyecto.sh).
dir=$(printf '%s' "$input" | "$(dirname "$0")/lib/dir-proyecto.sh")

# Solo en proyectos Python con ruff configurado (guarda de plugin multi-repo).
[[ -f "$dir/pyproject.toml" ]] || exit 0
grep -q '^\[tool\.ruff\]' "$dir/pyproject.toml" || exit 0

cd "$dir"

# Solo procesamos archivos dentro del proyecto.
case "$file_path" in
  "$dir"*) ;;
  *) exit 0 ;;
esac

# Format (idempotente, nunca destructivo). El lint + autofix va en el hook `Stop`.
uv run ruff format "$file_path" >/dev/null 2>&1 || true

exit 0
