---
name: open-pr
description: Abre un PR enlazado a su issue siguiendo las convenciones del repo, con los gotchas de gh aprendidos - Closes #N en texto plano y línea propia, labels en el propio gh pr create, verificación de closingIssuesReferences. Genérico, lee las convenciones del repo en vez de darlas por supuestas. Úsala cuando el trabajo esté listo y haya que abrir el PR; para rematarlo después, /land-pr.
disable-model-invocation: false
---

# /open-pr — Abrir el PR enlazado a su issue

Paso del ciclo entre `/check-work` y `/land-pr`. Evita el error clásico: que `Closes #N` no
enlace (por backticks, por ir en un bullet con texto detrás, o por usar `Refs`) y el PR
quede huérfano de su issue, que se queda abierto para siempre.

## Precondición

Estás en la rama de trabajo (no en la base) con el cambio commiteado y **`/check-work` en
LISTO** o LISTO CON RESERVAS. Si no lo has pasado, pásalo: abrir un PR que no valida gasta
un ciclo de CI y el tiempo de quien revise.

Si no hay rama todavía, la convención de nombre está en `.claude/flujo-github.md` (la
mantiene `/work-issue`):

```bash
git checkout <base> && git pull --ff-only && git checkout -b <rama>
```

## Pasos

1. **Push** de la rama: `git push -u origin "$(git branch --show-current)"`.

2. **Cuerpo del PR** en un fichero temporal. El keyword de cierre va en **TEXTO PLANO, en
   su propia línea**, uno por issue que cierre:

   ```
   Closes #N
   ```

   NO uses backticks (`` `Closes #N` `` lo desactiva) ni lo metas en un bullet con texto
   detrás (`- Closes #N — ...` puede no reconocerse). El keyword va **en inglés**
   (`Closes`/`Fixes`/`Resolves`; «Cierra #N» no funciona), y el issue ha de estar en el
   mismo repo o referenciado como `owner/repo#N`.

   **Un PR puede cerrar varios issues**: una línea por cada uno. Cuando sea el caso:

   - **el nombre de la rama no puede mentir**. Si la convención del repo es
     `issue-<N>-...`, una rama que cierra tres issues necesita un nombre temático o que los
     lleve a todos; mira qué hace el repo (`.claude/flujo-github.md`) y, si no lo cubre, usa
     algo descriptivo del cambio en vez del número de uno solo.
   - **el cuerpo dice qué parte cubre cada issue**, para que la revisión pueda ir por
     partes en vez de tener que reconstruirlo del diff.

   Contenido: qué hace, cómo se ha comprobado, y la documentación viva actualizada. Las
   **reservas** que devolviera `/check-work` van aquí, no en tu cabeza: quien revisa las
   necesita.

   Si el repo trae plantilla (`.github/pull_request_template.md`, `.github/PULL_REQUEST_TEMPLATE/`),
   úsala como estructura y rellénala.

3. **Crear el PR CON sus labels.** `gh pr create` **no** las añade solo, así que van en el
   `--label` del propio comando: si no, el PR nace sin etiquetar y es fácil olvidarlo. Qué
   labels exige el repo está en `.claude/flujo-github.md` o en su `CONTRIBUTING.md`.

   ```bash
   gh pr create --base "<base>" --head "$(git branch --show-current)" \
     --title "..." --label "<labels coma-separadas>" --body-file <fichero>
   ```

   Si el trabajo aún no está para revisión, `--draft`.

4. **VERIFICAR enlace de cierre Y labels** (obligatorio):

   ```bash
   gh pr view <N> --json closingIssuesReferences,labels
   ```

   - `closingIssuesReferences` vacío (`[]`) → el keyword está mal formateado → corrige el
     cuerpo (`gh pr edit <N> --body-file ...`) y reverifica.
   - **con varios issues, cuéntalos**: que enlace dos de tres es el fallo silencioso, porque
     el PR parece correcto y el tercero se queda abierto para siempre.
   - `labels` sin las que exige el repo → `gh pr edit <N> --add-label "..."`.

   El hook `pr-closes-issue-check` de este plugin cubre este paso cuando el PR se crea sin
   la skill, pero solo avisa: corregirlo sigue siendo trabajo tuyo.

5. **Encadenar con `/land-pr`**, que es quien vigila CI, atiende la revisión, mergea (con
   confirmación) y cierra el ciclo. **Esta skill no mergea ni espera a CI**: su trabajo
   termina con el PR abierto, enlazado y etiquetado.

## Notas

- **Documentación viva en el MISMO PR**: README, `docs/` y `CLAUDE.md` afectados. Si no
  entró, `/check-work` debería haberlo cantado.
- Un PR sin issue detrás es legítimo (un arreglo de dos líneas), pero es la excepción: si
  el trabajo merece discusión o seguimiento, primero `/gh-create-issue`.
- Los agentes de revisión del repo se pasan **antes** de abrir el PR, vía `/check-work`, no
  después: el objetivo es que quien revise no encuentre lo que una máquina ya podía ver.
