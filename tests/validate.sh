#!/usr/bin/env bash
# Validación del plugin: JSON, sintaxis, wiring y smoke tests de los hooks.
#
# Es la MISMA que corre CI (.github/workflows/validate.yml) y la que pide CLAUDE.md
# antes de un push. Un cambio roto aquí llega a la vez a todos los repos que lo
# consumen, así que las comprobaciones van más allá de "el JSON parsea":
# también verifican que las rutas de hooks.json/.mcp.json existen y son ejecutables
# (un rename silencioso rompe los tres repos) y que los guards no-op siguen siendo no-op.
#
# No usa `set -e` a propósito: queremos el informe completo, no el primer fallo.
# Compatible con el bash 3.2 de macOS (sin mapfile, sin ${var,,}).

set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
ko()   { printf '  \033[31mFALLO\033[0m %s\n' "$1"; fails=$((fails + 1)); }
head_() { printf '\n== %s\n' "$1"; }

# Ejecuta un hook con JSON por stdin y compara el exit code con el esperado.
expect_exit() { # expect_exit <esperado> <descripción> <cmd...>
  local want=$1 desc=$2; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then ok "$desc (exit $got)"; else ko "$desc: esperado $want, obtenido $got"; fi
}

hook_exit() { # hook_exit <esperado> <descripción> <script> <json-stdin> [env...]
  local want=$1 desc=$2 script=$3 json=$4; shift 4
  local got=0
  printf '%s' "$json" | env "$@" "$script" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then ok "$desc (exit $got)"; else ko "$desc: esperado $want, obtenido $got"; fi
}

head_ "JSON válido"
for f in .mcp.json .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  if jq empty "$f" 2>/dev/null; then ok "$f"; else ko "$f no parsea"; fi
done

head_ "Sintaxis bash"
for f in hooks/*.sh hooks/lib/*.sh scripts/*.sh tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "$f"; else ko "$f: error de sintaxis"; fi
done

head_ "Scripts ejecutables"
# hooks/lib/ también: sus helpers se invocan, no se cargan con `source`.
for f in hooks/*.sh hooks/lib/*.sh scripts/*.sh; do
  if [[ -x "$f" ]]; then ok "$f +x"; else ko "$f sin bit de ejecución (fallaría al invocarlo el plugin)"; fi
done

head_ "Sin bin/ en la raíz"
# claude.ai rechaza un plugin con un bin/ de primer nivel, tanto al sincronizarlo como
# marketplace de la organización como al subirlo a mano («Plugin contains a top-level bin/
# directory»). Claude Code lo aceptaría sin quejarse, así que el fallo solo saldría al
# repartirlo por claude.ai: esta guarda lo adelanta. Los ejecutables van en scripts/.
if [[ -e bin ]]; then ko "existe bin/ en la raíz: claude.ai rechazaría el plugin (muévelo a scripts/)"; else ok "no hay bin/ en la raíz"; fi

head_ "Wiring de hooks.json y .mcp.json"
# Toda ruta del plugin debe ir por ${CLAUDE_PLUGIN_ROOT}: el plugin se COPIA a la caché
# al instalarse, así que una ruta relativa o absoluta al repo no existe en el destino.
refs=$(
  jq -r '.. | objects | select(has("command")) | .command' hooks/hooks.json
  jq -r '.mcpServers[].command' .mcp.json
)
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  case "$cmd" in
    '${CLAUDE_PLUGIN_ROOT}'/*)
      path=${cmd#'${CLAUDE_PLUGIN_ROOT}'/}
      if [[ -x "$path" ]]; then ok "$cmd"; else ko "$cmd apunta a algo que no existe o no es ejecutable"; fi
      ;;
    /*|./*|../*) ko "$cmd: ruta del repo sin \${CLAUDE_PLUGIN_ROOT} (no existirá en la caché del plugin)" ;;
    *) ok "$cmd (comando externo del PATH)" ;;
  esac
done <<< "$refs"

head_ "Frontmatter de skills y agentes"
# Sin name+description en el frontmatter, Claude Code no carga la skill/agente: fallo
# silencioso en los tres repos.
for f in skills/*/SKILL.md agents/*.md; do
  fm=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} {print}' "$f")
  if printf '%s' "$fm" | grep -q '^name:' && printf '%s' "$fm" | grep -q '^description:'; then
    ok "$f"
  else
    ko "$f: frontmatter sin name y/o description"
  fi
done

head_ "model y effort de los agentes"
# `claude plugin validate` da por bueno `model: sonet` o `effort: medio` (probado): el
# error solo aparecería al invocar el agente, en mitad de un /check-work. Aquí se caza al
# validar. Valores según la doc de subagentes: alias, `inherit` o un ID `claude-*`; y los
# cinco niveles de esfuerzo. Haiku no admite `effort`, así que esa pareja también es error.
fm_valor() { awk -v k="$2" 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} $0 ~ "^"k":" {sub("^"k":[[:space:]]*",""); print}' "$1"; }
modelo_valido()  { case "$1" in ""|sonnet|opus|haiku|fable|inherit|claude-*) return 0;; *) return 1;; esac; }
esfuerzo_valido() { case "$1" in ""|low|medium|high|xhigh|max) return 0;; *) return 1;; esac; }
# Control positivo: si las funciones aceptaran cualquier cosa, el bucle pasaría en falso.
if modelo_valido sonet || esfuerzo_valido medio; then ko "el chequeo de model/effort acepta valores inventados: está roto"
else ok "el chequeo rechaza valores inventados"; fi
for f in agents/*.md; do
  m=$(fm_valor "$f" model); e=$(fm_valor "$f" effort)
  if ! modelo_valido "$m"; then ko "$f: model '$m' no es un alias, inherit ni un ID claude-*"
  elif ! esfuerzo_valido "$e"; then ko "$f: effort '$e' no es low|medium|high|xhigh|max"
  elif [[ "$m" == haiku* || "$m" == claude-haiku* ]] && [[ -n "$e" ]]; then ko "$f: Haiku no admite effort"
  else ok "$f (model=${m:-hereda} effort=${e:-sesión})"; fi
done

head_ "Smoke: block-terraform-apply"
BTA=hooks/block-terraform-apply.sh
hook_exit 2 "apply de infra bloqueado"    "$BTA" '{"tool_input":{"command":"terraform -chdir=infra apply tfplan"}}'
hook_exit 2 "destroy bloqueado"           "$BTA" '{"tool_input":{"command":"terraform destroy"}}'
hook_exit 0 "bootstrap exento"            "$BTA" '{"tool_input":{"command":"terraform -chdir=infra/bootstrap apply"}}'
hook_exit 0 "plan permitido"              "$BTA" '{"tool_input":{"command":"terraform -chdir=infra plan -out=tfplan"}}'
hook_exit 0 "comando ajeno permitido"     "$BTA" '{"tool_input":{"command":"git status"}}'
# Falso positivo conocido y aceptado (documentado en CLAUDE.md): cualquier Bash que
# CONTENGA la cadena se bloquea. Se fija aquí para que el día que se cambie el matcher
# el test lo cante en vez de pasar desapercibido.
hook_exit 2 "falso positivo documentado (la cadena en un mensaje de commit)" \
  "$BTA" '{"tool_input":{"command":"git commit -m \"docs: nota sobre terraform apply\""}}'

head_ "Smoke: guards no-op (repos donde el hook no aplica)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '[project]\nname = "x"\n' > "$tmp/pyproject.toml"   # pyproject SIN [tool.ruff]
printf 'x  =  1\n' > "$tmp/x.py"                            # formato feo a propósito
before=$(cat "$tmp/x.py")

# OJO: con file_path inexistente el hook sale en el chequeo de `-f`, no en el guard de
# ruff — por eso el fichero existe de verdad aquí. Así el test valida el guard real.
hook_exit 0 "ruff-on-edit no-op sin [tool.ruff]" hooks/ruff-on-edit.sh \
  "{\"tool_input\":{\"file_path\":\"$tmp/x.py\"}}" "CLAUDE_PROJECT_DIR=$tmp"
if [[ "$(cat "$tmp/x.py")" == "$before" ]]; then ok "ruff-on-edit no tocó el fichero"; else ko "ruff-on-edit reformateó un repo sin ruff"; fi

rm -f "$tmp/pyproject.toml"
hook_exit 0 "ruff-on-edit no-op sin pyproject" hooks/ruff-on-edit.sh \
  "{\"tool_input\":{\"file_path\":\"$tmp/x.py\"}}" "CLAUDE_PROJECT_DIR=$tmp"
hook_exit 0 "ruff-fix-on-stop no-op sin pyproject" hooks/ruff-fix-on-stop.sh \
  '{"stop_hook_active":false}' "CLAUDE_PROJECT_DIR=$tmp"
hook_exit 0 "terraform-fmt-on-stop no-op sin infra/" hooks/terraform-fmt-on-stop.sh \
  '{}' "CLAUDE_PROJECT_DIR=$tmp"

head_ "Smoke: issue-fields-reminder"
IFR=hooks/issue-fields-reminder.sh
# Casos sin red: la guarda barata y la extracción de URL.
hook_exit 0 "comando ajeno ignorado" "$IFR" '{"tool_input":{"command":"git status"},"tool_response":{"stdout":""}}'
hook_exit 0 "gh issue create sin URL en la salida" "$IFR" '{"tool_input":{"command":"gh issue create --title x"},"tool_response":{"stdout":"algo raro"}}'
# El segundo disparo: setIssueFieldValue puede NO guardar el valor y responder OK, así que
# el hook tiene que releer también DESPUÉS de la mutación. Comprobar solo tras el create
# dejaba fuera justo el caso que perdió el Effort de dos issues reales.
hook_exit 0 "setIssueFieldValue sin URL en la salida" "$IFR" '{"tool_input":{"command":"gh api graphql -f query=mutation{setIssueFieldValue(...)}"},"tool_response":{"stdout":"{}"}}'

# El resto va con `gh` stubbeado, y no con issues reales: desde que el hook dejó de traer
# una org dentro (resuelve campos e IDs en runtime), lo que hay que fijar es su DECISIÓN,
# no la API. Además así corre en CI, donde no hay gh autenticado. El stub devuelve lo que
# gh devolvería YA pasado por el --jq del propio hook, que es lo que el hook consume.
mkdir -p "$tmp/ghstub"
cat > "$tmp/ghstub/gh" <<'STUB'
#!/bin/sh
case "$*" in
  *organization*) cat "$GH_STUB_ORG" ;;
  *repository*)   cat "$GH_STUB_ISSUE" ;;
  *)              exit 1 ;;
esac
STUB
chmod +x "$tmp/ghstub/gh"
IFR_JSON='{"tool_input":{"command":"gh issue create"},"tool_response":{"stdout":"https://github.com/una-org/un-repo/issues/7"}}'
printf 'Priority\tIFSS_p\tUrgent=o1 High=o2 Medium=o3 Low=o4\nEffort\tIFSS_e\tHigh=o5 Medium=o6 Low=o7\n' > "$tmp/org-con-campos"
: > "$tmp/org-sin-campos"
printf 'Priority\nEffort\n' > "$tmp/issue-completo"
printf 'Priority\n'         > "$tmp/issue-a-medias"
: > "$tmp/issue-vacio"
# Coincidencia de línea completa: `Effort` no debe darse por puesto porque exista otro
# campo cuyo nombre lo contenga. Es el bug que introduce un grep -q descuidado.
printf 'Priority\nEffort estimate\n' > "$tmp/issue-nombre-parecido"

hook_exit 0 "org sin campos nativos: no-op (el caso mayoritario)" "$IFR" "$IFR_JSON" \
  "PATH=$tmp/ghstub:$PATH" "GH_STUB_ORG=$tmp/org-sin-campos" "GH_STUB_ISSUE=$tmp/issue-vacio"
hook_exit 0 "issue con todos los campos puestos" "$IFR" "$IFR_JSON" \
  "PATH=$tmp/ghstub:$PATH" "GH_STUB_ORG=$tmp/org-con-campos" "GH_STUB_ISSUE=$tmp/issue-completo"
hook_exit 2 "falta un campo: devuelve la receta" "$IFR" "$IFR_JSON" \
  "PATH=$tmp/ghstub:$PATH" "GH_STUB_ORG=$tmp/org-con-campos" "GH_STUB_ISSUE=$tmp/issue-a-medias"
hook_exit 2 "un campo de nombre parecido no cuenta como puesto" "$IFR" "$IFR_JSON" \
  "PATH=$tmp/ghstub:$PATH" "GH_STUB_ORG=$tmp/org-con-campos" "GH_STUB_ISSUE=$tmp/issue-nombre-parecido"
# El caso real: la mutación dijo que sí, el campo quedó vacío. Con la URL en su respuesta
# (por eso la receta selecciona `url`), el hook lo relee y lo canta.
IFR_MUT='{"tool_input":{"command":"gh api graphql -f query=mutation{setIssueFieldValue}"},"tool_response":{"stdout":"{\"data\":{\"setIssueFieldValue\":{\"issue\":{\"number\":7,\"url\":\"https://github.com/una-org/un-repo/issues/7\"}}}}"}}'
hook_exit 2 "la mutación respondió bien pero el campo no aterrizó: lo caza" "$IFR" "$IFR_MUT" \
  "PATH=$tmp/ghstub:$PATH" "GH_STUB_ORG=$tmp/org-con-campos" "GH_STUB_ISSUE=$tmp/issue-a-medias"
hook_exit 0 "mutación con todo aterrizado: calla" "$IFR" "$IFR_MUT" \
  "PATH=$tmp/ghstub:$PATH" "GH_STUB_ORG=$tmp/org-con-campos" "GH_STUB_ISSUE=$tmp/issue-completo"

head_ "Smoke: pr-closes-issue-check"
PRC=hooks/pr-closes-issue-check.sh
hook_exit 0 "comando ajeno ignorado" "$PRC" '{"tool_input":{"command":"git push"},"tool_response":{"stdout":""}}'
hook_exit 0 "gh pr create sin URL en la salida" "$PRC" '{"tool_input":{"command":"gh pr create --title x"},"tool_response":{"stdout":""}}'

# Aquí el hook hace el jq él mismo, así que el stub devuelve el JSON crudo de `gh pr view`.
mkdir -p "$tmp/prstub"
printf '#!/bin/sh\ncat "$GH_STUB_PR"\n' > "$tmp/prstub/gh"
chmod +x "$tmp/prstub/gh"
PRC_JSON='{"tool_input":{"command":"gh pr create"},"tool_response":{"stdout":"https://github.com/una-org/un-repo/pull/42"}}'
printf '{"closingIssuesReferences":[{"number":12}],"body":"Closes #12"}'                  > "$tmp/pr-enlazado"
printf '{"closingIssuesReferences":[],"body":"Arregla el parser.\\n\\n`Closes #12`\\n"}'   > "$tmp/pr-backticks"
printf '{"closingIssuesReferences":[],"body":"Cierra #12 al mergear."}'                    > "$tmp/pr-castellano"
printf '{"closingIssuesReferences":[],"body":"- Closes #12 — y de paso ordena los tests."}' > "$tmp/pr-bullet"
# Adversarial: lleva un #N Y la palabra \"cierra\", pero NO es intención de cierre. Es la
# frase que hace que un hook mal afinado cante en cada PR de un repo que escribe en español.
printf '{"closingIssuesReferences":[],"body":"Contexto en #12, pero este PR no lo cierra."}' > "$tmp/pr-solo-referencia"
printf '{"closingIssuesReferences":[],"body":"Ajuste de dos líneas en el README."}'        > "$tmp/pr-sin-issue"

prc() { hook_exit "$1" "$2" "$PRC" "$PRC_JSON" "PATH=$tmp/prstub:$PATH" "GH_STUB_PR=$tmp/$3"; }
prc 0 "PR que enlazó bien"                          pr-enlazado
prc 2 "keyword entre backticks: intención sin enlace" pr-backticks
prc 2 "keyword en castellano: intención sin enlace"   pr-castellano
prc 2 "keyword en un bullet con texto detrás"         pr-bullet
# Los dos casos que sostienen el trade-off del hook (precisión sobre cobertura): sin ellos
# cantaría en cada PR pequeño y acabaría ignorándose, que es como muere un hook.
prc 0 "referencia sin intención de cierre: no molesta" pr-solo-referencia
prc 0 "PR sin ningún issue detrás: no molesta"         pr-sin-issue

head_ "Ninguna receta reparte confidence != HIGH"
# No es estilo: con confidence MEDIUM, setIssueFieldValue NO guarda el campo y NO da error.
# Lo tenían la skill Y el hook (que es quien reparte la receta cuando alguien no usa la
# skill), así que dos issues reales perdieron su Effort sin que saltara nada. Este test
# existe para que no vuelva a entrar por copiar y pegar.
#
# El patrón exige la sintaxis del input de GraphQL (el valor seguido de `,` o `}`), no la
# cadena suelta: la documentación del fallo TIENE que citar el valor malo para explicarlo
# ("con `confidence: MEDIUM` el campo no se guarda"), y un grep a secas prohibiría al
# plugin documentar su propio gotcha. Por eso, control positivo justo debajo: un grep que
# no casa nada pasa igual que uno correcto, y ese es el modo de fallo de estos tests.
CONF_RE='confidence:[[:space:]]*(MEDIUM|LOW)[[:space:]]*[,}]'
printf 'x: { rationale: "y", confidence: MEDIUM }\n' > "$tmp/conf-control.txt"
if grep -qE "$CONF_RE" "$tmp/conf-control.txt"; then ok "el patrón caza una receta mala"
else ko "el patrón no caza ni el control positivo: está roto, no hay nada verificado"; fi
malas=$(grep -rnE "$CONF_RE" skills/ hooks/ agents/ 2>/dev/null || true)
if [[ -z "$malas" ]]; then ok "confidence siempre HIGH"; else ko "confidence != HIGH: $malas"; fi

head_ "Smoke: plan-invariantes-drift"
DRIFT=$PWD/hooks/plan-invariantes-drift.sh
drift_repo() { # crea un repo git de pega con infra/ y, opcionalmente, invariantes
  local d; d=$(mktemp -d); ( cd "$d" && git init -q . && mkdir -p infra .claude \
    && printf 'resource "azurerm_resource_group" "rg" {\n  name = "x"\n}\n' > infra/main.tf \
    && { [[ "${1:-}" == "con-invariantes" ]] && printf '# Invariantes\n\n1. **rg** no se destruye.\n' > .claude/plan-invariantes.md || true; } \
    && git add -A && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1
  printf '%s' "$d"
}
d=$(drift_repo con-invariantes)
hook_exit 0 "sin cambios en infra/" "$DRIFT" '{"stop_hook_active":false}' "CLAUDE_PROJECT_DIR=$d"
printf 'tags = { a = "b" }\n' >> "$d/infra/main.tf"
hook_exit 0 "cambio no estructural (tags) no molesta" "$DRIFT" '{"stop_hook_active":false}' "CLAUDE_PROJECT_DIR=$d"
printf 'resource "azurerm_storage_account" "sa" {\n  name = "y"\n}\n' >> "$d/infra/main.tf"
hook_exit 2 "alta de resource con invariantes sin tocar" "$DRIFT" '{"stop_hook_active":false}' "CLAUDE_PROJECT_DIR=$d"
hook_exit 0 "anti-bucle: stop_hook_active ya activo" "$DRIFT" '{"stop_hook_active":true}' "CLAUDE_PROJECT_DIR=$d"
printf '\n2. **sa** nueva\n' >> "$d/.claude/plan-invariantes.md"
hook_exit 0 "alta + invariantes actualizados en el mismo turno" "$DRIFT" '{"stop_hook_active":false}' "CLAUDE_PROJECT_DIR=$d"
rm -rf "$d"
d=$(drift_repo)
printf 'resource "azurerm_storage_account" "sa" {\n  name = "y"\n}\n' >> "$d/infra/main.tf"
hook_exit 2 "alta de resource en repo sin fichero de invariantes" "$DRIFT" '{"stop_hook_active":false}' "CLAUDE_PROJECT_DIR=$d"
rm -rf "$d"
hook_exit 0 "no-op en repo sin infra/" "$DRIFT" '{"stop_hook_active":false}' "CLAUDE_PROJECT_DIR=$tmp"

head_ "Smoke: coverage-report"
COV=$PWD/hooks/coverage-report.sh
# Repo de pega con un informe de cobertura y un cambio sin commitear. Lo que se fija es la
# CIFRA DEL DIFF, que es la razón de ser del hook: la global no ve un módulo nuevo sin
# tests, y es justo lo que hay que cazar.
cov_repo() { # cov_repo <cobertura|lcov>
  local d; d=$(mktemp -d)
  ( cd "$d" && git init -q . && mkdir -p src coverage
    if [[ "$1" == cobertura ]]; then
      printf 'def a():\n    return 1\n' > src/foo.py
      git add -A && git -c user.email=t@t -c user.name=t commit -qm base
      printf 'def a():\n    return 1\n\ndef b():\n    return 2\n' > src/foo.py
      # líneas 4 y 5 son nuevas e instrumentadas; la 5 sin cubrir -> 50% del diff.
      # Adversarial a propósito: DOS <line> por línea de texto, como saldría de un XML
      # minificado. Un parser que solo mira el primero devuelve 100% y no se queja.
      printf '%s\n' '<coverage line-rate="0.75"><packages><package><classes>' \
        '<class filename="src/foo.py"><lines>' \
        '<line number="1" hits="1"/><line number="2" hits="1"/>' \
        '<line number="4" hits="1"/><line number="5" hits="0"/>' \
        '</lines></class></classes></package></packages></coverage>' > coverage.xml
    else
      printf 'export const a = 1\n' > src/foo.js
      git add -A && git -c user.email=t@t -c user.name=t commit -qm base
      printf 'export const a = 1\nexport const b = 2\nexport const c = 3\n' > src/foo.js
      printf 'SF:src/foo.js\nDA:1,5\nDA:2,0\nDA:3,0\nLF:3\nLH:1\nend_of_record\n' > coverage/lcov.info
    fi ) >/dev/null 2>&1
  printf '%s' "$d"
}
cov_dice() { # cov_dice <descripción> <patrón esperado> <dir>
  local salida; salida=$(printf '{}' | env "CLAUDE_PROJECT_DIR=$3" "$COV" 2>/dev/null)
  if printf '%s' "$salida" | grep -q "$2"; then ok "$1"; else ko "$1: salida = ${salida:-(vacía)}"; fi
}

d=$(cov_repo cobertura)
cov_dice "cobertura.xml: cifra del diff, no la global" '"systemMessage":"Cobertura: 50% de lo nuevo' "$d"
cov_dice "cuenta las líneas nuevas sin cubrir"          '1 línea(s) añadida(s) sin cubrir'          "$d"
cov_dice "la global va detrás, como contexto"           'global 75%'                                 "$d"
hook_exit 0 "nunca bloquea" "$COV" '{}' "CLAUDE_PROJECT_DIR=$d"
rm -rf "$d"

# Regresión: un fichero que NO es código no puede emparejar con uno del informe solo porque
# midan lo mismo. El emparejamiento por sufijo usaba index()==length(c)-length(d), y con
# longitudes iguales eso es 0==0 -> emparejaba cualquier cosa. Cazado corriendo el hook
# contra un repo de verdad: un `pyproject.toml` (14) casaba con `app/db/base.py` (14) y
# reportaba líneas sin cubrir de un cambio que solo tocaba configuración.
d=$(mktemp -d)
( cd "$d" && git init -q . && mkdir -p app/db
  printf 'x = 1\n' > app/db/base.py && printf '[project]\n' > pyproject.toml
  git add -A && git -c user.email=t@t -c user.name=t commit -qm base
  printf 'name = "x"\n' >> pyproject.toml   # 14 chars, igual que app/db/base.py
  printf '%s\n' '<coverage><packages><package><classes>' \
    '<class filename="app/db/base.py"><lines><line number="1" hits="0"/></lines></class>' \
    '</classes></package></packages></coverage>' > coverage.xml ) >/dev/null 2>&1
cov_dice "cambio solo de config no empareja con código de igual longitud" 'no aparece en el informe' "$d"
rm -rf "$d"

d=$(cov_repo lcov)
cov_dice "lcov: dos líneas nuevas sin cubrir -> 0%" '"Cobertura: 0% de lo nuevo (2 línea' "$d"
# El informe viejo es la trampa silenciosa: la cifra sería de OTRO código.
touch -t 202001010000 "$d/coverage/lcov.info"
cov_dice "informe anterior a los cambios: lo avisa" 'ANTERIOR a los cambios' "$d"
rm -rf "$d"

# No-ops: sin ellos el hook sería ruido en cada turno de cualquier repo.
d=$(cov_repo cobertura); ( cd "$d" && git add -A && git -c user.email=t@t -c user.name=t commit -qm x ) >/dev/null 2>&1
salida=$(printf '{}' | env "CLAUDE_PROJECT_DIR=$d" "$COV" 2>/dev/null)
if [[ -z "$salida" ]]; then ok "no-op sin cambios en el turno"; else ko "no-op sin cambios: dijo algo"; fi
rm -rf "$d"
# Sin informe hay DOS comportamientos correctos y distintos, y confundirlos es el bug:
# el repo que no mide cobertura no debe oír hablar del tema nunca; el que la mide pero no
# la vuelca a fichero tiene que enterarse, o creerá que el hook está roto.
d=$(mktemp -d)
( cd "$d" && git init -q . && printf 'x\n' > a.tf && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm b && printf 'y\n' >> a.tf ) >/dev/null 2>&1
salida=$(printf '{}' | env "CLAUDE_PROJECT_DIR=$d" "$COV" 2>/dev/null)
if [[ -z "$salida" ]]; then ok "repo que no mide cobertura: silencio total"; else ko "repo sin cobertura: dijo algo"; fi
rm -rf "$d"

d=$(mktemp -d)
( cd "$d" && git init -q . && printf '[tool.coverage.run]\nsource = ["src"]\n' > pyproject.toml \
  && printf 'x\n' > a.py && git add -A && git -c user.email=t@t -c user.name=t commit -qm b \
  && printf 'y\n' >> a.py ) >/dev/null 2>&1
cov_dice "mide cobertura sin volcarla: lo diagnostica en vez de callar" 'no deja informe en fichero' "$d"
cov_dice "y dice el flag exacto que falta" 'cov-report=xml' "$d"
rm -rf "$d"

salida=$(printf '{}' | env "CLAUDE_PROJECT_DIR=$tmp" "$COV" 2>/dev/null)
if [[ -z "$salida" ]]; then ok "no-op en repo sin git ni informe"; else ko "no-op: dijo algo"; fi

head_ "Ningún hook resuelve el proyecto con CLAUDE_PROJECT_DIR a secas"
# En un worktree, CLAUDE_PROJECT_DIR apunta a la copia principal (issue #2): un hook nuevo
# que haga `cd "$CLAUDE_PROJECT_DIR"` vuelve a meter el bug, y en uno que formatea, a
# tocar ficheros de otra copia de trabajo. El único que la lee es hooks/lib/dir-proyecto.sh,
# que el glob hooks/*.sh no incluye. Los comentarios no cuentan: los hooks explican por
# qué no la usan. Control positivo, como en el de confidence: un patrón que no casa nada
# pasaría igual que uno correcto.
PDIR_RE='^[^#]*\$\{?CLAUDE_PROJECT_DIR'
printf 'cd "${CLAUDE_PROJECT_DIR:-.}"\n' > "$tmp/pdir-control.sh"
if grep -qE "$PDIR_RE" "$tmp/pdir-control.sh"; then ok "el patrón caza un cd a CLAUDE_PROJECT_DIR"
else ko "el patrón no caza ni el control positivo: está roto, no hay nada verificado"; fi
malos=$(grep -nE "$PDIR_RE" hooks/*.sh 2>/dev/null || true)
if [[ -z "$malos" ]]; then ok "todos pasan por hooks/lib/dir-proyecto.sh"
else ko "CLAUDE_PROJECT_DIR a secas (usa hooks/lib/dir-proyecto.sh): $malos"; fi

head_ "Smoke: sesión en un git worktree"
# El caso del issue #2. La doc de worktrees lo deja así a propósito: CLAUDE_PROJECT_DIR
# «stays put» en la copia principal y el worktree solo llega por el `cwd` del JSON. Cada
# repo de pega tiene la copia principal Y un worktree en .claude/worktrees/, donde los deja
# Claude Code, y cada caso pone en los dos cosas DISTINTAS: si el hook mirase la principal,
# la salida lo delataría. Sin eso, un test que pasa no distingue un arreglo de una suerte.
DIRP=$PWD/hooks/lib/dir-proyecto.sh
wt_repo() { # crea <d>/main con un worktree en <d>/main/.claude/worktrees/wt e imprime <d>
  local d; d=$(mktemp -d)
  ( cd "$d" && git init -q main && cd main && mkdir -p src infra backend \
    && printf '.claude/worktrees/\n' > .gitignore \
    && printf 'def a():\n    return 1\n' > src/foo.py \
    && printf 'resource "azurerm_resource_group" "rg" {\n  name = "x"\n}\n' > infra/main.tf \
    && printf '[project]\nname = "x"\n\n[tool.ruff]\n' > pyproject.toml \
    && printf 'x\n' > backend/README \
    && git add -A && git -c user.email=t@t -c user.name=t commit -qm base \
    && git worktree add -q .claude/worktrees/wt ) >/dev/null 2>&1
  printf '%s' "$d"
}
# El helper devuelve la raíz que da git, con los symlinks resueltos (/tmp en macOS es
# /private/tmp): la esperada se calcula igual, o el test fallaría solo en un Mac.
wt_de() { (cd "$1/main/.claude/worktrees/wt" && pwd -P); }
dirp() { # dirp <descripción> <esperado> <CLAUDE_PROJECT_DIR> <json>
  local got; got=$(printf '%s' "$4" | env "CLAUDE_PROJECT_DIR=$3" "$DIRP" 2>/dev/null)
  if [[ "$got" == "$2" ]]; then ok "$1"; else ko "$1: esperado $2, obtenido ${got:-(vacío)}"; fi
}

d=$(wt_repo); M=$d/main; W=$(wt_de "$d")
mkdir -p "$d/otro" && git -C "$d/otro" init -q
dirp "sesión normal: CLAUDE_PROJECT_DIR tal cual, sin normalizar" "$M" "$M" "{\"cwd\":\"$M\"}"
dirp "sesión normal con cwd en un subdirectorio: igual"            "$M" "$M" "{\"cwd\":\"$M/src\"}"
dirp "worktree: su raíz"                                           "$W" "$M" "{\"cwd\":\"$W\"}"
dirp "cwd en un subdirectorio del worktree: la raíz del worktree"  "$W" "$M" "{\"cwd\":\"$W/src\"}"
dirp "proyecto en un subdirectorio: el mismo, dentro del worktree" "$W/backend" "$M/backend" "{\"cwd\":\"$W\"}"
# El cwd «moves again when Claude runs cd» (doc): seguirlo a otro repo haría que un hook
# que formatea tocase un repo que no es el proyecto.
dirp "cwd en OTRO repo: no lo sigue"                               "$M" "$M" "{\"cwd\":\"$d/otro\"}"
dirp "cwd fuera de git: CLAUDE_PROJECT_DIR"                        "$M" "$M" "{\"cwd\":\"$d\"}"
dirp "sin cwd en la entrada: CLAUDE_PROJECT_DIR"                   "$M" "$M" '{}'
rm -rf "$d"

# coverage-report: el caso exacto del issue. Mismo cambio en las dos copias, informes con
# cifras distintas: 0% del diff en la principal, 50% en el worktree.
cov_wt() { # cov_wt <descripción> <patrón esperado> <cwd>
  local salida; salida=$(printf '{"cwd":"%s"}' "$3" | env "CLAUDE_PROJECT_DIR=$M" "$COV" 2>/dev/null)
  if printf '%s' "$salida" | grep -q "$2"; then ok "$1"; else ko "$1: salida = ${salida:-(vacía)}"; fi
}
cov_xml() { # cov_xml <hits línea 4> <hits línea 5>
  printf '%s\n' '<coverage><packages><package><classes><class filename="src/foo.py"><lines>' \
    "<line number=\"1\" hits=\"1\"/><line number=\"2\" hits=\"1\"/><line number=\"4\" hits=\"$1\"/><line number=\"5\" hits=\"$2\"/>" \
    '</lines></class></classes></package></packages></coverage>'
}
d=$(wt_repo); M=$d/main; W=$(wt_de "$d")
for c in "$M" "$W"; do printf '\ndef b():\n    return 2\n' >> "$c/src/foo.py"; done
cov_xml 0 0 > "$M/coverage.xml"; cov_xml 1 0 > "$W/coverage.xml"
cov_wt "control: con cwd en la principal lee el de la principal" '0% de lo nuevo'  "$M"
cov_wt "con cwd en el worktree lee el informe del worktree"      '50% de lo nuevo' "$W"
# La otra cara: con la principal limpia, el hook antiguo callaba aunque el worktree
# tuviera cambios (su guarda `git diff HEAD --quiet` miraba la principal).
git -C "$M" checkout -q -- src/foo.py
cov_wt "principal limpia y worktree con cambios: habla"          '50% de lo nuevo' "$W"
rm -rf "$d"

# plan-invariantes-drift: alta de recurso solo en el worktree.
d=$(wt_repo); M=$d/main; W=$(wt_de "$d")
printf 'resource "azurerm_storage_account" "sa" {\n  name = "y"\n}\n' >> "$W/infra/main.tf"
hook_exit 2 "drift: alta de resource en el worktree, principal limpia" "$DRIFT" \
  "{\"stop_hook_active\":false,\"cwd\":\"$W\"}" "CLAUDE_PROJECT_DIR=$M"
hook_exit 0 "drift: control, con cwd en la principal no hay nada" "$DRIFT" \
  "{\"stop_hook_active\":false,\"cwd\":\"$M\"}" "CLAUDE_PROJECT_DIR=$M"
rm -rf "$d"

# Los tres que ESCRIBEN: aquí el bug no era una cifra mala, era formatear otra copia de
# trabajo. Stubs de terraform y uv que apuntan desde dónde y sobre qué se les llama.
d=$(wt_repo); M=$d/main; W=$(wt_de "$d")
mkdir -p "$d/stub"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$(pwd -P)" "$*" >> "$STUB_LOG"\n' > "$d/stub/uv"
cp "$d/stub/uv" "$d/stub/terraform"; chmod +x "$d/stub/uv" "$d/stub/terraform"
stub_log_es() { # stub_log_es <descripción> <primera línea esperada>
  local primera; primera=$(head -1 "$d/log" 2>/dev/null)
  if [[ "$primera" == "$2" ]] && ! grep -q "^$M|" "$d/log" 2>/dev/null; then ok "$1"
  else ko "$1: log = $(tr '\n' ' ' < "$d/log" 2>/dev/null)"; fi
  rm -f "$d/log"
}
# Cambios distintos en cada copia: el hook antiguo habría formateado src/solo_main.py.
printf 'y = 2\n' > "$M/src/solo_main.py"
printf 'z = 3\n' >> "$W/src/foo.py"
hook_exit 0 "ruff-fix-on-stop en un worktree" "$PWD/hooks/ruff-fix-on-stop.sh" \
  "{\"stop_hook_active\":false,\"cwd\":\"$W\"}" "CLAUDE_PROJECT_DIR=$M" "PATH=$d/stub:$PATH" "STUB_LOG=$d/log"
stub_log_es "ruff-fix-on-stop formatea los .py del worktree, no los de la principal" "$W|run ruff format src/foo.py"
hook_exit 0 "ruff-on-edit en un worktree" "$PWD/hooks/ruff-on-edit.sh" \
  "{\"tool_input\":{\"file_path\":\"$W/src/foo.py\"},\"cwd\":\"$W\"}" "CLAUDE_PROJECT_DIR=$M" "PATH=$d/stub:$PATH" "STUB_LOG=$d/log"
stub_log_es "ruff-on-edit corre uv desde el worktree" "$W|run ruff format $W/src/foo.py"
hook_exit 0 "terraform-fmt-on-stop en un worktree" "$PWD/hooks/terraform-fmt-on-stop.sh" \
  "{\"cwd\":\"$W\"}" "CLAUDE_PROJECT_DIR=$M" "PATH=$d/stub:$PATH" "STUB_LOG=$d/log"
stub_log_es "terraform-fmt-on-stop formatea el infra/ del worktree" "$W|-chdir=infra fmt -recursive"
rm -rf "$d"

head_ "Smoke: postgres-mcp-launcher"
LAUNCHER=scripts/postgres-mcp-launcher.sh
expect_exit 1 "sin URL: falla con mensaje accionable" "$LAUNCHER" PROD
expect_exit 1 "literal \${VAR} sin expandir y sin env" env -u DATABASE_URL_PROD "$LAUNCHER" PROD '${DATABASE_URL_PROD}'
# Stub de uvx para no arrancar postgres-mcp de verdad en la ruta feliz.
mkdir -p "$tmp/stub" && printf '#!/bin/sh\necho "$@"\n' > "$tmp/stub/uvx" && chmod +x "$tmp/stub/uvx"
PATH="$tmp/stub:$PATH" expect_exit 0 "ruta feliz con URL por argumento" "$LAUNCHER" DEV 'postgresql://x'
# El fallback por entorno es la razón de ser del launcher en headless (`claude -p`,
# donde el env de settings NO llega a la expansión de ${VAR} del .mcp.json).
PATH="$tmp/stub:$PATH" DATABASE_URL_DEV='postgresql://envx' \
  expect_exit 0 "fallback headless: literal sin expandir + variable en el entorno" \
  "$LAUNCHER" DEV '${DATABASE_URL_DEV}'

printf '\n'
if [[ $fails -eq 0 ]]; then
  printf '\033[32mTodo OK.\033[0m\n'
else
  printf '\033[31m%d comprobación(es) fallida(s).\033[0m\n' "$fails"
fi
exit $(( fails > 0 ))
