---
name: doctor
description: Comprueba que la configuración que necesita el plugin en este repo y en esta máquina está completa y funciona —las URLs de Postgres (con conexión real, por la máquina de salto si la hay, y si el rol de prod es de lectura), uvx, Docker y az para los MCP, y jq, gh, uv y terraform para los hooks—; explica qué falta y cómo se pone, rellena la configuración con lo que pueda descubrir del repo y la aplica con tu confirmación. Úsala al poner el plugin en un repo o en una máquina nuevos, cuando un MCP no arranque, cuando el aviso de inicio de sesión lo pida, o cuando se pregunte si el plugin está bien configurado.
disable-model-invocation: false
---

# /doctor — ¿Está bien configurado el plugin aquí?

Casi todo lo que el plugin necesita falla **en silencio**: un MCP sin su variable solo se ve
en `/plugin` → Errors, y un hook sin su herramienta no hace nada. Esta skill lo comprueba,
dice qué falta y cómo se pone, y lo deja puesto. El objetivo es que nadie tenga que
acordarse de memoria de cómo se llama una variable ni en qué fichero va.

No es un paso del ciclo: se usa al poner el plugin en un repo o una máquina nuevos, y
cuando el hook de inicio de sesión avisa de que algo está roto.

## 1. Diagnosticar

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" "$(pwd)"
```

Hace el repaso completo, con red: entra por SSH en la máquina de salto si la hay y abre una
conexión real a cada BD con el **mismo launcher que usa el MCP**. Devuelve líneas `FALLO`,
`AVISO`, `INFO` y `OK`, cada una con cómo arreglarla debajo. Nunca imprime una URL, porque
llevan la clave; tú tampoco.

Resume al usuario primero los `FALLO`, después los `AVISO`, y los `INFO` en una línea. Para
cada uno, di en una frase **qué deja de funcionar** («postgres-prod no arrancará»), no solo
qué falta.

## 2. Proponer el arreglo, rellenado

La salida trae la forma genérica (`<servidor>`, `<bd>`, `<rol-lectura>`). No la pegues tal
cual: **descubre lo que puedas del repo** y deja como hueco solo lo que no se puede saber.

| Dato | Dónde buscarlo |
|---|---|
| `<servidor>` | `infra/`: `azurerm_postgresql_flexible_server` (el FQDN es `<name>.postgres.database.azure.com`), sus `output` o los `tfvars` por entorno; o el `.env.example`/README del repo |
| `<bd>` | `alembic.ini`/`env.py`, la config de la app, `azurerm_postgresql_flexible_server_database` |
| `<rol-lectura>` | Grants y roles en migraciones o en Terraform, `.claude/migraciones-invariantes.md`, README |
| `<puerto>` de dev | `docker-compose*.yml` del repo (el puerto publicado del servicio de Postgres) |
| Máquina de salto | `~/.ssh/config` (un `Host` que apunte a la red de la BD), o pregunta |

Reglas para escribir:

- **`DATABASE_URL_PROD` va en `.claude/settings.local.json`**, que no se versiona.
  Compruébalo antes con `git check-ignore -q .claude/settings.local.json`; si no está
  ignorado, añádelo al `.gitignore` primero. **Nunca en `settings.json`.**
- **La clave no la escribes tú**: pídesela al usuario o deja `<clave>` y dile dónde ponerla.
  No la repitas en el chat.
- **Prod con un rol de lectura**, nunca el admin. Es una opinión del plugin y no se relaja
  aquí. Solo el repo que administra el propio servidor tiene la excepción, y la documenta él.
- **Une el JSON, no lo sobrescribas**: lee el fichero, añade la clave dentro de `"env"` y
  conserva lo demás. Un `settings*.json` roto desactiva toda su configuración sin avisar.
- **Fuera del repo** (`~/.ssh/config`, instalar herramientas) solo con confirmación
  explícita, y enseñando antes el cambio exacto.
- **Lo que necesita un terminal lo lanza el usuario**: `ssh-add` con passphrase, la primera
  conexión SSH que pide aceptar la huella, `gh auth login`, `az login`. Dale el comando
  exacto para su sistema (`uname`) y espera a que confirme.

Enseña el cambio completo (el bloque JSON resultante, con la clave tapada) y aplícalo solo
con el OK del usuario.

## 3. Volver a comprobar

Repite el paso 1 tras los cambios. Lo que dependa de variables de entorno o de los MCP **no
se ve hasta reiniciar la sesión**: el MCP las lee al arrancar. Dilo cuando toque, en vez de
dar por arreglado lo que esta sesión todavía no puede ver; el doctor lo marca como `INFO`
(«está en … pero esta sesión no la tiene»).

Termina con una línea: qué ha quedado arreglado, qué queda pendiente del usuario (un
`ssh-add`, un reinicio) y qué es opcional y se ha dejado a propósito.

## Lo que esta skill no hace

- **No relaja opiniones del plugin** (rol de lectura en prod, apply solo por CI).
- **No crea los ficheros por repo** (`flujo-github.md` y los de invariantes): tienen sus
  dueños, y ninguno es un requisito previo.
- **No toca la instalación del plugin** (marketplace, auto-update): eso está en el README.
