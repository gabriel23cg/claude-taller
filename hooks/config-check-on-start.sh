#!/usr/bin/env bash
# SessionStart: al abrir sesión, avisa si algo de la configuración que necesita el plugin
# está roto (scripts/doctor.sh --inicio). Solo lo roto: lo que falta y puede faltar a
# propósito —DATABASE_URL_DEV en un repo sin BD de dev— no avisa nunca aquí, que un aviso
# en cada sesión sin motivo se acaba ignorando. El repaso completo, con lo que falta y cómo
# ponerlo, es la skill /taller:doctor.
#
# Sin red y en milisegundos: la primera respuesta de la sesión espera a los SessionStart.
# Sale por JSON: systemMessage para el usuario y additionalContext para que el agente sepa
# qué está roto y pueda ofrecer /taller:doctor. Calla si todo está bien. Exit 0 siempre.

set -uo pipefail

input=$(cat)
# En un worktree, CLAUDE_PROJECT_DIR puede ser la copia principal (ver lib/dir-proyecto.sh).
dir=$(printf '%s' "$input" | "$(dirname "$0")/lib/dir-proyecto.sh")
"$(dirname "$0")/../scripts/doctor.sh" --inicio "$dir"
exit 0
