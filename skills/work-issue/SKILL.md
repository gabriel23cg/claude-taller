---
name: work-issue
description: Arranca el trabajo sobre un issue con todo su contexto antes de tocar código - cuerpo Y comentarios, los campos nativos de la organización que gh no muestra, issues enlazados, y si ya hay rama o PR abierto. Termina con los supuestos y las preguntas explícitas, y encadena con /check-work y /open-pr. Es dueña de .claude/flujo-github.md, donde cachea las convenciones del repo. Úsala cuando se pida implementar, resolver, arreglar, hacer, abordar, empezar, atacar, trabajar en o ponerse con un issue o un #N, tanto si es uno como si son varios.
disable-model-invocation: false
---

# /work-issue — Abordar un issue con su contexto real

El fallo caro no es implementar mal: es implementar lo que decía el **título** del issue
mientras el acuerdo real estaba en el comentario cuarto. Esta skill reúne el contexto antes
de escribir nada, y deja explícito lo que el issue **no** dice.

No implementa, no revisa y no mergea: prepara el terreno. Viene de `/triage` y encadena con
`/check-work` → `/open-pr`.

## Paso 0 — Las convenciones del repo, del repo (no de tu memoria)

Este plugin corre en repos que no conoce. Lo que cambia de uno a otro —cómo se llaman las
ramas, qué labels son obligatorias, con qué se valida, qué agentes revisan, cómo se
mergea— vive en **`.claude/flujo-github.md` del repo**, y **esta skill es su dueña**: lo
lees si existe, lo creas si no, y lo corriges cuando descubras que miente.

Si existe, léelo y salta al paso 1. Si no, **descúbrelo y escríbelo** (una vez por repo,
sale gratis a partir de la segunda). De dónde sale cada cosa:

| Sección | Dónde mirar |
|---|---|
| Rama base | `gh repo view --json defaultBranchRef` |
| Convención de nombre de rama | `git branch -a` + las ramas de PRs recientes (`gh pr list --state all --json headRefName`) |
| Labels obligatorias | `CONTRIBUTING.md`, `gh label list`, las labels de los últimos PRs mergeados |
| Validación | ver `/check-work` paso 2: `CLAUDE.md`, `Makefile`, y sobre todo `.github/workflows/` |
| Agentes de revisión | `ls .claude/agents/` + `ls "${CLAUDE_PLUGIN_ROOT}/agents/"` |
| Política de merge | `CONTRIBUTING.md`, o el método de los últimos merges (`gh pr list --state merged`) |
| Señales de prioridad | ver el paso 2 de esta skill |

Forma canónica del fichero (esta es la referencia; si la cambias, cámbiala aquí):

```markdown
# Flujo de trabajo de este repo

Fichero descubierto y mantenido por la skill `work-issue` del plugin. Corrígelo a mano si
miente: manda el fichero, no lo que el plugin vuelva a deducir.

## Base y ramas
- Rama base: `main`
- Convención: `issue-<N>-descripcion-corta`

## Labels
- Issues: al menos una `area:*`
- PRs: al menos una `area:*` y una de tipo

## Validación antes de abrir PR
`pytest -q && ruff check .`  (el gate real es `.github/workflows/ci.yml`)

## Agentes de revisión
- `nombre-del-agente` — cuándo aplica

## Política de merge
Squash + borrar rama. Nunca autónomo: lo confirma el usuario.

## Señales de prioridad
Campos nativos de la organización: `Priority`, `Effort`.
```

Secciones sin dato fiable: escríbelas como `(sin declarar)`. Un hueco honesto es mejor que
una convención inventada que luego alguien sigue.

## Si te dan varios issues: el reparto se evalúa, no se presupone

«Implementa el 12, el 14 y el 15» puede ser tres trabajos o uno solo mal troceado, y eso no
se sabe desde el título. **No lo decidas por regla**: ni «siempre un PR por issue» ni «todo
junto que va más rápido».

1. **Lanza el agente `backlog-triage` en modo agrupación** con el conjunto. Lee los issues
   enteros, mira qué zona del código toca cada uno y devuelve un reparto en PRs con su
   razón. Va en contexto aislado a propósito: leer tres issues completos para decidir una
   cosa es justo lo que no debe comerse tu ventana.

2. **Pon la propuesta delante del usuario y espera.** El reparto tiene consecuencias que ni
   tú ni el agente veis —quién revisa, qué hay a medias en otra rama, qué se prometió para
   cuándo—, así que **manda el usuario**. Preséntalo corto: qué PR cierra qué, por qué, y
   en qué orden.

3. **Con el reparto confirmado**, cada grupo recorre el ciclo entero —contexto, rama,
   implementación, `/check-work`, `/open-pr`, `/land-pr`— antes de empezar el siguiente. Un
   grupo, un PR, y en ese PR **un `Closes #N` por cada issue que cierre**.

El criterio con el que el agente decide, por si tienes que discutirlo: **¿se pueden revertir
por separado?** Si revertir uno sin tocar el otro es un `git revert` limpio, son dos PRs; si
revertir uno deja al otro roto, ya son un solo cambio y separarlos produce un commit que ni
compila. Y como segunda prueba: si el cuerpo del PR tiene que empezar con «esto hace tres
cosas no relacionadas», eran tres PRs.

Cuando el grupo lleva más de un issue, esto cambia aguas abajo y no es automático:

- la **rama** no puede llamarse como uno solo de ellos (`/open-pr` lo trata),
- **`/check-work` contrasta contra TODOS** los issues del grupo, no contra el primero,
- **`/land-pr` verifica que se cerraron todos**, no que se cerró alguno.

## Paso 1 — Leer el issue entero, comentarios incluidos

Una sola llamada:

```bash
gh issue view <N> --json number,title,state,body,comments,issueType,labels,assignees,parent,subIssues,blockedBy,blocking,closedByPullRequestsReferences
```

(en una sola línea: partirla con `\` mete los espacios de la indentación en la lista de
campos y `gh` la rechaza. Si tu versión de `gh` no conoce algún campo, quítalo y repite: el
juego disponible depende de la versión y de si el repo tiene issue types.)

Los **comentarios no son opcionales**: es donde vive el cambio de criterio («esto al final
no, mejor X»). Resumir el issue sin leerlos es la forma habitual de reabrirlo.

Para y pregunta si: `state` no es `OPEN`, `assignees` tiene a otra persona, o `blockedBy`
trae algo abierto (trabajarlo ahora es trabajarlo dos veces).

## Paso 2 — Los campos de la organización, si los hay

Muchas organizaciones ponen la prioridad y el esfuerzo en **campos nativos de issue**: son
de la organización, un issue los tiene sin estar en ningún proyecto, y `gh issue view
--json` **no los expone**. Van por GraphQL:

```bash
OWNER=$(gh repo view --json owner --jq .owner.login); REPO=$(gh repo view --json name --jq .name)
gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ issue(number:$n){
    issueFieldValues(first:20){ nodes{
      ... on IssueFieldSingleSelectValue { field { ... on IssueFieldSingleSelect { name } } value }
    } } } } }' -F o="$OWNER" -F r="$REPO" -F n=<N> \
  --jq '[.data.repository.issue.issueFieldValues.nodes[]? | select(.field.name) | "\(.field.name)=\(.value)"] | join(" ")'
```

Vacío o error → la organización no usa estos campos. **Es lo normal y no es un fallo**: cae
a labels (`priority:*`, `P1`, `size:*`) o al milestone, y si tampoco hay, sigue sin ellos.

Cuando existe una señal de **esfuerzo**, decide el **modo de trabajo** — es un dato que
suele estar puesto y que no lee nadie:

- **bajo** → al grano: cambio localizado, sin plan previo.
- **medio** → plan corto (3-6 pasos) antes de tocar código.
- **alto** → plan explícito y acordado; si además el issue es ambiguo, brainstorming antes
  del plan. Un esfuerzo alto en algo que parece de diez minutos es señal de que falta
  contexto, no de que el campo esté mal.

La **prioridad** no cambia el cómo, sí el **si ahora**: si es baja y hay algo urgente
abierto, dilo antes de empezar (y si la duda es real, eso es `/triage`).

## Paso 3 — Comprobar que nadie está ya en esto

Ni otra persona, ni tú en otra sesión:

- `closedByPullRequestsReferences` del paso 1 lista los PRs enlazados. Si hay uno
  **abierto**, se continúa ahí: no se abre un segundo PR. Eso es `/land-pr`, no esta skill.
- Ramas existentes: `git fetch --prune && git branch -a --list "*<N>*"`.

## Paso 4 — Contexto relacionado: lo estructural siempre, la búsqueda solo con señal

`parent`, `subIssues`, `blockedBy` y `blocking` ya vienen del paso 1: son enlaces explícitos
y se leen siempre (cuestan cero).

La **búsqueda** de issues relacionados NO es un paso fijo — en un issue trivial solo añade
ruido y latencia. Hazla cuando haya señal: el cuerpo o los comentarios mencionan otro `#N`,
el título huele a duplicado de algo ya discutido, o el área tuvo incidentes recientes:

```bash
gh issue list --state all --search "<términos del título>" --json number,title,state
```

## Paso 5 — Decir qué NO dice el issue. Obligatorio, antes de implementar

Con un grupo de varios, esto se hace **una vez para el grupo entero**: los supuestos que
importan suelen estar justo en la costura entre un issue y otro.

Presenta:

- **Qué se va a hacer** (2-4 líneas, en los términos del issue + lo acordado en comentarios).
- **Supuestos** que rellenan huecos del issue, uno por línea. Nada de rellenar en silencio.
- **Preguntas** que de verdad bloquean la decisión (si no bloquean, es un supuesto).

Con esfuerzo medio o alto, esto va acompañado del plan del paso 2. Espera confirmación.

## Paso 6 — Rama desde la base al día

Con la convención del paso 0:

```bash
git checkout <base> && git pull --ff-only && git checkout -b <rama>
```

## Paso 7 — Encadenar

Implementado el cambio: **`/check-work`** (validación, agentes de revisión del repo,
relectura del diff, contraste con el issue) y, con su veredicto, **`/open-pr`**. No
reimplementes ninguna de las dos aquí. **Nunca mergees**: eso es `/land-pr`, y lo confirma
el usuario.

## Notas

- **No comentes en el issue** al empezar. Es una acción con efecto externo y, en equipos
  pequeños, ruido. Solo si el usuario lo pide.
- Esta skill **no revisa código**: eso son los agentes que declare el repo, vía
  `/check-work`.
- Cómo **escribir** los campos de la organización (prioridad, esfuerzo) está en la skill
  `gh-create-issue`, junto con la rúbrica para inferirlos.
- Si el issue resulta ser en realidad varios trabajos, dilo y propón trocearlo
  (`/gh-create-issue` para los nuevos) en vez de abrir un PR gigante.
- Si descubres que `.claude/flujo-github.md` dice algo que ya no es cierto, **corrígelo en
  el mismo cambio**: eres su dueña, no solo su lectora.
