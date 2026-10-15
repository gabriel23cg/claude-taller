#!/usr/bin/env bash
# Descompone una URL de Postgres para el túnel de la máquina de salto. La usan el launcher
# (para abrir el túnel y reescribir la URL) y el doctor (para avisar antes de que falle):
# vive aquí para que los dos apliquen exactamente las mismas reglas.
#
# Uso:    . scripts/lib/pg-url.sh; pg_url_partes "$url" || echo "$PG_MOTIVO"
# Salida: PG_ESQUEMA (postgresql://), PG_USUARIO (usuario[:clave]@ o vacío), PG_HOST,
#         PG_PUERTO (5432 si no viene) y PG_RESTO (/bd?parámetros o vacío).
# Solo se admite un host y sin host/hostaddr/port en los parámetros: con varios hosts no hay
# un único destino para el túnel, y esos parámetros pisarían el del túnel.
# Compatible con el bash 3.2 de macOS.

pg_url_partes() {
  PG_ESQUEMA='' PG_USUARIO='' PG_HOST='' PG_PUERTO='' PG_RESTO='' PG_MOTIVO=''
  # BASH_REMATCH: 1 esquema · 3 usuario@ · 4 host · 6 puerto · 7 /bd?parámetros
  local re='^(postgres(ql)?://)([^@/?]*@)?([^:/?@,]+|\[[^]/]+\])(:([0-9]+))?([/?].*)?$'
  if [[ ! "$1" =~ $re ]]; then
    PG_MOTIVO="URL no reconocida, sin host o con varios hosts"
    return 1
  fi
  PG_ESQUEMA=${BASH_REMATCH[1]} PG_USUARIO=${BASH_REMATCH[3]:-} PG_HOST=${BASH_REMATCH[4]}
  PG_PUERTO=${BASH_REMATCH[6]:-5432} PG_RESTO=${BASH_REMATCH[7]:-}
  local re_param='[?&](host|hostaddr|port)='
  if [[ "$PG_RESTO" =~ $re_param ]]; then
    PG_MOTIVO="trae ${BASH_REMATCH[1]}= en los parámetros"
    return 1
  fi
  return 0
}
