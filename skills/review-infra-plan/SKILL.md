---
name: review-infra-plan
description: Localiza el plan de Terraform de un PR o run de CI (job de plan del workflow de infra), extrae su log y lo pasa al agente terraform-plan-reviewer contra los invariantes del repo (.claude/plan-invariantes.md). Úsalo antes de aprobar un apply o al revisar un PR de infra. Nunca mergea ni aplica.
disable-model-invocation: false
---

# /review-infra-plan — Revisar el plan de Terraform de un PR/run

Empaqueta el ritual común de los repos de infra: esperar al plan de CI, leer el plan
del **log** (el check verde no basta: verde solo significa que el plan se generó sin
error, no que sea seguro) y pasar el veredicto por `terraform-plan-reviewer`.

## Entrada

Un número de PR, un run id del workflow de infra, o nada (usa el PR de la rama actual:
`gh pr view --json number`).

## Pasos

1. **Localiza el run de plan**:
   - Con PR: `gh pr checks <N>` → run del workflow de infra (`infra.yml`).
   - Con run id: úsalo directo.
   - Si el check aún corre, espera a que termine: `gh run watch <run-id>`.
   - Si el run falló, informa del fallo y para: no hay plan que revisar.

2. **Extrae el log del job de plan** (normalmente `Plan (prod)`):
   ```bash
   gh run view <run-id> --json jobs   # localizar el job-id del job de plan
   gh run view <run-id> --log --job <job-id>
   ```

3. **Lanza el subagente `terraform-plan-reviewer`** (de este plugin) con el log del plan
   como entrada. El agente lee `.claude/plan-invariantes.md` del repo y devuelve el
   veredicto **SEGURO / REVISAR / NO APLICAR**, con cada destroy/replace justificado
   (recurso, causa, riesgo) y los invariantes tocados.

4. **Reporta** el veredicto y las acciones previas requeridas. **NO mergees el PR ni
   lances el apply**: el dispatch de apply (`workflow_dispatch action=apply` con
   `plan_run_id`, sobre `main`) es la aprobación humana y queda fuera de esta skill.
