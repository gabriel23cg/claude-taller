---
name: triage
description: Decide por dónde seguir. Revisa todos los issues abiertos de un repo (o de varios a la vez) y devuelve una recomendación argumentada, delegando la lectura pesada en el agente backlog-triage para no quemar contexto. Es la entrada y la vuelta del ciclo de trabajo. Úsala cuando se pregunte qué hago ahora, por dónde sigo, qué hay pendiente, cómo está el backlog, o al terminar un PR.
disable-model-invocation: false
---

# /triage — Por dónde seguir

Primera y última parada del ciclo:

```
/triage → /work-issue → implementar → /check-work → /open-pr → /land-pr ─┐
   ↑                                                                     │
   └─────────────────────────────────────────────────────────────────────┘
        /gh-create-issue alimenta el backlog que lee /triage
```

El backlog no se mira: se sabe. Y lo que se sabe está desfasado — el issue que crees
urgente lleva un comentario de hace tres semanas diciendo que ya no aplica. Esta skill
existe para que la decisión salga de leer, no de recordar.

## Entrada

Nada (repo actual), una lista de repos, o un filtro en lenguaje natural («algo corto»,
«lo que desbloquee a alguien», «solo infra»).

## Pasos

1. **Ámbito.** Sin argumentos, el repo actual (`gh repo view --json nameWithOwner`).

   Si el trabajo se reparte entre varios repos, **pregunta una vez si el ámbito es solo
   este o todos** — la respuesta cambia por completo la recomendación, y `gh` no necesita
   clonarlos: le vale `--repo owner/nombre`. Si el usuario ya lo dijo, no repreguntes.

2. **Lanza el agente `backlog-triage`** (de este plugin) con el ámbito y el filtro. Él
   descubre qué señales de prioridad tiene el repo, lee el backlog, descarta lo que no es
   candidato y devuelve la recomendación.

   **No hagas tú el barrido.** Si te pones a `gh issue view` uno por uno te comes el
   contexto que hace falta luego para implementar — que es justo lo que el agente evita.

3. **Presenta el veredicto tal cual**, sin reordenarlo ni ampliarlo. Si discrepas de la
   recomendación con un dato que el agente no podía tener (algo que se habló en esta
   sesión, una urgencia de hace diez minutos), dilo como corrección explícita: «el agente
   recomienda X; yo iría a Y porque <dato>». No lo maquilles.

4. **Encadena.** Confirmado el issue, sigue con `/work-issue <N>`, que es quien lee el
   issue entero y prepara el terreno. Esta skill **no** implementa, no abre ramas y no
   comenta en GitHub.

   Si el usuario decide llevarse **varios** de la recomendación, no presupongas el reparto:
   `/work-issue` vuelve a lanzar el agente en **modo agrupación** para evaluar cuáles van en
   un mismo PR y cuáles separados, y lo propone. Puedes adelantarlo aquí si ya viste señales
   claras (se pisan los mismos ficheros, uno no compila sin el otro), pero la decisión es
   del usuario, no tuya.

## Cuándo NO usar esta skill

- Ya sabes qué issue vas a hacer → `/work-issue <N>` directo.
- Quieres el estado de un PR, no del backlog → `/land-pr`.
- No hay issue y el trabajo es nuevo → `/gh-create-issue` primero: lo que no está en el
  backlog no existe para el triage de la semana que viene.

## Notas

- **El triage es barato y las notas mentales caras.** Correrlo al terminar cada PR cuesta
  una llamada y evita la deriva clásica: seguir picando en el área cómoda mientras lo
  urgente envejece.
- Un backlog que el agente devuelve como «nada claramente primero» no es un fallo del
  agente: es la señal de que toca **afinar el backlog** (poner prioridades, trocear lo
  difuso, cerrar lo muerto), y eso es trabajo legítimo de un rato.
- Si el agente marca issues sin criterio de aceptación o duplicados, arreglarlo ahí mismo
  (`/gh-create-issue` para los troceos) sale más barato que volver a tropezar con ellos.
