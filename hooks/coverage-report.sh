#!/usr/bin/env bash
# Stop: muestra la cobertura del cambio en curso. NO corre los tests: lee el informe que
# ya exista en el repo.
#
# Por qué existe: la cobertura solo sirve si se ve sin pedirla. Pedirla es justo lo que no
# se hace el día que hay prisa, que es el día que importa.
#
# Por qué NO corre los tests: un Stop hook que lanza la suite con cobertura mete minutos al
# final de CADA turno. Eso no es un guardarraíl, es un hook que acabas desactivando. Este
# lee un informe ya generado (milisegundos) y, si está viejo, lo dice — que un informe
# desfasado es información, no un fallo.
#
# La cifra principal es la del DIFF, no la global. Un módulo nuevo de 200 líneas sin un
# solo test mueve un total de 20.000 líneas un 1%: la global no lo ve. La del diff sí, y es
# la que responde a "¿esto que acabo de escribir tiene tests?".
#
# NUNCA bloquea (exit 0 siempre). Un umbral que corta es como se aprende a escribir tests
# sin asserts para rellenar el número. Aquí la aritmética se muestra y el juicio —¿esta
# línea MERECE test?— lo da el agente de revisión, que es quien puede leer el test y ver si
# comprueba algo.
#
# Mecanismo: la salida al usuario va por `systemMessage` en JSON por stdout. En Stop, el
# stdout de un exit 0 va SOLO al log de depuración (verificado en la doc, 2026-09-18), así
# que un `echo` normal aquí no lo vería nadie. PostToolUse no vale para esto: descarta
# `systemMessage`.
#
# No-op agresivo: sin git, sin cambios, sin informe reconocible o sin datos, sale callado.
#
# Exit codes: 0 siempre (con o sin mensaje).

set -uo pipefail

# El directorio sale del `cwd` de la sesión, no de CLAUDE_PROJECT_DIR a secas: en un
# worktree, este apunta a la copia principal y el hook mediría el diff y el informe de otra
# copia de trabajo (issue #2; el porqué entero, en lib/dir-proyecto.sh).
input=$(cat 2>/dev/null || true)
dir=$(printf '%s' "$input" | "$(dirname "$0")/lib/dir-proyecto.sh")
cd "$dir" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Guarda barata: si el turno no tocó nada, no hay nada que contar.
git diff HEAD --quiet 2>/dev/null && exit 0

# --- Localizar el informe. Se descubre, no se declara: cada repo lo deja donde quiere. ---
informe=""; formato=""
for c in coverage.xml cobertura.xml coverage/cobertura-coverage.xml coverage/coverage.xml; do
  [[ -f "$c" ]] && { informe=$c; formato=cobertura; break; }
done
if [[ -z "$informe" ]]; then
  for c in coverage/lcov.info lcov.info coverage/lcov/lcov.info; do
    [[ -f "$c" ]] && { informe=$c; formato=lcov; break; }
  done
fi
# Sin informe: callar NO siempre es correcto. Si el repo mide cobertura pero no la vuelca a
# fichero (`--cov-report=term` y nada más), este hook no tendría nada que leer y el usuario
# se quedaría pensando que no funciona. Un fallo silencioso es peor que la falta: se
# diagnostica. Y solo se diagnostica cuando hay INTENCIÓN de medir — un repo que no mide
# cobertura (Terraform puro, por ejemplo) no tiene por qué oír hablar del tema nunca.
if [[ -z "$informe" ]]; then
  mide=""
  for f in pyproject.toml setup.cfg tox.ini .coveragerc pytest.ini; do
    [[ -f "$f" ]] && grep -qE 'pytest-cov|\[tool\.coverage|--cov|\[coverage:' "$f" 2>/dev/null \
      && { mide="python"; break; }
  done
  if [[ -z "$mide" && -f package.json ]]; then
    grep -qE '"(jest|vitest|nyc|c8)"|collectCoverage|--coverage' package.json 2>/dev/null && mide="js"
  fi
  [[ -n "$mide" ]] || exit 0
  if [[ "$mide" == python ]]; then
    receta='añade --cov-report=xml a la invocación de pytest (o cov_report = xml al [tool.coverage.run])'
  else
    receta='activa el reporter lcov de tu runner (coverageReporters/reporter incluyendo "lcov")'
  fi
  printf '{"systemMessage":"Cobertura: este repo la mide pero no deja informe en fichero, así que no hay nada que mostrar. Para verla en cada turno, %s."}\n' "$receta"
  exit 0
fi

# --- Normalizar a un stream `fichero<TAB>línea<TAB>hits` ---
tmp=$(mktemp) || exit 0
trap 'rm -f "$tmp"' EXIT

if [[ "$formato" == cobertura ]]; then
  # Recorre TODOS los <line> de cada línea de texto, no solo el primero: el XML puede venir
  # minificado o con varios elementos por línea, y quedarse con uno daría una cifra
  # optimista y silenciosa — el peor tipo de error en una métrica.
  awk '
    {
      resto = $0
      if (match(resto, /filename="[^"]*"/)) { f = substr(resto, RSTART+10, RLENGTH-11); sub(/^\.\//, "", f) }
      if (f == "") next
      while (match(resto, /<line[^>]*>/)) {
        el = substr(resto, RSTART, RLENGTH)
        resto = substr(resto, RSTART + RLENGTH)
        if (!match(el, /number="[0-9]+"/)) continue
        n = substr(el, RSTART+8, RLENGTH-9)
        if (!match(el, /hits="[0-9]+"/)) continue
        h = substr(el, RSTART+6, RLENGTH-7)
        print f "\t" n "\t" h
      }
    }' "$informe" > "$tmp" 2>/dev/null
else
  awk '
    /^SF:/ { f = substr($0, 4); sub(/^\.\//, "", f); next }
    /^DA:/ && f != "" {
      split(substr($0, 4), a, ",")
      if (a[1] != "" && a[2] != "") print f "\t" a[1] "\t" a[2]
    }' "$informe" > "$tmp" 2>/dev/null
fi
[[ -s "$tmp" ]] || exit 0

# --- Cruzar con las líneas que este cambio AÑADE ---
# --unified=0 quita el contexto, así que el rango `+c,d` de cada hunk son exactamente las
# líneas nuevas. Sin eso contaríamos como "añadidas" las tres líneas de contexto de around.
resumen=$(git diff HEAD --unified=0 2>/dev/null | awk -v covfile="$tmp" '
  BEGIN {
    FS = "\t"
    while ((getline linea < covfile) > 0) {
      split(linea, p, "\t")
      cov[p[1] SUBSEP p[2]] = p[3]
      ficheros[p[1]] = 1
      total++; if (p[3] + 0 > 0) cubiertas++
    }
    close(covfile)
    FS = " "
  }
  # Resolver la ruta del diff contra las del informe: coinciden exacto, o una es sufijo de
  # la otra (el informe puede traer rutas absolutas, o relativas a un src/ distinto).
  # OJO con el sufijo: index() devuelve 0 cuando NO encuentra, y si las dos rutas miden lo
  # mismo, length(c)-length(d) también es 0 -> 0==0 y empareja cualquier cosa. Es cómo un
  # `pyproject.toml` acababa contando como si fuera un fichero de código de 14 caracteres.
  # De ahí el length(...) > length(...): obliga a que la posición esperada sea >= 1.
  function resolver(d,   c) {
    if (d in ficheros) return d
    if (d in cache) return cache[d]
    for (c in ficheros) {
      if (c == d \
          || (length(c) > length(d) && index(c, "/" d) == length(c) - length(d)) \
          || (length(d) > length(c) && index(d, "/" c) == length(d) - length(c))) {
        cache[d] = c; return c
      }
    }
    cache[d] = ""; return ""
  }
  /^\+\+\+ b\// { df = substr($0, 7); cf = resolver(df); next }
  /^@@ / && cf != "" {
    split($3, r, ",")               # $3 es "+c" o "+c,d"
    ini = substr(r[1], 2) + 0
    n = (r[2] == "" ? 1 : r[2] + 0)
    for (i = 0; i < n; i++) {
      k = cf SUBSEP (ini + i)
      if (k in cov) { medibles++; if (cov[k] + 0 > 0) nuevas_cubiertas++ }
    }
  }
  END { printf "%d %d %d %d", medibles + 0, nuevas_cubiertas + 0, total + 0, cubiertas + 0 }
')

set -- $resumen
medibles=${1:-0}; nuevas_cubiertas=${2:-0}; total=${3:-0}; cubiertas=${4:-0}

[[ "$total" -gt 0 ]] || exit 0
global=$(( cubiertas * 100 / total ))

# --- ¿El informe es anterior a los cambios? Entonces la cifra no es de este código. ---
frescura=""
mas_nuevo=$(git diff HEAD --name-only 2>/dev/null | while IFS= read -r f; do
  [[ -f "$f" ]] && printf '%s\n' "$f"
done | xargs -r ls -t 2>/dev/null | head -1)
if [[ -n "$mas_nuevo" && "$mas_nuevo" -nt "$informe" ]]; then
  frescura=" · ⚠ el informe es ANTERIOR a los cambios: vuelve a correr los tests"
fi

if [[ "$medibles" -gt 0 ]]; then
  diffpct=$(( nuevas_cubiertas * 100 / medibles ))
  sin_cubrir=$(( medibles - nuevas_cubiertas ))
  if [[ "$sin_cubrir" -gt 0 ]]; then
    detalle="${diffpct}% de lo nuevo (${sin_cubrir} línea(s) añadida(s) sin cubrir)"
  else
    detalle="${diffpct}% de lo nuevo"
  fi
else
  # Cambio sin líneas instrumentadas: documentación, configuración, o ficheros que el
  # informe no incluye. Decirlo evita leer el silencio como "todo cubierto".
  detalle="lo añadido no aparece en el informe (docs, config, o fuera de su alcance)"
fi

printf '{"systemMessage":"Cobertura: %s · global %d%% (%s)%s"}\n' \
  "$detalle" "$global" "$informe" "$frescura"
exit 0
