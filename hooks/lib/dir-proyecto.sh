#!/usr/bin/env bash
# Imprime el directorio sobre el que debe trabajar un hook: el proyecto de
# CLAUDE_PROJECT_DIR, pero en el git worktree donde está la sesión.
#
# Por qué existe: en una sesión dentro de un worktree (`--worktree`, `EnterWorktree` o la
# app de escritorio, todos en `<repo>/.claude/worktrees/<nombre>`), CLAUDE_PROJECT_DIR
# apunta a la copia PRINCIPAL, no al worktree. Es así por diseño (doc de worktrees,
# verificado 2026-10-02: «`${CLAUDE_PROJECT_DIR}` stays put: it still points at the
# project root where the session started»), y se notó en la práctica en el issue #2. Un
# hook que hace `cd "$CLAUDE_PROJECT_DIR"` mide, avisa o —lo peor— formatea los ficheros
# de otra copia de trabajo, que puede tener cambios a medias de otra sesión. Y calla
# cuando el worktree sí tiene algo que decir.
#
# La señal del worktree es el `cwd` del JSON de entrada del hook (misma doc: «is the
# worktree root, and it moves again when Claude runs `cd`»). Ese «moves again» es por lo
# que no se usa a ciegas: tras un `cd` a otro repo (un clon en un directorio temporal, un
# repo hermano), el cwd ya no dice nada del proyecto, y un hook que formatea no debe
# seguirlo hasta allí. Por eso solo se toma cuando es OTRO worktree del MISMO repositorio
# (mismo git common dir); en cualquier otro caso sale CLAUDE_PROJECT_DIR tal cual.
#
# En una sesión normal, sin worktree, la salida es CLAUDE_PROJECT_DIR exacto, sin
# normalizar: el arreglo no cambia nada donde no había fallo.
#
# Se conserva la posición del proyecto dentro del repo: si CLAUDE_PROJECT_DIR es un
# subdirectorio (un monorepo abierto desde `backend/`), sale ese mismo subdirectorio dentro
# del worktree, no su raíz.
#
# Uso:     dir=$(printf '%s' "$input" | "$(dirname "$0")/lib/dir-proyecto.sh")
#          (antes de cualquier `cd`: con $0 relativo, la ruta del helper dejaría de valer)
# Entrada: el JSON del hook por stdin (sin él, o sin jq, cae a CLAUDE_PROJECT_DIR).
# Salida:  el directorio por stdout. Exit 0 siempre.

set -uo pipefail

proyecto=${CLAUDE_PROJECT_DIR:-.}
cwd=$(jq -r '.cwd // empty' 2>/dev/null || true)

raiz() { git -C "$1" rev-parse --show-toplevel 2>/dev/null; }
# El common dir de un worktree llega por su fichero `commondir` y el de la principal es
# `.git` relativo: se comparan resueltos con `pwd -P`, no como texto. El `-n` no sobra:
# `cd ""` no falla en bash, y sin él un git que no responde daría el propio directorio.
comun() {
  (cd "$1" 2>/dev/null && g=$(git rev-parse --git-common-dir 2>/dev/null) && [[ -n "$g" ]] \
    && cd "$g" 2>/dev/null && pwd -P)
}

dir=$proyecto
if [[ -n "$cwd" ]]; then
  wt=$(raiz "$cwd"); top=$(raiz "$proyecto")
  if [[ -n "$wt" && -n "$top" && "$wt" != "$top" ]]; then
    c_wt=$(comun "$cwd"); c_top=$(comun "$proyecto")
    if [[ -n "$c_wt" && "$c_wt" == "$c_top" ]]; then
      dir="$wt/$(git -C "$proyecto" rev-parse --show-prefix 2>/dev/null)"
      dir=${dir%/}
    fi
  fi
fi
printf '%s\n' "$dir"
exit 0
