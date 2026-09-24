---
name: gh-create-issue
description: Crea un issue bien formado - con su tipo si el repo los usa y, si la organización define campos nativos de issue (prioridad, esfuerzo), SIEMPRE con valor, infiriéndolo del contenido cuando el usuario no lo diga. Empaqueta la receta de setIssueFieldValue porque gh no tiene flag para esos campos, y descubre los IDs en runtime en vez de traerlos escritos. Úsala para crear issues, trocear trabajo en issues o registrar algo visto de paso.
disable-model-invocation: false
---

# /gh-create-issue — Crear un issue que el triage pueda ordenar

Lo que no está en el backlog no existe, y lo que está sin prioridad ni esfuerzo no se puede
ordenar: es ruido que alguien tendrá que clasificar después, normalmente nunca. Esta skill
crea el issue **y lo deja clasificable**.

Alimenta el ciclo: lo que se crea aquí es lo que `/triage` lee después.

## Paso 1 — Qué campos tiene este repo. Descúbrelo, no lo supongas.

Hay tres cosas distintas y conviene no confundirlas:

- **Issue types** (`Task`/`Bug`/`Feature`…): de la organización, se ponen con `--type`.
- **Campos nativos de issue** (prioridad, esfuerzo, fechas): también de la organización; un
  issue los tiene **sin estar en ningún proyecto**, y `gh` **no tiene flag** para ellos.
- **Campos de Project**: cosa aparte, requieren que el issue esté en el proyecto. Esta
  skill no los toca.

Si `.claude/flujo-github.md` (lo mantiene `/work-issue`) ya trae los nombres y los IDs en su
sección de señales de prioridad, úsalos y salta al paso 2. Si no, resuélvelos:

```bash
OWNER=$(gh repo view --json owner --jq .owner.login)

# ¿la organización define campos nativos de issue?
gh api graphql -f query='query($o:String!){ organization(login:$o){ issueFields(first:50){ nodes{
  ... on IssueFieldSingleSelect{ id name options{ id name } }
  ... on IssueFieldDate{ id name } } } } }' -F o="$OWNER"

# ¿y issue types?
gh api graphql -f query='query($o:String!){ organization(login:$o){ issueTypes(first:20){ nodes{ name } } } }' -F o="$OWNER"
```

**Vacío o error es el caso normal**, no un fallo: la mayoría de organizaciones no usa nada
de esto (y en un repo de usuario, no de organización, directamente no existe). Entonces el
issue se crea con `gh issue create` a secas y los pasos 3 y 4 no aplican — si el repo
transmite la prioridad por labels (`priority:*`, `P1`, `size:*`), úsalas en su lugar.

**Si los has resuelto, anótalos en `.claude/flujo-github.md`**: son estables y así la
próxima vez no hay que volver a preguntarle a la API.

## Paso 2 — Recoger del usuario

- **Título** (obligatorio, corto, imperativo).
- **Cuerpo** (obligatorio; acepta heredoc / multilínea). Un issue sin criterio de
  aceptación es un issue que se discutirá dos veces: escribe qué significa «hecho».
- **Tipo**, si el repo los usa.
- **Labels** según la convención del repo (`.claude/flujo-github.md`, su `CONTRIBUTING.md`,
  o `gh label list`).
- **Prioridad / esfuerzo**: si el usuario no los da, **no los preguntes** — infiérelos con
  la rúbrica de abajo y anuncia qué has inferido. Si los da, manda el usuario.

## Paso 3 — Crear el issue

`gh issue create` soporta `--type` de forma nativa (desde gh 2.72). El cuerpo por heredoc
para preservar los saltos:

```bash
URL=$(gh issue create \
  --title "<título>" \
  --type "<tipo>" \
  --label "<labels coma-separadas>" \
  --body "$(cat <<'BODY'
<cuerpo>
BODY
)")
ISSUE_ID=$(gh issue view "$URL" --json id -q .id)
```

Sin issue types en la organización, quita `--type`. Para cambiarlo después:
`gh issue edit <n> --type Bug` / `--remove-type`.

## Paso 4 — Poner los campos nativos

`setIssueFieldValue` acepta una **lista**: todos los campos van en UNA llamada, con los IDs
del paso 1.

```bash
gh api graphql -f query='
mutation($issueId: ID!, $a: ID!, $b: ID!) {
  setIssueFieldValue(input: { issueId: $issueId, issueFields: [
    { fieldId: "<id del campo de prioridad>", singleSelectOptionId: $a,
      rationale: "<por qué esta prioridad, máx 280 chars>", confidence: HIGH },
    { fieldId: "<id del campo de esfuerzo>", singleSelectOptionId: $b,
      rationale: "<por qué este esfuerzo>", confidence: HIGH }
  ]}) { issue { number url } }
}' -f issueId="$ISSUE_ID" -f a='<option-id>' -f b='<option-id>'
```

Semántica, que no es obvia y muerde:

- **`confidence` SIEMPRE `HIGH`.** Con `rationale` y `confidence: MEDIUM`, el campo **no se
  guarda y la mutación NO da error**: responde como si hubiera ido bien y el issue se queda
  sin el valor (observado en producción, 2026-09-23: dos issues perdieron su esfuerzo así).
  Encaja con lo de `suggest` de abajo — todo lo que no sea una afirmación en firme parece
  acabar en la cola de sugerencias en vez de aplicarse.
- **NUNCA pases `suggest: true`**: el valor quedaría como *sugerencia pendiente* de revisión
  humana en vez de aplicarse. Esta skill aplica valores de verdad.
- **`setIssueFieldValue` es upsert de lo que listas y no toca lo omitido.** Úsalo siempre:
  `createIssueFieldValue` falla si el valor ya existe y `updateIssueFieldValue` falla si no
  existe.
- Selecciona `url` en la respuesta (no solo `number`): es lo que permite al hook
  `issue-fields-reminder` reconocer qué issue se tocó y comprobar que el valor aterrizó.
- Para campos de fecha, el input es `date: "YYYY-MM-DD"` en vez de `singleSelectOptionId`.
- Para editar los campos de un issue que ya existe: este mismo paso con su `ISSUE_ID`.

### Verifica que aterrizó. No te fíes de que la mutación responda bien.

Es el paso que faltaba cuando esto mordió: la mutación devolvió `issue { number }` tan
contenta y el campo estaba vacío. Una escritura que puede fallar en silencio hay que
**releerla**:

```bash
gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ issue(number:$n){
    issueFieldValues(first:20){ nodes{
      ... on IssueFieldSingleSelectValue { field { ... on IssueFieldSingleSelect { name } } value }
    } } } } }' -F o="$OWNER" -F r="$REPO" -F n=<N> \
  --jq '[.data.repository.issue.issueFieldValues.nodes[]? | select(.field.name) | "\(.field.name)=\(.value)"] | join(" ")'
# -> Priority=High Effort=Low   (si falta alguno, NO se guardó: repítelo)
```

## Paso 5 — Confirmar

URL + número + tipo + campos asignados, marcando **explícitamente cuáles has inferido tú**.
Una inferencia anunciada se corrige en un clic; una silenciosa se queda para siempre.

## Rúbrica de inferencia

Vale con cualquier nomenclatura (`Priority`/`Prioridad`/`Severity`, `Effort`/`Size`/
`Estimate`): lo que importa es el eje, no el nombre.

**Prioridad** — impacto si no se hace, no ganas de hacerlo:

- **la más alta** (`Urgent`/`P0`): producción rota, pérdida de datos en curso, credencial
  expuesta. Se deja lo demás.
- **alta**: bloquea a otra persona o a otro repo; riesgo de seguridad sin explotar; deuda
  que va a doler ya.
- **media** (*default razonable*): mejora clara, sin bloqueo ni riesgo inmediato.
- **baja**: cosmético, nice-to-have, idea a futuro.

**Esfuerzo** — trabajo hasta tenerlo mergeado y verificado, no hasta la primera línea:

- **bajo**: cambio localizado, un repo, sin migración ni coordinación.
- **medio** (*default razonable*): varios ficheros o repos, tests nuevos, revisión de infra.
- **alto**: migración de datos, cambio entre repos con orden de despliegue, o diseño abierto.

Ante la duda, medio/medio: es un dato corregible en un clic, no una decisión que convenga
dejar vacía. Pon el *porqué* en `rationale` — es lo que hace la inferencia auditable en vez
de un adorno.

## Notas

- El hook `issue-fields-reminder` de este plugin cubre el camino de al lado (crear el issue
  con `gh` a pelo): si la organización define campos y el issue nace sin ellos, avisa con la
  mutación lista. La regla «ningún issue sin clasificar» no depende de acordarse de la skill.
- Filtrar por campo nativo (el qualifier `priority:` de búsqueda **no** funciona):
  ```bash
  gh api graphql -f query='query($o:String!,$r:String!){ repository(owner:$o,name:$r){
    issues(first:20, filterBy:{issueFieldValues:[{fieldName:"Priority", singleSelectOptionValue:"High"}]}){
      nodes{ number title } } } }' -F o="$OWNER" -F r="$REPO"
  ```
- También se puede crear el issue con los campos en un solo paso (`createIssue` acepta
  `issueFields`), pero exige node IDs para repo, labels y assignees. La receta de dos pasos
  es la práctica.
