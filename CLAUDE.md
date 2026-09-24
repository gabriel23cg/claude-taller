# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es este repo

**Plugin + marketplace de Claude Code** (ambas cosas, el mismo repo): `taller`, las
automatizaciones que comparten los proyectos de un mismo perfil. Los repos consumidores lo
activan vía `extraKnownMarketplaces`/`enabledPlugins` en su `.claude/settings.json`
versionado: al abrir cualquiera de ellos, Claude Code lo instala y lo activa solo. **Un
cambio aquí llega a todos los consumidores a la vez** — esa es la razón de existir del repo,
y también su riesgo: piensa cada cambio como si editaras el `.claude/` de todos ellos.

El perfil es concreto y a propósito: **GitHub** para issues y PRs, **infra en Azure con
Terraform** y **Postgres** con migraciones Alembic. De ahí salen los MCP (`terraform`,
`azure-mcp`, `postgres-prod/dev`) y los revisores de plan y de migraciones. Un repo al que le
falte alguna de esas piezas no se rompe —los hooks tienen guarda no-op—, pero el plugin no
está pensado para él.

Lo **específico de un proyecto NO vive aquí**: su dominio, sus secretos y sus skills
operativas se quedan en el `.claude/` de ese repo.

Hasta v0.9.0 tenía otro nombre y vivía en otra organización: el historial de git conserva
las referencias de entonces, y en v1.0.0 solo cambió el nombre, no el comportamiento.

### Datos descubiertos, opiniones escritas

Son dos cosas distintas y mezclarlas es el error que este repo evita:

- **Los datos que cambian de un repo a otro** —organización, repo, IDs de campos, labels,
  rama base, comando de validación— **no viven aquí**: se **descubren en runtime** y se
  cachean en el `.claude/` del repo (ver «Ficheros por-repo» abajo). La regla al añadir
  algo: si tu cambio funciona solo porque la org o el repo se llaman de una manera
  concreta, está mal — y el mecanismo para arreglarlo ya existe, no lo inventes.
- **Las opiniones, que son las mismas en todos los proyectos, sí viven aquí**, y escritas
  como política del plugin, no disfrazadas de descubrimiento: el apply de Terraform solo por
  CI (`block-terraform-apply`), prod de solo lectura (el rol de `DATABASE_URL_PROD`), la BD
  en UTC y `COMMENT` en español en todo objeto (`alembic-migration-reviewer`). Un repo
  puede **endurecerlas** en su fichero de invariantes; no relajarlas.

La prueba para saber en qué lado cae algo nuevo: si en otro proyecto del mismo perfil
tendría un valor distinto, es un dato y se descubre; si tendría el mismo, es una opinión y
se escribe.

## Estructura

```
.claude-plugin/plugin.json       # manifiesto: name, description, VERSION (ver abajo)
.claude-plugin/marketplace.json  # este repo como marketplace; el plugin es source "./"
hooks/hooks.json                 # wiring de los 8 hooks (PreToolUse/PostToolUse/Stop)
hooks/*.sh                       # los hooks (bash 3.2-compatible: sin mapfile)
bin/postgres-mcp-launcher.sh     # guarda de los MCP de Postgres (valida la URL antes de arrancar)
agents/*.md                      # agentes: triage de backlog, cobertura de tests, plan de
                                 #   Terraform, migraciones Alembic
skills/*/SKILL.md                # el ciclo: triage, work-issue, check-work, open-pr, land-pr,
                                 #   gh-create-issue, review-infra-plan
.mcp.json                        # MCP comunes: terraform, azure-mcp, postgres-prod/dev
tests/validate.sh                # la validación entera (JSON, wiring, smoke tests); la corre CI
.github/workflows/validate.yml   # CI: validate.sh + exige version bump si el cambio llega a los consumidores
README.md                        # contrato con los consumidores (léelo antes de tocar nada)
```

## El ciclo de trabajo (v0.8.0)

Las seis skills de flujo son **una sola cosa**, no seis utilidades sueltas:

```
/triage → /work-issue → implementar → /check-work → /open-pr → /land-pr ─┐
   ↑                                                                     │
   └─────────────────────────────────────────────────────────────────────┘
        /gh-create-issue alimenta el backlog que lee /triage
```

Consecuencias que hay que respetar al tocar cualquiera de ellas:

- **Cada skill dice explícitamente de dónde viene y a dónde va.** Si rompes un eslabón, el
  ciclo deja de girar y vuelves a tener seis utilidades sueltas que nadie encadena.
- **Ninguna hace el trabajo de otra.** `/open-pr` no espera a CI (es `/land-pr`),
  `/land-pr` no revisa código (es `/check-work`), `/triage` no lee el backlog él mismo (es
  el agente). Cada solapamiento que metas es contexto duplicado en las tres sesiones.
- **El cierre del ciclo es la parte que se olvida**: `/land-pr` termina verificando que el
  issue se cerró y devolviendo a `/triage`. Eso no es adorno — es lo que impide que el
  siguiente trabajo lo elija la inercia.

## Ficheros por-repo: el mecanismo de «genérico sin perder potencia»

Cuatro ficheros en el `.claude/` del repo consumidor, cada uno con un **dueño** en el plugin
que lo crea si falta y lo mantiene:

| Fichero | Dueño | Qué guarda |
|---|---|---|
| `.claude/flujo-github.md` | skill `work-issue` | rama base y convención de nombres, labels obligatorias, comando de validación, agentes de revisión, política de merge, señales de prioridad (y los IDs de los campos nativos, si la org los usa) |
| `.claude/plan-invariantes.md` | agente `terraform-plan-reviewer` | invariantes de infra + **de qué depende el repo sin administrarlo y quién lo administra**, que el agente deduce del propio Terraform (ver abajo) |
| `.claude/migraciones-invariantes.md` | agente `alembic-migration-reviewer` | invariantes de esquema |
| `.claude/tests-invariantes.md` | agente `test-coverage-reviewer` | convenciones de test, zonas que exigen rigor extra y **huecos aceptados con su motivo** — sin eso el agente repite el mismo hallazgo para siempre |

La regla es la misma en los cuatro: **el plugin descubre, el fichero manda.** Si el fichero
dice algo distinto de lo que el plugin deduciría, gana el fichero. Y las secciones sin dato
fiable se escriben `(sin declarar)` — un hueco honesto no hace daño; una convención
inventada que alguien sigue, sí.

Corolario que conviene no perder: **ninguno de los cuatro es un requisito previo.** Si
añadiendo algo al plugin te sale un «y el repo declara X», no has quitado el nombre propio:
lo has movido a un formulario que alguien tiene que rellenar, y que nadie rellenará. La
salida siempre es la misma: buscar la señal que ya está en el repo. Para las dependencias
cross-repo de infra, esa señal es la sintaxis de Terraform —un `data` sin su `resource`, un
`terraform_remote_state`, el backend del state— más una búsqueda de código en la
organización para ver quién declara ese recurso. El procedimiento entero vive en
`terraform-plan-reviewer`.

## Reglas al cambiar algo

- **Sube `version` en `plugin.json` en cada cambio con efecto en consumidores.** Es el único
  mecanismo de release: con `version` presente el plugin queda pineado a esa cadena y
  empujar commits sin tocarla NO actualiza a nadie. Necesario pero **no suficiente**: la
  versión nueva llega sola solo donde el auto-update está activado, y aun así con retraso
  (ver gotcha del auto-update abajo).
- **Los cambios en `.mcp.json` exigen reiniciar la sesión** en los consumidores
  (`/reload-plugins` refresca hooks/agents/skills, pero NO los MCP).
- **Rutas siempre con `${CLAUDE_PLUGIN_ROOT}`** en hooks.json y .mcp.json: el plugin se COPIA a
  la caché al instalarse; una ruta relativa o absoluta al repo no existe en el destino.
- Los hooks deben ser **seguros en todos los consumidores a la vez**: guarda no-op donde no apliquen
  (los de ruff comprueban `[tool.ruff]` en pyproject; el de fmt comprueba `infra/` + terraform).
  Un hook nuevo sin guarda romperá el repo al que no aplica.
- Los hooks del plugin **se suman** a los del repo consumidor (mismo evento → corren ambos; un
  exit 2 de cualquiera bloquea). Exit codes: 0 = seguir, 2 = bloquear con stderr al modelo.
- **CI mínimo** (`validate` en cada PR y push a main): corre `tests/validate.sh` y, si el PR
  toca `hooks/`, `bin/`, `agents/`, `skills/` o `.mcp.json`, **falla si `version` no sube**.
  No sustituye a probar en un repo consumidor antes del push: CI valida el plugin en el vacío,
  no su efecto en los consumidores.

## Validación local (hazla SIEMPRE antes de push)

```bash
./tests/validate.sh
```

Es el mismo script que corre CI, a propósito: una sola fuente de verdad en vez de dos listas
de comandos que divergen. Cubre JSON válido, `bash -n`, bit `+x`, que las rutas de
`hooks.json`/`.mcp.json` existan y usen `${CLAUDE_PLUGIN_ROOT}`, el frontmatter de
skills/agentes, y smoke tests de **todos** los hooks y del launcher (con stub de `uvx`, y de
`gh` para los dos hooks de GitHub, que así no dependen de issues reales ni de estar
autenticado). Sin número: el día que añadas un hook, el recuento no se queda mintiendo.
Al tocar un hook, **añade el caso al script**; los comentarios de cada bloque explican qué
regresión evita (p. ej.: un `file_path` inexistente hace salir a `ruff-on-edit` en el chequeo
de `-f`, antes de llegar al guard de ruff — por eso el test crea el fichero de verdad).

Para probar de punta a punta sin tocar los repos reales: `claude plugin marketplace add <ruta-a-este-repo> --scope local` en un proyecto de prueba + `claude plugin install taller@taller --scope local`.

## Contrato con los repos consumidores (la pieza por-repo)

- **`.claude/flujo-github.md`**: las convenciones de flujo del repo, que el plugin
  descubriría igual pero más lento y peor. Dueña: la skill `work-issue` (la forma canónica
  del fichero vive en su SKILL.md: si la cambias, cámbiala ahí). Lo leen también `triage`,
  `check-work`, `open-pr`, `land-pr` y `gh-create-issue`, todas con fallback a
  descubrimiento si no existe: **ningún repo necesita crearlo para que el ciclo funcione**.
- **`.claude/plan-invariantes.md`**: los invariantes que `terraform-plan-reviewer` contrasta.
  El agente es genérico a propósito; si un repo necesita una alarma nueva, va en SU fichero de
  invariantes, no en el agente. Desde v0.4.0 el agente es **dueño** del fichero (lo crea si
  falta y lo mantiene tras cada revisión, con `Write`/`Edit` en su frontmatter) y el hook
  `plan-invariantes-drift` avisa cuando `infra/` cambia de forma estructural sin tocarlo. La
  forma canónica del fichero vive en el propio agente: si la cambias, cámbiala ahí.
- **`.claude/tests-invariantes.md`**: lo específico de test de este repo, con
  `test-coverage-reviewer` de **dueño**. Lo genérico —cobertura no es verificación, el
  camino de error, los límites, el test de regresión que debe fallar antes del arreglo— vive
  en el agente y **no se relaja desde el repo**: el fichero solo lo endurece (zonas
  sensibles) y registra los **huecos aceptados con su motivo y su fecha**, que es lo que
  evita rediscutir cada trimestre lo que ya se decidió.
- **`.claude/migraciones-invariantes.md`**: lo mismo para `alembic-migration-reviewer`, que
  también es **dueño** del fichero. El checklist genérico (expand/contract, TIMESTAMPTZ,
  NOT NULL seguro, `downgrade()` obligatorio, integridad de la cadena, `COMMENT` en español)
  vive en el agente y **no se relaja desde el repo**: el fichero solo lo amplía con lo del
  esquema concreto (contratos que consume otro componente, jerarquías de tenant, roles,
  patrones de la baseline). El repo puede **endurecer** el checklist, nunca relajarlo — y el
  de `COMMENT` no admite exenciones, tampoco para `id` (v0.7.0). Sin hook de deriva
  equivalente al de plan: tocar `versions/` ya es el momento de invocar al agente.
- **`DATABASE_URL_PROD`** en el `settings.local.json` del repo (gitignored; rol de **lectura**,
  nunca el admin — la única excepción aceptable es el repo que administra el propio server
  compartido, donde no hay rol de lectura a nivel de server; la mitiga el
  `--access-mode=restricted` del launcher y se documenta en ESE repo, no aquí) y **`DATABASE_URL_DEV`** en su `settings.json` versionado (compose local, no
  secreto). Si faltan, en interactivo lo corta la **validación nativa** de Claude Code
  (`/plugin` → Errors: "Missing environment variables"; el server no arranca, benigno); el
  launcher cubre el resto (ver gotcha abajo) — su mensaje sigue siendo documentación al usuario
  en headless, mantenlo bueno.

## Gotchas conocidos

- **`setIssueFieldValue` no guarda el campo si la confianza no es `HIGH` — y NO da error**
  (observado en producción 2026-09-23: dos issues reales se quedaron sin esfuerzo). Con
  `rationale` y `confidence: MEDIUM` la mutación responde `issue { number }` tan contenta y
  el valor no aterriza. Encaja con lo de `suggest: true`: todo lo que no sea una afirmación
  en firme parece acabar en la cola de sugerencias en vez de aplicarse. Consecuencias que el
  plugin ya implementa y conviene no deshacer: la receta va **siempre** con `HIGH`, la
  escritura se **relee** (una escritura que puede fallar en silencio no se da por buena por
  su propia respuesta), y `tests/validate.sh` prohíbe que vuelva a entrar por copiar y pegar
  — con un patrón que exige la sintaxis del input, porque la documentación del fallo tiene
  que poder citar el valor malo.
- **Para que un hook le diga algo AL USUARIO hay que usar `systemMessage` en JSON**
  (verificado contra la doc, 2026-09-18). Con exit 0, el stdout de un `Stop` o un
  `PostToolUse` va **solo al log de depuración**: no lo ve el usuario ni el modelo, así que
  un `echo` ahí se pierde en silencio y parece que el hook no hace nada. El mecanismo es
  escribir por stdout `{"systemMessage":"..."}` y salir 0 — lo usa `coverage-report`. Dos
  trampas: **`PostToolUse` DESCARTA `systemMessage`** (ahí solo vale `additionalContext`,
  que va al modelo, no al usuario), y exit 2 no es alternativa para informar: bloquea, y un
  hook que bloquea para contar algo se acaba desactivando.
- **`block-terraform-apply` da falso positivo** si cualquier comando Bash CONTIENE la cadena
  "terraform apply" — incluidos mensajes de commit. Se sortea reformulando el texto. Es un
  trade-off deliberado (un parser más listo arriesga falsos negativos).
- **Expansión `${VAR}` en `.mcp.json`**: sale del entorno de la sesión. El `env` de settings del
  repo funciona en sesiones interactivas; en `claude -p` (headless) NO se aplica a la expansión
  (verificado empíricamente 2026-08) — el launcher lo cubre leyendo la variable del entorno del
  proceso como fallback.
- **Los MCP del plugin no se deshabilitan de uno en uno**: es todo el plugin o nada. Un repo
  sin BD simplemente no define la variable y el server queda parado por la validación nativa.
- **La guarda del launcher NO se ve en interactivo** (verificado 2026-08-17): Claude Code valida
  las `${VAR}` del `.mcp.json` del plugin antes de lanzar el comando y muestra su propio error.
  El launcher sigue valiendo para: headless (sin validación nativa, el literal pasaría crudo a
  postgres-mcp), centralizar el comando (pin `mcp<2`) y defensa ante cambios del comportamiento
  nativo (ya difiere entre superficies).
- Las herramientas MCP del plugin llevan prefijo `mcp__plugin_<plugin>_...`: los
  `permissions.allow` que apuntaban a otro nombre quedan huérfanos hasta reaprobar. Pasó al
  entrar en el plugin (nombres planos → `mcp__plugin_...`) y otra vez en v1.0.0, al renombrar
  el plugin a `taller`: **renombrar el plugin rompe los permisos de sus MCP**. Y no es lo
  único: un plugin se identifica por su nombre, así que activado en varios sitios (scope
  `user`, `settings.json` del repo, sincronizado desde claude.ai) carga una sola vez, pero
  dos nombres no se deduplican. Si el nombre viejo sigue activado a nivel de usuario, un
  repo ya migrado carga los dos, con cada hook corriendo dos veces: el viejo se quita justo
  después de migrar, no «algún día». El
  README trae el bloque `allow` exacto y la limpieza post-migración: mantenlo al día.
- **En ESTE repo el `.mcp.json` se carga dos veces** y de ahí los MCP fallidos al abrir la
  sesión: al vivir en la raíz, Claude Code lo toma también como config **de proyecto**, ámbito
  en el que `${CLAUDE_PLUGIN_ROOT}` **no existe** → `postgres-prod`/`postgres-dev` fallan con
  `ENOENT posix_spawn '${CLAUDE_PLUGIN_ROOT}/bin/...'`. Los del plugin, en paralelo, quedan en
  `CONNECTION_CLOSED` porque aquí no hay `DATABASE_URL_*` (esa es la guarda del launcher
  funcionando). Es ruido solo del repo fuente, no de los consumidores. La cura es
  **`disabledMcpjsonServers`** con `postgres-prod`/`postgres-dev` en el `settings.local.json`
  de este repo (verificado 2026-09-10: arranque limpio). Quitarlos de `enabledMcpjsonServers`
  NO basta: siguen intentando arrancar.
- **El auto-update llega DESPUÉS de arrancar, no al arrancar — y viene apagado por defecto
  en marketplaces de terceros** (solo los oficiales de Anthropic lo traen puesto). Se activa
  **una vez por máquina** —`/plugin` → Marketplaces → `taller` → Enable auto-update, que
  escribe `"autoUpdate": true` en `~/.claude/plugins/known_marketplaces.json`—. El toggle es
  **por marketplace**: al renombrarlo en v1.0.0 nació una entrada nueva con él apagado, así
  que hay que volver a activarlo en cada máquina (lo del marketplace viejo no se hereda).
  Donde no esté activado, subir `version` no llega a nadie hasta que se active o se
  refresque a mano.

  Con él activado, lo que confunde es el **cuándo** (verificado contra la doc, 2026-09-23:
  *«checks for marketplace and plugin updates after your session starts, with a random
  delay of up to ten minutes, so the running session keeps using the versions it loaded at
  launch»*):
  1. abres una sesión → arranca con la versión que ya había en disco;
  2. hasta 10 min después, en segundo plano, refresca el catálogo y baja la versión nueva;
  3. avisa para correr `/reload-plugins`; si no lo haces, la verás en la **siguiente** sesión.

  Así que «acabo de abrir sesión y sigue la vieja» es el comportamiento esperado, no un
  fallo: es a propósito, para que la sesión en curso no cambie de hooks ni de agentes a
  medio trabajo.

  **Lo que la doc no dice es si cubre todas las instalaciones** («updates installed plugins»,
  sin mencionar scopes), y aquí hay varias — ver abajo. La única observación que tenemos
  apunta a que no: el 2026-09-16, seis días después de activarlo, la de scope `user` iba dos
  versiones atrasada. No es concluyente (puede que ninguna sesión llegara a los 10 min), así
  que queda **sin verificar**. Cómo cerrarlo: tras un release, abrir sesión en un consumidor,
  esperar al aviso y mirar `claude plugin list`.

  **El refresco manual** sirve para forzar la versión ya, o en máquinas sin auto-update. Son
  **dos pasos** y saltarse el segundo deja el plugin en la versión vieja (verificado):
  `claude plugin marketplace update taller` refresca el catálogo, y
  `claude plugin update taller@taller --scope project` instala la
  versión — **por scope**, y ahí está la trampa: no hay «una instalación por repo
  consumidor». Verificado 2026-09-16 al publicar v0.6.0, `claude plugin list` devolvía
  **siete** instalaciones del plugin:
  - una de scope **`user`**, que es global, que nadie documentaba y que llevaba dos
    versiones desfasada (0.5.0 cuando el resto iba por 0.6.0). Se refresca con
    `--scope user`, y hay que acordarse: no la toca ningún refresco de proyecto.
  - una de scope `project` por cada directorio desde el que alguien haya corrido un
    `claude plugin install/update --scope project`, y eso incluye **los worktrees**. Un
    worktree NO nace con entrada propia: hereda (cae al scope `user`) hasta que alguien
    hace ahí dentro una operación de scope `project`; desde ese momento tiene la suya y se
    queda congelada en esa versión. Las entradas **sobreviven al borrado del worktree**: el
    registro (`~/.claude/plugins/installed_plugins.json`) acumula huérfanas apuntando a
    directorios inexistentes. Son inofensivas —nada puede cargar de un directorio que no
    existe— pero ensucian el recuento de `claude plugin list`, así que no te asustes si ves
    más instalaciones que directorios.

  Consecuencia práctica: tras subir `version`, con auto-update **no hay que hacer nada**
  salvo aceptar el `/reload-plugins` cuando avise. El manual se corre solo cuando hace falta
  la versión *ya* —p. ej. cuando un consumidor borra su copia local de un agente para pasar
  a usar la del plugin, y hasta que llegue la versión nueva se queda sin ninguno— y entonces en ese
  repo, en cada worktree vivo que se vaya a usar, y una vez con `--scope user`. Si un
  agente o una skill nueva «no aparece» después de `/reload-plugins`, el primer sitio donde
  mirar es `claude plugin list`: casi seguro que el scope desde el que trabajas sigue en la
  versión vieja. `/reload-plugins` **sí** recarga agentes y skills (verificado 2026-09-16: un
  agente nuevo pasó a ser invocable sin reiniciar la sesión) — pero solo puede cargar lo que
  la versión instalada EN ESE SCOPE contenga.

  El `"autoUpdate"` por entrada de `extraKnownMarketplaces` es solo para *managed settings*
  (la doc lo dice así: «Administrators can also set `"autoUpdate": true` on each
  `extraKnownMarketplaces` entry in managed settings»); en settings de proyecto no está
  confirmado que se aplique.
- **`context7` salió del `.mcp.json` en v0.3.0**: duplicaba el plugin oficial
  `context7@claude-plugins-official` (activo a nivel de usuario) y corrían dos servers por
  sesión. No lo re-añadas; lo mismo aplica antes de añadir cualquier MCP que ya exista como
  plugin oficial.

## Convenciones

Commits en español, conventional con scope cuando aplique (`feat:`, `fix(hooks):`). Se trabaja
contra `main` (repo pequeño, un solo mantenedor); el guardarraíl real es la validación local de
arriba + el version bump. Comentarios de los scripts en español, explicando el *porqué*.
