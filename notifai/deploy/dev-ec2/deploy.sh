#!/bin/sh
# Deploy de LiteLLM en el EC2 de dev.
#
# Lo corre el documento de SSM notifai-dev-deploy-litellm desde la carpeta del
# release: sh /opt/notifai/litellm/releases/<sha>/deploy.sh <sha>, con
# NOTIFAI_SERVICE_DIR y NOTIFAI_REGISTRY en el entorno. No lee el .env: solo lo
# pasa a docker compose. Runbook: notifai/deploy/dev-ec2/README.md.
#
# Salidas: 0 desplegado; 2 argumento, entorno o upstream-image.env inválido;
# 3 .env inválido; 5 el puerto quedaría publicado fuera del host (no se levantó
# nada); cualquier otra, la de la llamada a docker que falló.
set -eu

fail() {
  printf 'deploy: %s\n' "$2" >&2
  exit "$1"
}

if [ "$#" -ne 1 ]; then
  fail 2 'uso: deploy.sh <sha de 40 caracteres hexadecimales en minúscula>'
fi
sha=$1
if [ "${#sha}" -ne 40 ]; then
  fail 2 'el SHA no tiene la forma de 40 caracteres hexadecimales en minúscula'
fi
case $sha in
  *[!0-9a-f]*) fail 2 'el SHA no tiene la forma de 40 caracteres hexadecimales en minúscula' ;;
esac

if [ -z "${NOTIFAI_SERVICE_DIR:-}" ]; then
  fail 2 'falta NOTIFAI_SERVICE_DIR'
fi
if [ -z "${NOTIFAI_REGISTRY:-}" ]; then
  fail 2 'falta NOTIFAI_REGISTRY'
fi

env_file=$NOTIFAI_SERVICE_DIR/.env
if [ -L "$env_file" ] || [ ! -f "$env_file" ]; then
  fail 3 "$env_file no existe, no es un archivo regular o es un enlace simbólico"
fi
if [ -z "$(find "$env_file" -prune -perm 600)" ]; then
  fail 3 "$env_file no tiene modo 600"
fi

release_dir=$(cd "$(dirname "$0")" && pwd)
upstream_file=$release_dir/upstream-image.env
if [ ! -f "$upstream_file" ]; then
  fail 2 'falta upstream-image.env en el release'
fi
LITELLM_TAG=$(sed -n 's/^LITELLM_TAG=//p' "$upstream_file")
case $LITELLM_TAG in
  ''|*[!0-9a-z.-]*) fail 2 'LITELLM_TAG de upstream-image.env no es un tag válido' ;;
esac

IMAGE_TAG=$sha
export IMAGE_TAG LITELLM_TAG NOTIFAI_REGISTRY NOTIFAI_SERVICE_DIR

compose() {
  docker compose --project-name notifai-litellm --env-file "$env_file" -f "$release_dir/docker-compose.yml" "$@"
}

# Antes de levantar nada: todo puerto publicado tiene que llevar una dirección del
# host que no sea la de todas las interfaces. Compose resuelve NOTIFAI_BIND_ADDR
# desde el .env; config con --no-env-resolution no vuelca las variables del
# env_file y la salida no se imprime. Si la versión de Compose no acepta la
# opción, el deploy se detiene.
rendered=$(compose config --no-env-resolution 2>/dev/null) || fail 5 'no se pudo renderizar el compose con config --no-env-resolution; no se levantó nada'
published=$(printf '%s\n' "$rendered" | grep -c '^[[:space:]]*published:' || true)
bound=$(printf '%s\n' "$rendered" | sed -n 's/^[[:space:]]*host_ip:[[:space:]]*//p' | tr -d "\"'" | grep -vcE '^(|0\.0\.0\.0|::|\[::\])$' || true)
if [ "$published" -lt 1 ] || [ "$published" -ne "$bound" ]; then
  fail 5 'un puerto publicado no tiene una dirección del host distinta de todas las interfaces; no se levantó nada'
fi

compose pull
compose up -d --wait --remove-orphans

printf '%s\n' "$sha" > "$NOTIFAI_SERVICE_DIR/current.tmp"
mv "$NOTIFAI_SERVICE_DIR/current.tmp" "$NOTIFAI_SERVICE_DIR/current"
