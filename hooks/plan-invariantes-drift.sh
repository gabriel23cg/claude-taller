#!/usr/bin/env bash
# Stop hook: si el turno añadió o quitó recursos en `infra/` sin tocar
# `.claude/plan-invariantes.md`, devuelve al modelo la tarea de revisar los invariantes.
#
# Por qué: el agente `terraform-plan-reviewer` mantiene ese fichero cuando se le invoca,
# pero la infra se cambia muchas más veces de las que se revisa un plan. Sin este aviso,
# los invariantes se quedan describiendo el repo de hace tres PRs — y como el agente es
# genérico, un fichero podrido degrada la revisión entera en silencio.
#
# Solo avisa de cambios ESTRUCTURALES (altas/bajas de `resource`/`module`/`data`), no de
# retocar un tag o un default: esos no cambian qué puede destruirse.
#
# No-op en repos sin `infra/` o sin git (guarda de plugin multi-repo: casi todos los
# consumidores tienen infra, pero no se puede asumir).
#
# Compatibilidad: sin `mapfile` (bash 3.2 de macOS).
#
# Exit codes:
#   0 = nada que revisar (o no aplica).
#   2 = stderr al modelo, que revisa los invariantes antes de parar de verdad.

set -uo pipefail

input=$(cat 2>/dev/null || true)
# Una sola vez por cadena de Stop: si ya venimos de un bloqueo nuestro, no re-bloqueamos
# (mismo patrón que ruff-fix-on-stop; evita el bucle infinito de Stops).
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
[[ "$stop_active" == "true" ]] && exit 0

# En un worktree, CLAUDE_PROJECT_DIR es la copia principal: miraríamos el infra/ de otra
# copia de trabajo (ver lib/dir-proyecto.sh).
dir=$(printf '%s' "$input" | "$(dirname "$0")/lib/dir-proyecto.sh")
cd "$dir" 2>/dev/null || exit 0
[[ -d infra ]] || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# .tf tocados en el turno: modificados respecto a HEAD + no rastreados.
changed=$(
  {
    git diff --name-only --diff-filter=ACMR HEAD -- infra 2>/dev/null || true
    git ls-files --others --exclude-standard -- infra 2>/dev/null || true
  } | grep '\.tf$' | sort -u
)
[[ -z "$changed" ]] && exit 0

# ¿Hay altas/bajas de bloques? En el diff salen como líneas +/- que abren un bloque.
estructural=no
if git diff HEAD -- infra 2>/dev/null | grep -qE '^[-+](resource|module|data) "'; then
  estructural=si
else
  # Un .tf nuevo no aparece en el diff: cuenta si declara algún bloque.
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then continue; fi
    if grep -qE '^(resource|module|data) "' "$f"; then estructural=si; break; fi
  done <<< "$changed"
fi
[[ "$estructural" == "no" ]] && exit 0

inv=.claude/plan-invariantes.md

# Si el turno ya tocó el fichero, damos por hecho que se ha pensado en ello.
tocado=$(
  {
    git diff --name-only HEAD -- "$inv" 2>/dev/null || true
    git ls-files --others --exclude-standard -- "$inv" 2>/dev/null || true
  } | sort -u
)
[[ -n "$tocado" ]] && exit 0

if [[ ! -f "$inv" ]]; then
  cat >&2 <<EOF
Este turno ha añadido o quitado recursos en infra/ y este repo NO tiene
.claude/plan-invariantes.md. Ese fichero es lo que hace útil al agente
terraform-plan-reviewer: sin él, la revisión de planes queda en reglas genéricas.

Créalo con el agente terraform-plan-reviewer (es su dueño: sabe la forma y qué debe
cubrir), derivándolo de infra/ de este repo. Ficheros tocados:
$changed
EOF
else
  cat >&2 <<EOF
Este turno ha añadido o quitado recursos en infra/ sin tocar .claude/plan-invariantes.md:

$changed

Comprueba si los invariantes siguen describiendo el repo: ¿el cambio añade un recurso con
estado, un lock, un secreto generado o una dependencia cross-repo que nadie cubre? ¿algún
invariante cita algo que este cambio retira? Actualízalo si procede (el agente
terraform-plan-reviewer es su dueño y sabe la forma) o di explícitamente que lo has
revisado y no hace falta cambiar nada.
EOF
fi
exit 2
