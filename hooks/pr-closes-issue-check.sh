#!/usr/bin/env bash
# PostToolUse (Bash): tras un `gh pr create`, comprueba que el PR enlazó de verdad con el
# issue que dice cerrar. Si el cuerpo trae intención de cierre pero GitHub no la reconoció,
# devuelve al modelo el motivo y el arreglo.
#
# Por qué: el keyword de cierre es frágil de una forma que no se ve. `Closes #12` enlaza;
# `` `Closes #12` `` (con backticks) no; `- Closes #12 — y además...` (en un bullet con
# texto detrás) puede no enlazar; «Cierra #12» no enlaza nunca porque el keyword va en
# inglés. En los tres casos el PR se crea tan contento y el issue se queda abierto para
# siempre. La skill `open-pr` lo verifica; este hook cubre el camino de al lado (crear el
# PR con gh directamente), igual que `issue-fields-reminder` hace con los issues.
#
# Precisión antes que cobertura: solo avisa cuando hay INTENCIÓN evidente de cerrar (un
# keyword de cierre y un #N en el cuerpo) y aun así `closingIssuesReferences` viene vacío.
# Un PR sin ningún issue detrás, o uno que solo referencia otro issue ("relacionado con
# #12", "ver #3"), NO se toca: eso es legítimo y avisar sería ruido en cada PR pequeño. El
# precio es no detectar al que se olvidó de enlazar del todo — trade-off deliberado, del
# mismo signo que el del guard de block-terraform-apply pero al revés (aquí preferimos el
# falso negativo al falso positivo, porque este hook corre en PRs ajenos también).
#
# El PR YA está creado cuando esto corre (es PostToolUse): no bloquea nada.
#
# Exit codes:
#   0 = nada que decir (o no aplica).
#   2 = intención de cierre que no enlazó: stderr al modelo con el arreglo.

set -uo pipefail

input=$(cat)

# Guarda barata primero: este hook corre en CADA Bash de todos los repos consumidores.
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
case "$cmd" in
  *"gh pr create"*) ;;
  *) exit 0 ;;
esac

command -v gh >/dev/null 2>&1 || exit 0

# La URL del PR sale por stdout de gh. Se busca en todo el JSON de respuesta en vez de en
# un campo concreto: el shape de tool_response no es contrato estable.
url=$(printf '%s' "$input" | tr -d '\\' \
  | grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' \
  | head -1)
[[ -n "$url" ]] || exit 0

# Una sola llamada. Si falla (red, auth, rate limit), no molestamos.
datos=$(gh pr view "$url" --json closingIssuesReferences,body 2>/dev/null) || exit 0

enlazados=$(printf '%s' "$datos" | jq -r '[.closingIssuesReferences[]?.number] | length' 2>/dev/null) || exit 0
[[ "$enlazados" == "0" ]] || exit 0   # enlazó: nada que decir

body=$(printf '%s' "$datos" | jq -r '.body // ""' 2>/dev/null) || exit 0

# ¿Hay intención de cierre? Un keyword (los de GitHub + los castellanos, que son el error
# clásico de un repo que escribe en español) PEGADO a una referencia #N.
#
# La adyacencia es la clave y no es un detalle: buscar el keyword y el #N por separado da
# falso positivo con la frase más normal del mundo en un cuerpo en español — "contexto en
# #12, pero este PR no lo cierra" tiene las dos cosas y no es intención de cierre.
#
# Sin \b: el word boundary de GNU grep no es portable al grep BSD de macOS. (^|[^A-Za-z])
# hace lo mismo en los dos.
printf '%s' "$body" \
  | grep -qiE '(^|[^A-Za-z])(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)|cierra|cerrar|soluciona|resuelve)[[:space:]:]*#[0-9]+' \
  || exit 0

cat >&2 <<EOF
El PR $url dice cerrar un issue pero NO ha enlazado: closingIssuesReferences viene vacío,
así que al mergearlo el issue se quedará abierto.

Causas, por frecuencia:
  1. El keyword va entre backticks (\`Closes #12\`) — los backticks lo desactivan.
  2. Va en un bullet con más texto detrás (- Closes #12 — y además...).
  3. Está en castellano (Cierra #12). El keyword va en INGLÉS: Closes / Fixes / Resolves.
  4. El issue es de otro repo y falta cualificarlo: owner/repo#12.

Arréglalo y reverifica:

  gh pr edit $url --body-file <fichero>   # 'Closes #N' en TEXTO PLANO y en su PROPIA LÍNEA
  gh pr view $url --json closingIssuesReferences

Si este PR no debe cerrar ningún issue, no hay nada que hacer: ignora este aviso.
Detalle completo en la skill open-pr.
EOF
exit 2
