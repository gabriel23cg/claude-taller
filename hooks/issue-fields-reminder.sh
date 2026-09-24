#!/usr/bin/env bash
# PostToolUse (Bash): tras un `gh issue create`, comprueba que el issue quedó con los
# campos nativos de issue de la organización puestos y, si falta alguno, devuelve al
# modelo la receta exacta para ponerlos.
#
# Por qué: algunas organizaciones definen campos NATIVOS de issue (Priority, Effort,
# Severity… — son de la org, un issue los tiene sin estar en ningún proyecto) y `gh` no
# tiene flag para ellos, así que un `gh issue create` a pelo los deja siempre vacíos. La
# skill `gh-create-issue` los pone; este hook cubre el camino de al lado para que la regla
# "ningún issue sin clasificar" no dependa de acordarse de usar la skill.
#
# Genérico a propósito: NO trae dentro ninguna organización ni ningún fieldId. Pregunta a
# la API qué campos existen y resuelve los IDs en runtime, así que funciona igual en
# cualquier repo y no-opea limpiamente en la mayoría, que no usa estos campos.
#
# El issue YA está creado cuando esto corre (es PostToolUse): no bloquea nada, solo
# devuelve trabajo pendiente al modelo. Por eso mismo sirve de verificación tras
# `setIssueFieldValue`: relee el issue y canta si el valor no aterrizó.
#
# No-op agresivo: cualquier cosa que no sea un `gh issue create` con éxito sobre un repo
# de una org que use estos campos sale con 0, igual que un fallo de red o de auth. Nunca
# molesta por ruido.
#
# Exit codes:
#   0 = nada que decir (o no aplica).
#   2 = faltan campos: stderr al modelo con la mutación exacta y los IDs ya resueltos.

set -uo pipefail

input=$(cat)

# Guarda barata primero: este hook corre en CADA Bash de todos los repos consumidores.
#
# Dos disparos, y el segundo es el que de verdad protege: `setIssueFieldValue` puede NO
# guardar el valor y responder como si hubiera ido bien (pasa con confidence != HIGH).
# Comprobar solo tras `gh issue create` deja fuera justo el caso en que el issue se queda
# sin campo después de que alguien creyera ponérselo.
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
case "$cmd" in
  *"gh issue create"*|*setIssueFieldValue*) ;;
  *) exit 0 ;;
esac

command -v gh >/dev/null 2>&1 || exit 0

# La URL del issue sale por stdout de gh. Se busca en todo el JSON de respuesta en vez de
# en un campo concreto: el shape de tool_response no es contrato estable.
url=$(printf '%s' "$input" | tr -d '\\' \
  | grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+' \
  | head -1)
[[ -n "$url" ]] || exit 0

repo=${url#https://github.com/}; repo=${repo%%/issues/*}
owner=${repo%%/*}; name=${repo#*/}
num=${url##*/}

# ¿Esta organización define campos nativos de issue? Solo miramos los single-select: los
# de fecha (Start/Target date) están legítimamente vacíos casi siempre y avisar de ellos
# sería ruido. Si el owner es un usuario y no una org, esto falla -> no-op, que es lo
# correcto: ahí estos campos no existen.
campos=$(gh api graphql -f query='
  query($o:String!) { organization(login:$o) { issueFields(first:50) { nodes {
    ... on IssueFieldSingleSelect { id name options { id name } }
  } } } }' -F o="$owner" \
  --jq '.data.organization.issueFields.nodes[]? | select(.id != null and (.options | length) > 0)
        | .name + "\t" + .id + "\t" + ([.options[] | .name + "=" + .id] | join(" "))' \
  2>/dev/null) || exit 0
[[ -n "$campos" ]] || exit 0

# Qué campos tiene puestos ya el issue. Si la consulta falla (red, auth, rate limit), no
# molestamos: un aviso a ciegas es peor que ninguno.
puestos=$(gh api graphql -f query='
  query($o:String!, $n:String!, $num:Int!) {
    repository(owner:$o, name:$n) { issue(number:$num) {
      issueFieldValues(first:20) { nodes {
        ... on IssueFieldSingleSelectValue { field { ... on IssueFieldSingleSelect { name } } value }
      } } } }
  }' -F o="$owner" -F n="$name" -F num="$num" \
  --jq '[.data.repository.issue.issueFieldValues.nodes[]? | select(.field.name != null) | .field.name] | join("\n")' \
  2>/dev/null) || exit 0

# Bash 3.2 (el de macOS): sin mapfile, sin ${var,,}.
faltan_nombres=""
faltan_detalle=""
while IFS=$'\t' read -r fname fid fopts; do
  [[ -n "$fname" ]] || continue
  # Coincidencia de línea completa: `Effort` no debe darse por puesto porque exista `Effort estimate`.
  printf '%s\n' "$puestos" | grep -qxF "$fname" && continue
  faltan_nombres="$faltan_nombres $fname"
  faltan_detalle="$faltan_detalle
  { fieldId: \"$fid\", singleSelectOptionId: \"<$fname>\", rationale: \"<por qué>\", confidence: HIGH },
  # $fname: $fopts"
done <<< "$campos"

[[ -n "$faltan_nombres" ]] || exit 0

cat >&2 <<EOF
El issue $url se ha creado SIN:$faltan_nombres

Esta organización define esos campos y un issue sin ellos no se puede ordenar en el
triage. Si el usuario no los dijo, infiérelos (prioridad = impacto si no se hace;
esfuerzo = trabajo hasta tenerlo mergeado y verificado), ponlos ahora y dile cuáles has
inferido. Los IDs de abajo ya están resueltos para esta organización:

ISSUE_ID=\$(gh issue view $url --json id -q .id)
gh api graphql -f query='
mutation(\$id: ID!) {
  setIssueFieldValue(input: { issueId: \$id, issueFields: [$faltan_detalle
  ]}) { issue { number url } }
}' -f id="\$ISSUE_ID"

Quita las líneas de comentario y sustituye cada <Campo> por el optionId que toque.

confidence va SIEMPRE en HIGH: con MEDIUM el campo NO se guarda y la mutación tampoco da
error — responde bien y el issue se queda igual de vacío. Y no uses suggest:true, que deja
el valor como sugerencia pendiente en vez de aplicarlo.

Después de la mutación, RELEE los campos: esta comprobación volverá a correr y te lo dirá.
Rúbrica y detalle completo en la skill gh-create-issue.
EOF
exit 2
