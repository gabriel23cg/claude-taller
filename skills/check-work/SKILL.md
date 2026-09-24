---
name: check-work
description: Comprueba que el trabajo en curso está de verdad listo antes de abrirlo a revisión. Corre la validación que declare el repo, pasa los agentes de revisión que el repo defina, relee el diff en contra y contrasta lo hecho con lo que pedía el issue. Genérico, descubre comandos y agentes del repo en vez de asumirlos. Úsala antes de /open-pr, antes de pedir revisión, o cuando se pregunte si esto está listo o si falta algo.
disable-model-invocation: false
---

# /check-work — ¿Esto está listo?

Paso del ciclo entre implementar y `/open-pr`. Es el que más se salta y el que más cuesta
saltarse: un PR que nace en rojo o al que le falta la mitad del issue gasta un ciclo de
revisión entero y la paciencia de quien revisa.

No arregla nada por su cuenta salvo lo que el propio validador autoarregle (formato). Su
producto es un **veredicto**.

## Paso 1 — Qué ha cambiado

```bash
BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)
git status --short
git diff "origin/$BASE...HEAD" --stat
git diff --stat            # lo que aún no está commiteado
```

Trabajo sin commitear es parte del cambio: o entra, o se dice que se queda fuera.

## Paso 2 — La validación del repo: descúbrela, no te la inventes

Un comando inventado que pasa no valida nada. Busca en este orden y **para en la primera
fuente que lo declare**:

1. `.claude/flujo-github.md` → sección «Validación» (lo que ya se descubrió antes).
2. `CLAUDE.md` del repo.
3. `CONTRIBUTING.md`.
4. `Makefile` / `justfile` (objetivos `test`, `check`, `lint`), `package.json` (`scripts`),
   `pyproject.toml` / `tox.ini` / `noxfile.py`, `.pre-commit-config.yaml`.
5. **`.github/workflows/*.yml` — la fuente de verdad.** Lo que CI ejecuta es lo que se
   exige; lo de arriba son atajos que pueden estar desfasados. Si un atajo y el workflow no
   coinciden, manda el workflow, y la discrepancia es un hallazgo que merece decirse.

Si no encuentras nada, **no te calles**: «este repo no declara validación» es un resultado,
y con él lo único honesto es correr lo que exista (tests si los hay) y decir hasta dónde
llega la comprobación.

Corre lo que hayas encontrado. Si falla, para aquí: no tiene sentido revisar a fondo un
árbol que no compila.

**Si el repo mide cobertura, corre los tests CON ella** (`--cov`, `--coverage`, el flag que
use): además de darte el dato, deja el informe fresco para que el hook `coverage-report`
diga la verdad en vez de la cifra de hace tres commits.

## Paso 3 — Los agentes de revisión que defina el repo

El plugin no sabe qué hay que vigilar en este repo; el repo sí. Míralos:

```bash
ls .claude/agents/ 2>/dev/null
ls "${CLAUDE_PLUGIN_ROOT}/agents/" 2>/dev/null
```

Más los que declare `.claude/flujo-github.md`. **Lanza solo los que apliquen al diff** —
un revisor de migraciones sobre un cambio de README es latencia pura. La regla de a qué
aplica cada uno está en la `description` del propio agente: léela, no lo adivines.

Los agentes de este plugin y su disparo:

| Agente | Lánzalo si el diff toca… |
|---|---|
| `terraform-plan-reviewer` | infraestructura como código (hay plan que revisar; vía `/review-infra-plan` si el plan lo genera CI) |
| `alembic-migration-reviewer` | una revisión de Alembic nueva o modificada |
| `test-coverage-reviewer` | código con lógica (o sus tests). Es el que dice si lo nuevo está **verificado**, no solo ejecutado |

## Paso 4 — Relee tu propio diff en contra

Con el diff delante y la pregunta «¿qué haría que esto se rechace?». Busca en concreto:

- **Restos de trabajo**: `print`/`console.log`, `TODO` recién puestos, código comentado,
  ficheros temporales, un `.only`/`skip` en un test.
- **Lo que el cambio rompe sin tocarlo**: quien llamaba a la firma que cambiaste, quien lee
  el campo que renombraste, el default que ahora es otro.
- **Secretos y datos reales**: credenciales, endpoints internos, datos de producción o
  personales en tests y fixtures. Una vez pusheado, ya está publicado.
- **Tests que acompañan al cambio**: un arreglo de bug sin test que falle antes y pase
  después es un arreglo sin garantía de que no vuelva. El hook `coverage-report` te da la
  cifra del diff al final de cada turno, pero **la cifra no es el juicio**: 100% de líneas
  ejecutadas con un test que no comprueba nada sigue siendo cero garantía, y un 60% cuyo
  resto son `raise` de validación puede estar perfectamente bien. Mira qué líneas nuevas
  quedan sin cubrir y decide una por una si merecen test.
- **Alcance**: lo que hay en el diff que el issue no pedía. O se justifica, o se saca.

## Paso 5 — Contrasta con el issue (o con todos, si son varios)

Vuelve al issue (cuerpo **y comentarios**, que es donde cambió el criterio) y haz la lista
explícita: cada cosa pedida → dónde está cubierta, o por qué no está.

**Si el trabajo cierra varios issues, la lista es por issue, no una lista común.** Un grupo
cubierto «en general» es como se cuela el tercero a medias: el diff parece completo, y lo
está para dos de los tres. Si alguno no queda cubierto, dilo por su número — sacarlo del
grupo y dejarlo para su propio PR es un desenlace perfectamente válido.

**Lo que falta se dice, no se redondea.** «Hecho salvo X, que propongo dejar para otro
issue» es un resultado perfectamente válido; «hecho» cuando falta X no lo es.

## Paso 6 — Documentación viva

Si el cambio invalida algo escrito (README, `docs/`, `CLAUDE.md`, el fichero de invariantes
del repo), se actualiza **en este mismo cambio**. Documentación que se corrige «luego» es
documentación que miente durante meses.

## Paso 7 — Veredicto

Una de estas tres, explícita, con lo que la sostiene:

- **LISTO** — validación en verde, agentes sin hallazgos bloqueantes, issue cubierto.
  Siguiente: `/open-pr`.
- **LISTO CON RESERVAS** — se puede abrir el PR, pero hay cosas que quien revise tiene que
  saber. Enuméralas: van al cuerpo del PR, no a tu cabeza.
- **NO LISTO** — validación en rojo, hallazgo bloqueante o parte del issue sin cubrir. Di
  qué falta y cuál es el siguiente paso.

Nunca «creo que está bien». Si no lo has corrido, no lo has comprobado: dilo así.

## Notas

- Es **idempotente y barata**: correrla dos veces no rompe nada. En cambios largos, vale la
  pena a mitad de camino y no solo al final.
- No mergea, no pushea y no abre PRs. Eso son `/open-pr` y `/land-pr`.
- Si el repo tiene hooks de formato (de este plugin o suyos), ya habrán actuado al editar:
  esta skill no los duplica, comprueba el resultado.
