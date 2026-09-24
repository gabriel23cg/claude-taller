---
name: land-pr
description: Lleva un PR ya abierto hasta mergeado y cierra el ciclo. Diagnostica CI en rojo leyendo el log (no el nombre del check), resuelve conflictos con la base, atiende los comentarios de revisión, mergea solo con confirmación explícita, limpia la rama y verifica que el issue quedó cerrado de verdad. Termina devolviendo al triage. Úsala cuando haya un PR abierto que rematar, cuando falle su CI o cuando llegue una revisión.
disable-model-invocation: false
---

# /land-pr — Rematar el PR y volver al triage

`/open-pr` abre; esta cierra. Un PR abierto no es trabajo hecho: es trabajo en
consignación. Lo que se acumula aquí —CI en rojo que nadie mira, un comentario sin
responder, una rama en conflicto con la base— es lo que hace que el ciclo deje de girar.

## Entrada

Un número de PR, o nada (el PR de la rama actual).

## Paso 1 — Foto del PR, entera y de una vez

```bash
gh pr view <N> --json number,title,state,isDraft,mergeable,mergeStateStatus,reviewDecision,\
statusCheckRollup,closingIssuesReferences,labels,headRefName,baseRefName,comments,reviews
```

De ahí salen las cuatro preguntas que ordenan todo lo demás: ¿choca con la base?, ¿está
rojo?, ¿hay revisión pendiente de atender?, ¿enlaza con su issue?

## Paso 2 — Orden de trabajo

**Conflicto → CI → revisión → merge.** El orden importa: diagnosticar un CI rojo sobre una
rama desfasada de la base es perseguir un fallo que a lo mejor ya no existe, y pedir
revisión de algo que no mergea es gastar el tiempo de otro.

## Paso 3 — Conflicto con la base

```bash
git fetch origin <base>
git merge origin/<base>      # merge, NO rebase
```

- **Nunca reescribas la historia de una rama que no es tuya** (rebase, amend, force-push):
  le rompes el checkout a quien la tenga. En una rama propia, manda la convención del repo.
- **Lockfiles y ficheros generados**: se regeneran con su herramienta, nunca se resuelven a
  mano. Un lockfile editado a mano pasa CI y explota en la máquina siguiente.
- Si los dos lados cambiaron la misma lógica y elegir cualquiera pierde comportamiento,
  **para y pregunta**. Eso no es un conflicto de texto, es una decisión.

Tras resolver, revalida (`/check-work`) antes de pushear.

## Paso 4 — CI en rojo

**Lee el log, no el nombre del check.** El nombre dice qué job cayó; la causa está dentro.

```bash
gh pr checks <N>                          # qué falló (NO acepta --exit-status)
gh run view <run-id> --json jobs          # localizar el job
gh run view <run-id> --log --job <job-id> # la causa, de verdad
```

Reglas que evitan los dos errores caros:

- **Reproduce en local antes de arreglar.** Un arreglo a ciegas cuesta otro ciclo de CI
  completo y tiene la mala costumbre de funcionar por el motivo equivocado.
- **«Es un flake» no es una causa raíz.** Solo vale como diagnóstico si el fallo es previo
  a ejecutar nada (checkout, instalación de dependencias, runner caído) o si el mismo
  commit pasó antes. Un reintento, como mucho; si vuelve a caer, es real.
- **Nunca desactives, saltes ni marques como skip un test para poner el check en verde.**
  Eso no arregla el PR: le quita la alarma.
- Comprueba si el fallo **también está en la base**. Si lo está, no es de este PR: dilo,
  trae el arreglo si existe, y no ensanches este PR por el camino.

## Paso 5 — Comentarios de revisión

- **Lo pequeño y local** (nombres, un test que falta, una función que se simplifica, lo que
  diga un linter): se implementa y se pushea.
- **Lo grande** (refactor de varios ficheros, cambio de API o de esquema, feedback de
  diseño abierto): se **responde con una propuesta**; decide quien es dueño del PR. En un
  PR ajeno no se pushea eso sin permiso.
- **Resuelve los hilos que hayas atendido** y responde a los que no vayas a aplicar
  diciendo por qué. Un hilo abierto sin respuesta es una pregunta que sigue sin contestar.
- Tras pushear, vuelve a pedir revisión a quien había pedido cambios.
- Si la revisión destapa que el issue estaba mal planteado, eso no se arregla en el PR: se
  dice, y se trocea (`/gh-create-issue`).

## Paso 6 — Merge

Solo con **CI en verde** y **confirmación explícita del usuario**. Nunca de forma
autónoma, ni aunque todo esté verde y parezca obvio: el merge es la frontera entre el
trabajo y la producción de otro.

El estilo (merge / squash / rebase, borrado de rama) es del repo: `.claude/flujo-github.md`,
su `CONTRIBUTING.md`, o lo que permita la configuración del propio repo. No impongas uno.

```bash
gh pr merge <N> --<estilo> --delete-branch
```

## Paso 7 — Cerrar el ciclo de verdad

Mergear no es terminar. Lo que queda, y que casi siempre se olvida:

1. **Verifica que se cerraron TODOS los issues que el PR decía cerrar** — en plural, que un
   PR puede cerrar varios y comprobar solo el primero es no comprobar nada:
   ```bash
   for M in $(gh pr view <N> --json closingIssuesReferences --jq '.closingIssuesReferences[].number'); do
     printf '#%s %s\n' "$M" "$(gh issue view "$M" --json state --jq .state)"
   done
   ```
   El que siga abierto, ciérralo a mano diciendo qué PR lo resolvió. Y contrasta la lista
   con los issues que el trabajo *debía* cerrar: si falta alguno ahí, el enlace nunca se
   puso y el fallo es de `/open-pr`, no del merge.
2. **Vuelve a la base limpia**: `git checkout <base> && git pull --ff-only`, y borra la
   rama local si el merge no lo hizo.
3. **Si el trabajo destapó cosas nuevas** (deuda vista de paso, un fallo que no era de este
   alcance), va a issues ahora, mientras el contexto está fresco: `/gh-create-issue`.
4. **Vuelve al triage**: `/triage`. Esa es la vuelta del ciclo, y es lo que impide que el
   siguiente trabajo lo elija la inercia.

## Notas

- Un PR en borrador se marca listo (`gh pr ready <N>`) cuando `/check-work` dé LISTO, no
  antes.
- Esta skill **no revisa código**: para eso están los agentes que declare el repo, vía
  `/check-work`.
- Si el PR lleva semanas abierto y ya no tiene sentido, cerrarlo es un desenlace válido —
  con su motivo escrito. Un PR zombi cuesta más que no haberlo abierto.
