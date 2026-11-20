# LiteLLM en el EC2 de dev

Runbook del despliegue de LiteLLM al entorno de dev, que corre con Docker Compose en la misma instancia EC2 donde ya corren Chatwoot y voicebot. Es un despliegue independiente: vive en este repo (el fork `Notifai-Team1/notifai-litellm`), no pasa por el CD de voicebot ni por el de Chatwoot y no compila LiteLLM. Esta carpeta es lo único propio de Notifai en el fork; el código de LiteLLM no se toca y no es lo que se despliega. Los valores de las variables los carga un humano y no van en ningún archivo, issue ni PR.

| Archivo | Qué es |
|---|---|
| [`.github/workflows/notifai-deploy-dev.yml`](../../../.github/workflows/notifai-deploy-dev.yml) | Workflow `Notifai deploy a dev` |
| [`docker-compose.yml`](docker-compose.yml) | Servicio `litellm`, con la memoria limitada y un solo worker |
| [`litellm-config.yaml`](litellm-config.yaml) | Ruteo por comodines por proveedor |
| [`upstream-image.env`](upstream-image.env) | Tag y digest de la imagen oficial; única fuente de la versión |
| [`deploy.sh`](deploy.sh) | Script que corre en el host |
| [`bundle.Dockerfile`](bundle.Dockerfile) | Imagen `FROM scratch` que lleva el compose, la config y el script al host |
| [`.env.example`](.env.example) | Nombres de las variables del `.env` del host, sin valores |

## Versión de LiteLLM

Imagen oficial `ghcr.io/berriai/litellm`, tag `1.108.13-lts`, fijada también por digest en `upstream-image.env`.

- **Por qué esa.** `lts` es la línea de soporte largo de la imagen oficial: recibe parches de la 1.108 sin cambios de funcionalidad. El tag `1.108.13-lts` y el tag `1.108.13` apuntan al mismo digest. Las otras opciones se descartaron así: el sufijo `-stable` terminó en `v1.83.14-stable` (publicada el 2026-05-02, de otra numeración) y `main-stable` es un tag móvil que hoy apunta a la 1.110.2.
- **Cómo se verificó.** Se leyó el registro de GHCR de forma anónima el 2026-11-20 (lista de tags, digest y fecha de construcción). `1.108.13-lts` se construyó el 2026-11-20 a las 03:53 UTC. Si se prefiere un parche con más días en el registro, `1.108.12-lts` es el anterior de la misma línea.
- **Por qué el digest.** El tag de una imagen oficial puede moverse; con el digest, ECR siempre recibe el mismo contenido y el workflow falla si `litellm-dev:<tag>` ya existe con otro digest.
- **Cómo se cambia de versión.** Se edita `upstream-image.env` con el tag nuevo y su digest (`docker buildx imagetools inspect ghcr.io/berriai/litellm:<tag> --format '{{.Manifest.Digest}}'`) y se hace merge a `litellm_internal_staging`.

## Qué despliega y cuándo

El workflow `Notifai deploy a dev` corre en cada push a `litellm_internal_staging` que cambie `notifai/**` o el propio workflow, y a demanda con `workflow_dispatch`. Las corridas no se pisan: van en serie en el grupo `notifai-deploy-dev`. Un `workflow_dispatch` o el reintento de una corrida despliega el commit de esa corrida, que tiene que ser ancestro de `litellm_internal_staging`.

El job `deploy`, en el environment `dev`:

1. Valida el SHA, que estén los cinco archivos de esta carpeta y que `upstream-image.env` tenga una línea `LITELLM_TAG` (versión `X.Y.Z` o `X.Y.Z-lts`) y una `LITELLM_DIGEST`.
2. Pide credenciales de AWS por OIDC con el rol de `NOTIFAI_DEV_DEPLOY_ROLE`, sin claves de larga vida.
3. Copia la imagen oficial a ECR como `litellm-dev:<tag>` con `docker buildx imagetools create`, que conserva todas las plataformas, y comprueba que el digest en ECR es el fijado. Si el tag ya está publicado con ese digest, no copia otra vez.
4. Publica el bundle `litellm-deploy-dev:<sha>` (compose, config, `upstream-image.env` y `deploy.sh`), salvo que ya exista.
5. Corre el documento de SSM `notifai-dev-deploy-litellm` con el parámetro `Sha` en la instancia de `NOTIFAI_DEV_INSTANCE_ID`, espera el final y falla si el estado no es `Success`. Imprime solo el ID del comando, el estado y el código de respuesta.

En el host, el documento de SSM baja `litellm-deploy-dev:<sha>`, copia su `/bundle` a `/opt/notifai/litellm/releases/<sha>/` y corre `deploy.sh <sha>` con `NOTIFAI_SERVICE_DIR=/opt/notifai/litellm` y `NOTIFAI_REGISTRY`. `deploy.sh`, con el proyecto de Compose `notifai-litellm`:

1. Valida el SHA, las dos variables, que `/opt/notifai/litellm/.env` es un archivo regular con modo 600 (no un enlace simbólico) y que `upstream-image.env` trae un tag válido.
2. Comprueba, antes de levantar nada, que todo puerto publicado tiene una dirección del host distinta de todas las interfaces (ver más abajo).
3. Baja la imagen (`pull`) y levanta el servicio (`up -d --wait --remove-orphans`). Las migraciones de la base de LiteLLM las corre LiteLLM al arrancar; por eso no hay un servicio `migrate`.
4. Solo si el `up` termina bien, escribe el SHA en `/opt/notifai/litellm/current`.

| Código de salida de `deploy.sh` | Significado |
|---|---|
| 0 | Desplegado; `current` tiene el SHA |
| 2 | El argumento no es un SHA válido, falta `NOTIFAI_SERVICE_DIR` o `NOTIFAI_REGISTRY`, o `upstream-image.env` falta o tiene un tag inválido |
| 3 | El `.env` no existe, es un enlace simbólico o su modo no es 600 |
| 5 | El puerto quedaría publicado en todas las interfaces, o Compose no pudo renderizarse con `config --no-env-resolution`; no se levantó nada |
| Otro | El de la llamada a `docker` que falló; `current` no cambia |

## Cómo se alcanza y por qué no hay entrada desde internet

Qué se verificó en los repos hermanos (lectura de `voicebot-typesafe@develop` y `jvp_chatwoot@dev-notifai`):

- **Verificado.** Ningún compose de dev declara `extra_hosts`, `host.docker.internal`, `host-gateway` ni redes externas compartidas: cada proyecto (`notifai-voicebot`, `notifai-chatwoot`) usa su red por defecto. Quien tiene un servicio hacia afuera lo publica como `${NOTIFAI_BIND_ADDR}:${PUERTO}:<puerto del contenedor>` (voicebot `deploy/dev-ec2/docker-compose.yml:74-75`; Chatwoot `docker/dev-ec2/docker-compose.yml:28-29`), con la dirección y el puerto en el `.env` del host y sin valor por defecto. La base y Redis se alcanzan por URL del `.env` (`DATABASE_URL`, `REDIS_URL`): Chatwoot usa la base y el Redis de la instalación directa (`docker-compose.yml:3`) y voicebot una base de la RDS compartida (`README.md:54`).
- **Pregunta abierta.** Qué valores concretos tienen `NOTIFAI_BIND_ADDR`, los puertos y las URL en el `.env` del host, y si el Postgres del host escucha en todas las interfaces: no están en los repos y no hay acceso a la instancia. Los datos de puertos y de Postgres del encargo (dos servicios en el loopback del host y Postgres en todas las interfaces) no se pudieron comprobar aquí.

Por eso LiteLLM usa **la misma vía que los hermanos**: un puerto publicado en `${NOTIFAI_BIND_ADDR}:${LITELLM_PORT}`, con ambas variables en el `.env` del host y la misma variable `DATABASE_URL` hacia la base. Los consumidores (Chatwoot y el motor de voicebot) llegan por esa dirección y ese puerto, igual que hoy.

Qué valor de `NOTIFAI_BIND_ADDR` poner (lo decide un humano en el host):

- **La dirección del puente `docker0` del host** (`ip -4 addr show docker0`) si los consumidores son contenedores. Es una dirección local del host, en un puente privado sin salida a internet; por diseño de Docker los contenedores de cualquier proyecto de Compose la alcanzan (**Inferencia**: confirmar con el `curl` del paso 7 desde un contenedor de Chatwoot y de voicebot). Para Chatwoot en instalación directa (proceso del host) también sirve.
- **El loopback del host** solo si todos los consumidores son procesos del host: un contenedor no alcanza el loopback del host.
- **Nunca** todas las interfaces.

Por qué no se puede entrar desde internet, en capas:

1. `NOTIFAI_BIND_ADDR` no tiene valor por defecto (`${NOTIFAI_BIND_ADDR:?}`): sin él, `docker compose` falla.
2. `deploy.sh` renderiza el compose con `config --no-env-resolution` y rechaza el deploy (código 5) si algún puerto publicado no lleva dirección del host o lleva la de todas las interfaces, antes de levantar nada.
3. No se agrega ningún `location` ni `upstream` del nginx del host hacia LiteLLM.
4. El security group de la instancia no debe tener una regla de entrada para `LITELLM_PORT` (paso de verificación abajo; **Inferencia** hasta que DevOps lo confirme, no hay acceso a AWS aquí).

## Precondiciones del host

- Docker Engine con el plugin de Compose (que acepte `config --no-env-resolution`) y el agente de SSM, ya instalados para voicebot y Chatwoot.
- La carpeta `/opt/notifai/litellm/` y su `.env` con modo 600, creados por un humano.
- Una base `litellm` **aparte** en el Postgres de dev, con su propio rol (dueño de esa base, porque LiteLLM crea sus tablas al arrancar) y sin acceso a las bases de Chatwoot ni de voicebot. `DATABASE_URL` del `.env` apunta a ella y tiene que ser alcanzable desde un contenedor.

## Pasos humanos y de DevOps

Hasta que no estén, el primer deploy falla en el paso de credenciales o en SSM, sin tocar el host.

1. **ECR (DevOps).** Crear los repositorios `litellm-dev` y `litellm-deploy-dev`, con tags inmutables, igual que los de voicebot en `notifai-infra/cloudformation/dev-deploy.yaml`.
2. **Perfil de la instancia (DevOps).** Agregar a `notifai-dev-ec2` el permiso de bajar de esos dos repositorios (las mismas acciones de lectura que ya tiene para los de voicebot y Chatwoot).
3. **Confianza OIDC y rol de deploy (DevOps).** Un rol para este repo de GitHub, con confianza OIDC limitada al environment `dev` de `Notifai-Team1/notifai-litellm` y los mismos permisos que el rol de voicebot: `ecr:GetAuthorizationToken`, escritura y lectura de ECR sobre `litellm-dev` y `litellm-deploy-dev`, `ssm:SendCommand` sobre el documento del paso 4 y sobre las instancias con la etiqueta `NotifaiDeployTarget=dev`, y `ssm:GetCommandInvocation`.
4. **Documento de SSM (DevOps).** `notifai-dev-deploy-litellm`, copia del de voicebot con parámetro `Sha` (40 hexadecimales), carpeta `/opt/notifai/litellm` e imagen `litellm-deploy-dev:<Sha>`. Estos cuatro pasos son cambios en `notifai-infra`, fuera de este PR.
5. **GitHub (humano).** Crear el environment `dev` en este repo, limitado a la rama `litellm_internal_staging`, con las variables `NOTIFAI_DEV_DEPLOY_ROLE`, `NOTIFAI_DEV_AWS_REGION` y `NOTIFAI_DEV_INSTANCE_ID` (mismos nombres que en voicebot; las variables de GitHub son por repo). El deploy no usa secretos de GitHub.
6. **Host (humano).** Crear `/opt/notifai/litellm/` y su `.env`, con modo 600, con estos nombres (los valores no se versionan):

   | Variable | Para qué |
   |---|---|
   | `NOTIFAI_BIND_ADDR` | Dirección del host donde se publica el puerto (ver arriba) |
   | `LITELLM_PORT` | Puerto del host, distinto de los que ya usan los otros servicios |
   | `DATABASE_URL` | Conexión a la base `litellm` del Postgres de dev |
   | `LITELLM_MASTER_KEY` | Clave maestra del proxy; tiene que empezar con `sk-`. La misma que Chatwoot carga como `LITELLM_MASTER_KEY` |
   | `LITELLM_SALT_KEY` | Sal con la que LiteLLM cifra lo que guarda en la base; se define antes del primer uso y no se cambia después |
   | `OPENAI_API_KEY` | Modelos `gpt-*`, `text-embedding-*`, `whisper-*` y `tts-*` |
   | `GEMINI_API_KEY` | Modelos `gemini-*` |
   | `ANTHROPIC_API_KEY` | Modelos `claude-*` |
   | `COHERE_API_KEY` | Rerank (`rerank-*`) |

   Un proveedor sin clave solo falla cuando alguien pide un modelo suyo: LiteLLM no se cae.
7. **Primer deploy.** Hacer merge a `litellm_internal_staging` o lanzar `Notifai deploy a dev` con `workflow_dispatch`. Comprobar que la corrida termina en verde, que `/opt/notifai/litellm/current` tiene el SHA y que `curl` a `http://<NOTIFAI_BIND_ADDR>:<LITELLM_PORT>/health/liveliness` desde el host responde 200.
8. **Consumidores.** Después del primer deploy verde, los pasos de la sección siguiente.

## Qué configurar en Chatwoot y en el motor

Chatwoot dev (`.env` del host de Chatwoot; `app/services/llm/config.rb:30,34`):

- `LITELLM_PROXY_URL=http://<NOTIFAI_BIND_ADDR>:<LITELLM_PORT>`, sin barra final y con los valores de LiteLLM de arriba.
- `LITELLM_MASTER_KEY`: el mismo valor que el `LITELLM_MASTER_KEY` de LiteLLM. Chatwoot crea equipos y claves virtuales con `/team/new` y `/key/generate`, que necesitan la base de LiteLLM (`app/services/llm/lite_llm_admin_client.rb:11-23`).
- Opcionales: `LITELLM_ALLOWED_MODELS`, `LITELLM_EMBEDDING_MODELS`, `LITELLM_RERANK_MODELS` y `LITELLM_AUDIO_MODELS` (`config.rb:46-65`). Los modelos por defecto de Chatwoot (`gpt-4.1`, `gpt-4o-mini`, `gpt-5.5`, `gemini-2.5-pro`, entre otros) quedan cubiertos por los comodines `gpt-*` y `gemini-*`.

Motor de voicebot dev (`.env` del host de voicebot):

- `AI_GATEWAY=litellm`. El motor no tiene una variable con la URL del proxy: la recibe de Chatwoot en la respuesta de C-30 (`proxy_url`, `backend/app/application/ai/gateway.py:33-34`; `architecture/data-contracts.md:324-330`), así que ve a LiteLLM por la misma dirección que Chatwoot y esa dirección tiene que ser alcanzable desde el contenedor del motor. Con `AI_GATEWAY=litellm` el arranque exige `CHATWOOT_VIRTUAL_KEY_URLS` y `CHATWOOT_SERVICE_CREDENTIALS` para cada emisor (`backend/app/bootstrap/ai.py:41-59`).
- Modelos (`backend/app/config/settings.py:73-79,125`): `EMBEDDING_MODEL` queda por defecto en `text-embedding-3-small` con LiteLLM, que cubre `text-embedding-*`. `RERANK_MODEL`, `STT_MODEL` y `TTS_MODEL` están vacíos por defecto, y vacíos esos servicios quedan no disponibles con el motivo `sin_modelo` (`ai.py:98-101`): para activarlos hay que poner un id que el comodín cubra, por ejemplo `whisper-1`, `tts-1` y un `rerank-*` de Cohere. `AGENT_MODEL` por defecto es `anthropic/claude-sonnet-5.5`, que el comodín `anthropic/*` cubre con `ANTHROPIC_API_KEY`; con otro proveedor, poner un id que cubra otro comodín.

## Ruteo de modelos

`litellm-config.yaml` no lista modelos: cada proveedor tiene un comodín con prefijo (`openai/*`, `gemini/*`, `anthropic/*`, `cohere/*`) y uno sin prefijo con el patrón de ids que piden los consumidores (`gpt-*`, `text-embedding-*`, `whisper-*`, `tts-*`, `gemini-*`, `claude-*`, `rerank-*`). El sin prefijo hace falta porque Chatwoot y el motor piden ids como `gpt-4.1-mini` o `text-embedding-3-small`, y el comodín `openai/*` solo cubriría `openai/gpt-4.1-mini`. Las claves y la master key vienen de `os.environ/...`. Embeddings, STT y TTS caen en los comodines de OpenAI; el rerank se sirve con Cohere, por eso su comodín. Verificado con el código de ruteo del fork (`litellm/router_utils/pattern_match_deployments.py`): cada id de ejemplo se traduce al modelo del proveedor esperado. Un id que ningún comodín cubre (por ejemplo `mistral-*`) responde con error de modelo desconocido; agregar un proveedor es agregar dos entradas.

## Memoria

El servicio corre con `mem_limit: 1g`, `mem_reservation: 512m` y `--num_workers 1`: un solo proceso, que es lo que mantiene el consumo bajo con poca carga. Es un punto de partida, no una medición: todavía no se midió en el host.

Para medir después de un deploy y de unos minutos de uso:

```bash
docker stats --no-stream notifai-litellm-litellm-1
docker inspect -f '{{.State.OOMKilled}} {{.RestartCount}}' notifai-litellm-litellm-1
```

Mirar `MEM USAGE` durante al menos 48 horas de uso normal, no en el arranque (la migración inicial de la base sube el pico). Criterio propuesto (**Inferencia**, a confirmar con la medición): si el máximo observado queda por debajo de 450 MB, `OOMKilled` es `false` y `RestartCount` es 0, bajar `mem_limit` a `768m` en un PR a esta carpeta. Si `OOMKilled` es `true`, subirlo en vez de bajarlo.

## Cómo verificar que no hay entrada desde internet

Después del primer deploy y después de cada cambio del compose:

1. En el host, `docker port notifai-litellm-litellm-1`: la dirección que antecede al puerto es `NOTIFAI_BIND_ADDR`, nunca la de todas las interfaces.
2. En el host, `ss -ltn` y buscar `LITELLM_PORT`: la dirección local es la misma, no un asterisco ni la de todas las interfaces.
3. Desde una máquina fuera de la instancia y de la red privada, `curl --max-time 5` a `http://<nombre público de la instancia>:<LITELLM_PORT>/health/liveliness` tiene que fallar por tiempo o conexión rechazada.
4. DevOps, en solo lectura, confirma que ningún security group de la instancia permite entrada TCP a `LITELLM_PORT` y que el nginx del host no tiene ningún `location` ni `upstream` hacia LiteLLM.

## Redesplegar un SHA

Lanzar `Notifai deploy a dev` con `workflow_dispatch` desde `litellm_internal_staging`: despliega el commit de esa corrida. Para volver atrás a un commit anterior, reintentar la corrida de ese commit. Cada release queda en su carpeta `releases/<sha>/`; las anteriores y sus imágenes quedan en el host.

## Si falla

- **Falla el paso de credenciales o `ecr`.** Falta un paso 1 a 5 de los pasos humanos o de DevOps, o el environment `dev` no tiene las variables.
- **El workflow dice que `litellm-dev:<tag>` ya existe con otro digest.** Alguien cambió el tag de `upstream-image.env` sin cambiar el digest, o al revés. Corregir el archivo; los tags de ECR son inmutables.
- **`deploy.sh` sale con 3.** El `.env` no es un archivo regular con modo 600. Corregirlo en el host y repetir.
- **`deploy.sh` sale con 5.** `NOTIFAI_BIND_ADDR` falta, está vacío o es la dirección de todas las interfaces; o Compose es demasiado viejo para `config --no-env-resolution`. No se levantó nada.
- **`up --wait` no termina.** LiteLLM tarda en el primer arranque por la migración de la base: la espera del healthcheck es de hasta 90 s más cinco reintentos. Si sigue sin quedar sano, revisar `DATABASE_URL` y los logs con `docker compose --project-name notifai-litellm logs litellm` en la carpeta del release.
