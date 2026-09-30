# taller

Plugin de Claude Code con el **ciclo de trabajo sobre GitHub** —del triage del backlog al
PR mergeado y vuelta— más los hooks de guardarraíl, los agentes de revisión y los MCP que
lo sostienen, para proyectos con **infra en Azure con Terraform y Postgres con Alembic**.
Este repo es a la vez marketplace y plugin: un fix aquí llega a todos los repos
consumidores.

**Los datos no vienen escritos**: no trae dentro ninguna organización, ningún repo ni ningún ID.
Lo que cambia de un repo a otro —convención de ramas, labels obligatorias, comando de
validación, campos de issue de la organización, política de merge— lo **descubre en
runtime** y lo cachea en `.claude/flujo-github.md` del propio repo, del que la skill
`work-issue` es dueña. Un repo nuevo funciona sin configurar nada.

**Las opiniones sí**: el apply de Terraform solo por CI, prod de solo lectura, la BD en UTC
y `COMMENT` en español en todo objeto de esquema son política del plugin, iguales en todos
los proyectos. Un repo puede endurecerlas en su fichero de invariantes, no relajarlas.

Lo específico de un proyecto (su dominio, sus secretos, sus skills de operación) **no** vive
aquí: se queda en el `.claude/` de ese repo.

## El ciclo

```
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  ▼                                                                          │
/triage ──▶ /work-issue ──▶ implementar ──▶ /check-work ──▶ /open-pr ──▶ /land-pr
  ▲                                                                          
  └── /gh-create-issue alimenta el backlog (desde cualquier punto del ciclo)
```

| Skill | Pregunta que responde | Termina en |
|---|---|---|
| `/triage` | ¿Por dónde sigo? | un issue elegido |
| `/work-issue` | ¿Qué pide de verdad este issue, y qué no dice? | supuestos, plan y rama |
| `/check-work` | ¿Esto está listo? | veredicto LISTO / CON RESERVAS / NO LISTO |
| `/open-pr` | — | PR abierto, enlazado y etiquetado |
| `/land-pr` | ¿Qué le falta a este PR? | PR mergeado, issue cerrado, de vuelta al triage |
| `/gh-create-issue` | — | issue creado y clasificable |

## Qué aporta

### Hooks (`hooks/hooks.json`)

| Hook | Evento | Qué hace | No-op cuando |
|---|---|---|---|
| `block-terraform-apply.sh` | PreToolUse (Bash) | Bloquea `terraform apply\|destroy` en local: el apply corre solo por CI (dispatch con `plan_run_id`). Exime `bootstrap`. | — |
| `ruff-on-edit.sh` | PostToolUse (Edit/Write) | `ruff format` sobre el `.py` editado (solo formato, nunca autofix). | El pyproject no declara `[tool.ruff]` |
| `ruff-fix-on-stop.sh` | Stop | `ruff format` + `ruff check --fix` sobre los `.py` cambiados vs HEAD; exit 2 si quedan issues no-autofixables (solo bloquea una vez por Stop: respeta `stop_hook_active` para no entrar en bucle). | El pyproject no declara `[tool.ruff]` |
| `terraform-fmt-on-stop.sh` | Stop | `terraform -chdir=infra fmt -recursive`. | No hay `infra/` o no hay terraform |
| `issue-fields-reminder.sh` | PostToolUse (Bash) | Tras un `gh issue create` **o un `setIssueFieldValue`**, relee el issue y comprueba que quedó con los campos nativos que defina la organización; si falta alguno, exit 2 con la mutación y los IDs **ya resueltos en runtime**. Cubre el camino de crear issues sin la skill y, al releer tras la mutación, caza también la escritura que responde OK y no guarda. | El comando no es ninguno de los dos, la organización no define esos campos (el caso mayoritario), o la consulta a la API falla |
| `pr-closes-issue-check.sh` | PostToolUse (Bash) | Tras un `gh pr create`, si el cuerpo trae intención de cierre (keyword pegado a un `#N`) pero `closingIssuesReferences` viene vacío, exit 2 con la causa probable. Es el hermano del anterior para PRs. | El comando no es `gh pr create`, el PR sí enlazó, o el cuerpo no declara intención de cierre |
| `coverage-report.sh` | Stop | Muestra la cobertura **del diff** (no la global) al final de cada turno que tocó código, leyendo el informe que ya exista (`coverage.xml` Cobertura o `lcov.info`). No corre los tests, no bloquea nunca, y avisa si el informe es anterior a los cambios. Si el repo mide cobertura pero no la vuelca a fichero, lo diagnostica con el flag exacto que falta en vez de callar. Sale por `systemMessage` en JSON. | No hay git, no hubo cambios, o el repo no mide cobertura en absoluto |
| `plan-invariantes-drift.sh` | Stop | Si el turno añadió o quitó `resource`/`module`/`data` en `infra/` sin tocar `.claude/plan-invariantes.md`, exit 2 para que se revisen los invariantes (una vez por cadena de Stop). | No hay `infra/`, no hay git, o el cambio no es estructural (tags, defaults) |

### Servidores MCP (`.mcp.json`)

Arrancan solos al habilitar el plugin (sin `enabledMcpjsonServers` por usuario). Sus
herramientas llevan el prefijo de plugin (`mcp__plugin_...`): ver «Permisos y limpieza
post-migración» más abajo.

> `context7` salió del plugin en v0.3.0: duplicaba el plugin oficial
> `context7@claude-plugins-official` (doble proceso y doble juego de tools por sesión).
> Si lo quieres, activa el oficial a nivel de usuario. No lo re-añadas aquí.

| Server | Qué es | Necesita |
|---|---|---|
| `terraform` | registry de providers/módulos (docker, pin 0.4.0) | Docker corriendo |
| `azure-mcp` | operaciones Azure (pin 2.0.3) | sesión az |
| `postgres-prod` | consulta read-only de la BD de prod (postgres-mcp restricted) | `DATABASE_URL_PROD` |
| `postgres-dev` | ídem contra la BD local de dev | `DATABASE_URL_DEV` |

**Contrato de las URLs**: cada repo consumidor define los valores —
`DATABASE_URL_PROD` en su `.claude/settings.local.json` (secreto, gitignored, con un rol
de **lectura**, nunca el admin) y `DATABASE_URL_DEV` en su `.claude/settings.json`
versionado (credencial local de compose, no es secreto).

La única excepción aceptable es el repo que **administra el propio server** compartido,
donde no existe rol de lectura a nivel de server: ahí la mitigación es el
`--access-mode=restricted` que el launcher fija siempre. La excepción se documenta en ese
repo, y ningún otro la hereda: un repo de aplicación tiene su rol de lectura y lo usa.

```json
{ "env": { "DATABASE_URL_PROD": "postgresql://<rol-lectura>:<pass>@<fqdn>:5432/<bd>?sslmode=require" } }
```

**Si falta la variable** (repo sin esa BD, p. ej. sin entorno dev): en sesiones
interactivas es **Claude Code quien lo detecta** antes de lanzar nada — el panel
`/plugin` → Errors muestra `Missing environment variables: DATABASE_URL_*` y el server
no arranca; es benigno, se ignora. El panel dice *qué* falta; *dónde* definirla es el
párrafo de arriba.

Los dos servers arrancan vía `bin/postgres-mcp-launcher.sh`. Su guarda ya no es la
primera línea en interactivo (la validación nativa la precede), pero sigue teniendo
tres funciones: (1) en **headless** (`claude -p`) no hay validación nativa y el literal
`${...}` pasaría crudo a postgres-mcp — el launcher lo corta con mensaje accionable;
(2) centraliza el comando (pin `--with 'mcp<2'` + `--access-mode=restricted` una sola
vez para prod y dev); (3) defensa si el comportamiento nativo cambia (ya difiere entre
superficies).

Gotchas: los MCP de plugin no se pueden deshabilitar de uno en uno (es todo el plugin);
actualizar el `.mcp.json` del plugin requiere reiniciar la sesión (`/reload-plugins` no
refresca MCPs); y la expansión `${VAR}` sale del entorno de la sesión — el `env` de
settings funciona en sesiones interactivas, pero en `claude -p` (headless) exporta la
variable en la shell antes (verificado empíricamente, 2026-08).

Los MCP **específicos de un repo** sí viven en el `.mcp.json` del propio repo y conviven
sin conflicto con los del plugin (p. ej. un server de telemetría propio del repo, con su
entrada en `enabledMcpjsonServers`). La regla no es «sin `.mcp.json` por proyecto»,
sino **no duplicar**: si un server ya lo trae el plugin (o existe como plugin oficial),
el repo no lo redefine.

#### Permisos y limpieza post-migración

Las herramientas de estos servers se llaman `mcp__plugin_taller_<server>__<tool>`.
Para no reaprobar en cada sesión, añade al `permissions.allow` del repo consumidor las
entradas a nivel de server (autorizan todas sus tools):

```json
{ "permissions": { "allow": [
  "mcp__plugin_taller_terraform",
  "mcp__plugin_taller_postgres-dev",
  "mcp__plugin_taller_postgres-prod"
] } }
```

`azure-mcp` se deja fuera a propósito (puede mutar recursos de Azure; mejor aprobar por
acción). Al migrar un repo al plugin, borra además los restos del esquema anterior en su
`settings.local.json`: los permisos con nombres planos (`mcp__postgres-prod__*`,
`mcp__context7__*`, …) ya no matchean nada, y `enabledMcpjsonServers` /
`enableAllProjectMcpServers` solo aplican al `.mcp.json` del propio repo — si ese fichero
ya no define los servers comunes, quedan huérfanos y confunden.

### Agentes (`agents/`)

Cada agente fija su `model` y su `effort` en el frontmatter (el porqué, en `CLAUDE.md` →
«Modelo y esfuerzo de los agentes»). Si defines `CLAUDE_CODE_EFFORT_LEVEL`, esa variable
gana al `effort` de los agentes; `CLAUDE_CODE_SUBAGENT_MODEL` no gana al `model` salvo con
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`.

- **backlog-triage** — lee todos los issues abiertos de uno o varios repos y devuelve
  **una** recomendación argumentada de por dónde seguir, con los bloqueos, los duplicados y
  lo que ya tiene PR abierto apartados. Es un agente y no una skill justamente por eso: lee
  decenas de miles de tokens para producir quince líneas, y ese trabajo va en contexto
  aislado. Descubre en runtime qué señales de prioridad tiene el repo (campos nativos de
  issue de la organización, labels tipo `priority:*`/`P1`/`size:*`, milestones) y, si no hay
  ninguna, lo dice en vez de inventarse un orden. No toca nada: ni ramas, ni comentarios,
  ni labels.

- **test-coverage-reviewer** — dice si un cambio está **verificado**, no solo ejecutado.
  Tría las líneas nuevas sin cubrir (una rama de negocio sin test es alarma; un
  `__repr__` no lo es), busca los casos que faltan —camino de error, límites, nulos, y el
  test de regresión que tiene que **fallar antes** del arreglo— y, sobre todo, mira si los
  tests que ya hay comprueban algo: un test sin asserts, un snapshot regenerado en el mismo
  commit o un mock que se come al sujeto dejan la línea cubierta y el código sin testear.
  De ahí su veredicto más útil, **COBERTURA ENGAÑOSA**, que es el que nadie más da.
  **No escribe tests**: dice qué casos faltan. Un agente que los escribe los escribe leyendo
  el código, así que assertaría lo que el código hace — bug incluido, con guardián. Es
  **dueño de `.claude/tests-invariantes.md`**, donde viven las zonas de rigor extra y los
  huecos aceptados con su motivo.

- **terraform-plan-reviewer** — clasifica un `terraform plan` (create/update/replace/destroy),
  marca destroys/replaces con causa y riesgo, y contrasta con los invariantes del repo.
  Veredicto: SEGURO / REVISAR / NO APLICAR.
  Además es **dueño de `.claude/plan-invariantes.md`**: lo **crea si no existe** y lo
  **mantiene al día** tras cada revisión — añade lo que el plan
  reveló, corrige lo que cita cosas que ya no existen y retira lo que dejó de aplicar,
  informando de cada cambio. Nunca relaja un invariante para que un plan pase.

  Para los invariantes **cross-repo** —los que revientan el plan de otro repo, y los que
  nadie deduce leyendo un solo `infra/`— **no pregunta de qué repo depende este: lo
  deduce**. Depender de algo sin administrarlo tiene sintaxis en Terraform (un `data` cuyo
  tipo no se declara como `resource` aquí, un `terraform_remote_state`, el backend del
  state, un `provider` con alias a otra cuenta), así que saca esa lista del código y luego
  busca en la organización quién declara ese recurso (`gh search code`). Lo que encuentra lo
  cachea en el fichero **con su evidencia**, para no repetirlo, y el hook
  `plan-invariantes-drift` —que ya vigila las altas de `data "`— es el disparador natural
  para volver a mirarlo. Un recurso del que dependes y que **nadie** versiona no es un
  callejón sin salida: es el hallazgo más valioso de todos, y también se escribe.

- **alembic-migration-reviewer** — revisa una revisión Alembic nueva o editada contra la
  doctrina del plugin (expand/contract, `TIMESTAMPTZ` para instantes, `NOT NULL`
  seguro sobre tablas con datos, **`downgrade()` obligatorio** —vacío es violación, y la
  única salida es declararlo irreversible en el docstring con una razón que no sea
  comodidad—, integridad de la cadena de revisiones y `COMMENT` en español en todo
  objeto, **sin excepciones ni siquiera para `id`**). Veredicto: SEGURO / REVISAR / NO APLICAR. No aplica ni reescribe nada.
  Además es **dueño de `.claude/migraciones-invariantes.md`**: lo **crea si no existe**
  (derivándolo de la baseline, del resto de `versions/` y del `db/README.md` del repo) y lo
  **mantiene al día** tras cada revisión. Ahí va lo específico del esquema —contratos que
  consume otro componente, jerarquías de tenant, roles y privilegios, patrones de la
  baseline—; el checklist genérico no se relaja desde el repo, solo se amplía.

### Skills (`skills/`)

Se refrescan con `/reload-plugins` (no hace falta reiniciar la sesión). Las seis primeras
son el ciclo del principio de este README; cada una encadena con la siguiente y ninguna
hace el trabajo de otra.

- **/triage** — *¿por dónde sigo?* Delega el barrido del backlog en el agente
  `backlog-triage` (para no comerse el contexto que hace falta luego para implementar),
  presenta su veredicto y encadena con `/work-issue`. Vale para un repo o para varios a la
  vez: `gh` no necesita clonarlos.
- **/work-issue** — arranca un issue con su contexto real antes de tocar código: cuerpo **y
  comentarios** (donde vive el cambio de criterio), los campos nativos de la organización
  —que `gh issue view` no expone y que fijan el modo de trabajo: esfuerzo bajo al grano,
  alto con plan acordado—, los enlaces del issue (`parent`, sub-issues, `blockedBy`) y si ya
  hay rama o PR abierto. Obliga a listar supuestos y preguntas antes de implementar. Es
  además **dueña de `.claude/flujo-github.md`**: lo descubre y lo escribe la primera vez, y
  lo corrige cuando encuentra que miente.
- **/check-work** — *¿esto está listo?* Corre la validación que declare el repo
  (descubriéndola, con `.github/workflows/` como fuente de verdad por encima de cualquier
  atajo desfasado), pasa los agentes de revisión que el repo defina y que apliquen al diff,
  relee el diff en contra y contrasta lo hecho con lo que pedía el issue. Devuelve LISTO /
  LISTO CON RESERVAS / NO LISTO, nunca un «creo que sí».
- **/open-pr** — abre el PR con los gotchas de `gh` aprendidos: `Closes #N` en texto plano y
  línea propia, labels en el propio `gh pr create` (no las añade solo), verificación de
  `closingIssuesReferences`. No espera a CI ni mergea: eso es `/land-pr`.
- **/land-pr** — remata el PR y **cierra el ciclo**: conflicto → CI → revisión → merge, en
  ese orden y por ese motivo. Lee el **log** del job que falló, no el nombre del check;
  nunca desactiva un test para poner el verde; no mergea sin confirmación explícita; y
  después verifica que el issue se cerró de verdad, limpia la rama y devuelve a `/triage`.
- **/gh-create-issue** — issue con Issue Type nativo (`gh issue create --type`, nativo desde
  gh 2.72) y, si la organización define campos nativos de issue, **siempre con valor** vía
  `setIssueFieldValue` (`gh` no tiene flag para ellos). Si no los especificas, los
  **infiere** con una rúbrica (impacto si no se hace / trabajo hasta mergear), los pone con
  su `rationale` y te dice qué ha inferido. Los IDs se resuelven en runtime y se cachean en
  `.claude/flujo-github.md`: el plugin no trae ninguno escrito. La mutación va **siempre con
  `confidence: HIGH`** y se **relee** después: con cualquier otra confianza el campo no se
  guarda y la API responde como si sí (detalle en `CLAUDE.md`).
- **/review-infra-plan** — localiza el job de plan del PR/run de infra, extrae su log y lo
  pasa por `terraform-plan-reviewer` contra `.claude/plan-invariantes.md`. Nunca mergea ni
  aplica. Se invoca desde `/check-work` cuando el diff toca infraestructura.

## Cómo lo consume un repo

En el `.claude/settings.json` (versionado) del repo consumidor:

```json
{
  "extraKnownMarketplaces": {
    "taller": {
      "source": {
        "source": "github",
        "repo": "gabriel23cg/claude-taller"
      }
    }
  },
  "enabledPlugins": {
    "taller@taller": true
  }
}
```

Al abrir el repo, Claude Code detecta el marketplace, instala el plugin y lo activa. Mientras
`gabriel23cg/claude-taller` sea **privado**, cada máquina que lo cargue necesita acceso de
lectura a él con sus credenciales de git.
Los hooks del plugin **se suman** a los hooks propios del repo (si ambos corren sobre el
mismo evento, un exit 2 de cualquiera bloquea).

No hace falta escribir `.claude/flujo-github.md` a mano: la primera vez que corras
`/work-issue` en el repo, la skill descubre las convenciones (rama base, nombres de rama,
labels, validación, agentes, política de merge, señales de prioridad) y las escribe. A
partir de ahí manda el fichero: corrígelo si se equivocó, y lo que pongas ahí gana sobre lo
que el plugin vuelva a deducir. Las secciones sin dato fiable se escriben `(sin declarar)`,
que es más honesto que una convención inventada.

Si el repo tiene infra Terraform, no hace falta escribir `.claude/plan-invariantes.md` a
mano: pide una revisión de plan (`/review-infra-plan`) y el agente lo crea derivándolo del
`infra/` del repo. A partir de ahí lo mantiene él, y el hook `plan-invariantes-drift` avisa
cuando la infra cambia de forma estructural y los invariantes se quedan atrás.

Lo mismo con Alembic: si el repo tiene migraciones, no escribas
`.claude/migraciones-invariantes.md` a mano — invoca `alembic-migration-reviewer` sobre una
revisión y lo crea derivándolo del esquema del repo. No hay hook de deriva equivalente a
propósito: crear un fichero en `versions/` ya es el momento natural de invocar al agente.

## Versionado y actualización

`version` en `.claude-plugin/plugin.json`: súbelo en cada cambio con efecto en los
consumidores. Con `version` presente el plugin queda **pineado a esa cadena**: empujar
commits nuevos sin tocarla NO actualiza a nadie («users only receive updates when you
change this field»). No la declares también en `marketplace.json`: Claude Code usa la de
`plugin.json` sin avisar.

Subir la versión es **necesario pero no suficiente**: alguien tiene que refrescar el
marketplace. Los marketplaces de terceros —este— tienen el **auto-update desactivado por
defecto** (solo los oficiales de Anthropic lo traen activado). Dos formas de cerrarlo:

- **Activar auto-update una vez por máquina**: `/plugin` → **Marketplaces** →
  `taller` → *Enable auto-update*. A partir de ahí Claude Code hace los dos
  pasos solo («refreshes the marketplace data **and** updates installed plugins to their
  latest versions on disk») tras arrancar, con retardo aleatorio de hasta 10 min, y avisa
  para que corras `/reload-plugins`; la sesión en curso sigue con lo que cargó al arrancar.
- **Refrescar a mano** cuando quieras la versión nueva ya. Son **dos pasos**, y saltarse el
  segundo es el error fácil (verificado 2026-09-10):
  ```bash
  claude plugin marketplace update taller   # refresca el CATÁLOGO
  claude plugin update taller@taller --scope project   # instala la versión
  ```
  El primero solo actualiza el catálogo del marketplace: deja el plugin instalado en la
  versión vieja. El segundo es el que la baja a disco, y es **por scope**: `--scope user`
  (el default) no toca las instalaciones de scope `project`, y esas son **una por repo
  consumidor**, así que el comando se corre **dentro de cada repo**. Ambos exigen reiniciar
  la sesión (o `/reload-plugins`) para que la sesión en curso los vea.

El auto-update es **por máquina, no por repo**: el marketplace se registra una vez en
`~/.claude/plugins/known_marketplaces.json` y esa entrada sirve a todos los consumidores, así
que basta activarlo una vez. Lo que **no está verificado** es que el auto-update alcance
todas las instalaciones (la de scope `user` y una por repo/worktree de scope `project`):
la doc dice «updates installed plugins» sin hablar de scopes. Si tras un release un repo
sigue en la versión vieja, `claude plugin list` lo dice y el refresco manual lo arregla.

La doc menciona un `"autoUpdate": true` por entrada de `extraKnownMarketplaces`, pero
**para *managed settings***. En settings de proyecto no está confirmado que se aplique (en
una prueba headless no propagó al registro; el arranque headless no registra marketplaces,
así que la prueba no es concluyente). Por eso los `settings.json` de los consumidores NO lo
llevan: el mecanismo que se sabe que funciona es el toggle de `/plugin`.
