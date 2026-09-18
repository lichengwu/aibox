#!/usr/bin/env bash
# dify module — install hook (contract: docs/module-spec.md §Hook contract).
# Runs AFTER the aibox preflight gate; idempotent. Places the curated compose,
# the vendored nginx/ + ssrf_proxy/ config templates, and writes the deploy
# .env once (never clobbers an existing one).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${DIR}/lib.sh"

ROOT="$(deploy_root)"
mkdir -p "${ROOT}/nginx/conf.d" "${ROOT}/ssrf_proxy" "${ROOT}/nginx/ssl"

# --- place the curated compose + vendored config templates (verbatim copies) ---
cp "${DIR}/docker-compose.yml" "${ROOT}/docker-compose.yml"
cp "${DIR}/docker-compose.shared.yml" "${ROOT}/docker-compose.shared.yml"
cp "${DIR}/nginx/nginx.conf.template" "${ROOT}/nginx/nginx.conf.template"
cp "${DIR}/nginx/proxy.conf.template" "${ROOT}/nginx/proxy.conf.template"
cp "${DIR}/nginx/https.conf.template" "${ROOT}/nginx/https.conf.template"
cp "${DIR}/nginx/conf.d/default.conf.template" "${ROOT}/nginx/conf.d/default.conf.template"
cp "${DIR}/nginx/docker-entrypoint.sh" "${ROOT}/nginx/docker-entrypoint.sh"
cp "${DIR}/ssrf_proxy/squid.conf.template" "${ROOT}/ssrf_proxy/squid.conf.template"
cp "${DIR}/ssrf_proxy/squid-common.conf.template" "${ROOT}/ssrf_proxy/squid-common.conf.template"
cp "${DIR}/ssrf_proxy/docker-entrypoint.sh" "${ROOT}/ssrf_proxy/docker-entrypoint.sh"
chmod +x "${ROOT}/nginx/docker-entrypoint.sh" "${ROOT}/ssrf_proxy/docker-entrypoint.sh"
log "compose + nginx/ssrf_proxy templates placed → ${ROOT}"

# --- write the deploy .env once (idempotent: existing file is never clobbered) ---
if [ ! -f "${ROOT}/.env" ]; then
  # Generate secrets when not pre-supplied. SECRET_KEY signs session cookies
  # (dify auto-generates one in-storage if left empty, but pinning it makes
  # restarts deterministic). INIT_PASSWORD is the admin first-login password
  # (dify 1.x requires it to be set).
  gen_secret() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p | tr -d '\n'; }
  gen_password() { openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-24 || head -c 18 /dev/urandom | base64; }

  secret_key="${DIFY_SECRET_KEY:-$(gen_secret)}"
  init_password="${DIFY_INIT_PASSWORD:-$(gen_password)}"
  db_password="${DB_PASSWORD:-difyai123456}"
  redis_password="${REDIS_PASSWORD:-difyai123456}"

  cat >"${ROOT}/.env" <<ENV
# dify deploy env — written by aibox install dify (pinned to dify v1.17.1).
# Edit values here, then apply with: aibox dify restart
# Defaults ported from dify's envs/*.env.example (the compose references these
# via \${VAR:-default}; this file is the single override point).

# ---- aibox overrides ----
# Host web port (dify upstream defaults to 80; this module defaults to 8088 to avoid
# colliding with the windmill module). nginx listens internally on NGINX_PORT.
# NOTE the naming trap: upstream's DIFY_PORT is the API gunicorn listen port
# (5001), NOT the web port — the aibox knob is DIFY_WEB_PORT (measured live:
# reusing DIFY_PORT made gunicorn bind 8088 and nginx 502 on api:5001).
DIFY_WEB_PORT=${DIFY_WEB_PORT:-${DEFAULT_PORT}}
EXPOSE_NGINX_PORT=${DIFY_WEB_PORT:-${DEFAULT_PORT}}
NGINX_PORT=${DEFAULT_NGINX_INTERNAL_PORT}
DIFY_PORT=5001

# ---- image tags (pinned; bump here + module.yaml docker_images on update) ----
DIFY_API_IMAGE=${DIFY_API_IMAGE:-${DEFAULT_API_IMAGE}}
DIFY_WEB_IMAGE=${DIFY_WEB_IMAGE:-${DEFAULT_WEB_IMAGE}}
DIFY_SANDBOX_IMAGE=${DIFY_SANDBOX_IMAGE:-${DEFAULT_SANDBOX_IMAGE}}
DIFY_PLUGIN_DAEMON_IMAGE=${DIFY_PLUGIN_DAEMON_IMAGE:-${DEFAULT_PLUGIN_DAEMON_IMAGE}}
DIFY_AGENT_BACKEND_IMAGE=${DIFY_AGENT_BACKEND_IMAGE:-${DEFAULT_AGENT_BACKEND_IMAGE}}
DB_IMAGE=${DB_IMAGE:-${DEFAULT_DB_IMAGE}}
REDIS_IMAGE=${REDIS_IMAGE:-${DEFAULT_REDIS_IMAGE}}
WEAVIATE_IMAGE=${WEAVIATE_IMAGE:-${DEFAULT_WEAVIATE_IMAGE}}

# ---- security (auto-generated; treat as secrets — this file is mode 600) ----
SECRET_KEY=${secret_key}
INIT_PASSWORD=${init_password}
CODE_EXECUTION_API_KEY=${CODE_EXECUTION_API_KEY:-dify-sandbox}
SANDBOX_API_KEY=${SANDBOX_API_KEY:-dify-sandbox}

# ---- bundled DB / Redis (standalone mode). Shared-base mode overrides these
#       via docker-compose.shared.yml (DB_* → AIBOX_POSTGRES_*, REDIS_* →
#       AIBOX_REDIS_*; REDIS_PASSWORD forced empty since base redis has no auth).
DB_TYPE=postgresql
DB_USERNAME=${DB_USERNAME:-postgres}
DB_PASSWORD=${db_password}
DB_DATABASE=${DB_DATABASE:-dify}
DB_PLUGIN_DATABASE=${DB_PLUGIN_DATABASE:-dify_plugin}
DB_SSL_MODE=disable
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${redis_password}
REDIS_USE_SSL=false
REDIS_DB=0
DB_HOST=db_postgres
DB_PORT=5432

# ---- app wiring + tuning (ported verbatim from upstream docker/.env.example
#      v1.17.1). The api/worker/plugin_daemon CONNECTION config (DB_HOST,
#      CODE_EXECUTION_ENDPOINT, PLUGIN_DAEMON_URL, WEAVIATE_ENDPOINT, STORAGE_TYPE,
#      SERVER_WORKER_CLASS, pool/timeout tuning...) lives HERE, not in the compose
#      inline blocks — an incomplete port once made api hit localhost:5432 and
#      plugin_daemon crash-loop on missing DBHost/DBPort. Shared-base mode overrides
#      DB_*/REDIS_*/CELERY_BROKER_URL via compose environment (which beats env_file). ----
ALLOW_EMBED=false
ALLOW_UNSAFE_DATA_SCHEME=false
BROKER_USE_SSL=false
CELERY_AUTO_SCALE=false
CELERY_BACKEND=redis
CELERY_TASK_ANNOTATIONS=null
CELERY_WORKER_AMOUNT=4
CODE_EXECUTION_CONNECT_TIMEOUT=10
CODE_EXECUTION_ENDPOINT=http://sandbox:8194
CODE_EXECUTION_POOL_KEEPALIVE_EXPIRY=5.0
CODE_EXECUTION_POOL_MAX_CONNECTIONS=100
CODE_EXECUTION_POOL_MAX_KEEPALIVE_CONNECTIONS=20
CODE_EXECUTION_READ_TIMEOUT=60
CODE_EXECUTION_SSL_VERIFY=True
CODE_EXECUTION_WRITE_TIMEOUT=10
COMPOSE_WORKER_HEALTHCHECK_DISABLED=true
COMPOSE_WORKER_HEALTHCHECK_INTERVAL=30s
COMPOSE_WORKER_HEALTHCHECK_TIMEOUT=30s
CONSOLE_CORS_ALLOW_ORIGINS=*
DB_HOST=db_postgres
DB_PORT=5432
DEBUG=false
DIFY_BIND_ADDRESS=0.0.0.0
ENABLE_COLLABORATION_MODE=true
ENABLE_REQUEST_LOGGING=False
ENABLE_WEBSITE_FIRECRAWL=true
ENABLE_WEBSITE_JINAREADER=true
ENABLE_WEBSITE_WATERCRAWL=true
ENDPOINT_URL_TEMPLATE=http://localhost/e/{hook_id}
EVENT_BUS_REDIS_CHANNEL_TYPE=pubsub
EVENT_BUS_REDIS_USE_CLUSTERS=false
EXPERIMENTAL_ENABLE_VINEXT=false
FILES_ACCESS_TIMEOUT=300
FLASK_DEBUG=false
FORCE_VERIFYING_SIGNATURE=true
GUNICORN_TIMEOUT=360
INDEXING_MAX_SEGMENTATION_TOKENS_LENGTH=4000
LOG_DATEFORMAT=%Y-%m-%d %H:%M:%S
LOG_FILE=/app/logs/server.log
LOG_FILE_BACKUP_COUNT=5
LOG_FILE_MAX_SIZE=20
LOG_OUTPUT_FORMAT=text
LOG_TZ=UTC
LOOP_NODE_MAX_COUNT=100
MARKETPLACE_API_URL=https://marketplace.dify.ai
MAX_ITERATIONS_NUM=99
MAX_PARALLEL_LIMIT=10
MAX_TOOLS_NUM=10
MAX_TREE_DEPTH=50
NEXT_PUBLIC_BATCH_CONCURRENCY=5
NEXT_PUBLIC_ENABLE_AGENT_V2=true
NEXT_PUBLIC_ENABLE_SINGLE_DOLLAR_LATEX=false
NEXT_PUBLIC_SOCKET_URL=ws://localhost
OPENDAL_FS_ROOT=storage
OPENDAL_SCHEME=fs
PLUGIN_DAEMON_URL=http://plugin_daemon:5002
PLUGIN_DIFY_INNER_API_URL=http://api:5001
PLUGIN_INSTALLED_PATH=plugin
PLUGIN_MAX_EXECUTION_TIMEOUT=600
PLUGIN_MAX_FILE_SIZE=52428800
PLUGIN_MAX_PACKAGE_SIZE=52428800
PLUGIN_MEDIA_CACHE_PATH=assets
PLUGIN_MODEL_SCHEMA_CACHE_TTL=3600
PLUGIN_PACKAGE_CACHE_PATH=plugin_packages
PLUGIN_PPROF_ENABLED=false
PLUGIN_PYTHON_ENV_INIT_TIMEOUT=120
PLUGIN_SENTRY_ENABLED=false
PLUGIN_STDIO_BUFFER_SIZE=1024
PLUGIN_STDIO_MAX_BUFFER_SIZE=5242880
PLUGIN_STORAGE_LOCAL_ROOT=/app/storage
PLUGIN_STORAGE_TYPE=local
PLUGIN_WORKING_PATH=/app/storage/cwd
POSTGRES_EFFECTIVE_CACHE_SIZE=4096MB
POSTGRES_IDLE_IN_TRANSACTION_SESSION_TIMEOUT=0
POSTGRES_MAINTENANCE_WORK_MEM=64MB
POSTGRES_MAX_CONNECTIONS=200
POSTGRES_SHARED_BUFFERS=128MB
POSTGRES_STATEMENT_TIMEOUT=0
POSTGRES_WORK_MEM=4MB
REDIS_HEALTH_CHECK_INTERVAL=30
REDIS_KEEPALIVE=true
REDIS_KEEPALIVE_COUNT=10
REDIS_KEEPALIVE_IDLE=30
REDIS_KEEPALIVE_INTERVAL=10
REDIS_RETRY_BACKOFF_BASE=1.0
REDIS_RETRY_BACKOFF_CAP=10.0
REDIS_RETRY_RETRIES=3
REDIS_SOCKET_CONNECT_TIMEOUT=5.0
REDIS_SOCKET_TIMEOUT=5.0
REDIS_SSL_CERT_REQS=CERT_NONE
SANDBOX_ENABLE_NETWORK=true
SANDBOX_GIN_MODE=release
SANDBOX_PORT=8194
SANDBOX_WORKER_TIMEOUT=15
SERVER_CONSOLE_API_URL=http://api:5001
SERVER_WORKER_AMOUNT=1
SERVER_WORKER_CLASS=gevent
SERVER_WORKER_CONNECTIONS=10
SQLALCHEMY_ECHO=false
SQLALCHEMY_MAX_OVERFLOW=10
SQLALCHEMY_POOL_PRE_PING=false
SQLALCHEMY_POOL_RECYCLE=3600
SQLALCHEMY_POOL_RESET_ON_RETURN=rollback
SQLALCHEMY_POOL_SIZE=30
SQLALCHEMY_POOL_TIMEOUT=30
SQLALCHEMY_POOL_USE_LIFO=false
SSRF_DEFAULT_CONNECT_TIME_OUT=5
SSRF_DEFAULT_READ_TIME_OUT=5
SSRF_DEFAULT_TIME_OUT=5
SSRF_DEFAULT_WRITE_TIME_OUT=5
SSRF_POOL_KEEPALIVE_EXPIRY=5.0
SSRF_POOL_MAX_CONNECTIONS=100
SSRF_POOL_MAX_KEEPALIVE_CONNECTIONS=20
STORAGE_TYPE=opendal
TEXT_GENERATION_TIMEOUT_MS=60000
TOP_K_MAX_VALUE=10
TRIGGER_URL=http://localhost
UV_CACHE_DIR=/tmp/.uv-cache
VECTOR_INDEX_NAME_PREFIX=Vector_index
WEAVIATE_API_KEY=WVF5YThaHlkYwhGUSmCRgsX3tD5ngdN8pkih
WEAVIATE_ENABLE_TOKENIZER_GSE=false
WEAVIATE_ENABLE_TOKENIZER_KAGOME_JA=false
WEAVIATE_ENABLE_TOKENIZER_KAGOME_KR=false
WEAVIATE_ENDPOINT=http://weaviate:8080
WEAVIATE_GRPC_ENDPOINT=grpc://weaviate:50051
WEAVIATE_TOKENIZATION=word
WEB_API_CORS_ALLOW_ORIGINS=*
# ---- app runtime defaults (ported from envs/core-services/shared.env.example) ----
LANG=C.UTF-8
LC_ALL=C.UTF-8
PYTHONIOENCODING=utf-8
DEPLOY_ENV=PRODUCTION
DEPLOYMENT_EDITION=COMMUNITY
MIGRATION_ENABLED=true
CELERY_BROKER_URL=redis://:${redis_password}@redis:6379/1
CHECK_UPDATE_URL=https://updates.dify.ai
OPENAI_API_BASE=https://api.openai.com/v1
MARKETPLACE_ENABLED=true
PGDATA=/var/lib/postgresql/data/pgdata
LOG_LEVEL=INFO

# ---- SSRF forward proxy (squid) — the dify ssrf_proxy service config ----
SSRF_PROXY_HTTP_URL=http://ssrf_proxy:3128
SSRF_PROXY_HTTPS_URL=http://ssrf_proxy:3128
SSRF_HTTP_PORT=3128
SSRF_COREDUMP_DIR=/var/spool/squid
SSRF_PROXY_ALLOW_PRIVATE_IPS=
SSRF_PROXY_ALLOW_PRIVATE_DOMAINS=
SANDBOX_HTTP_PROXY=http://ssrf_proxy:3128
SANDBOX_HTTPS_PROXY=http://ssrf_proxy:3128

# ---- nginx config (envsubst'd by the vendored entrypoint) ----
NGINX_SERVER_NAME=_
NGINX_HTTPS_ENABLED=false
NGINX_SSL_PORT=443
NGINX_WORKER_PROCESSES=auto
NGINX_CLIENT_MAX_BODY_SIZE=100M
NGINX_KEEPALIVE_TIMEOUT=65
NGINX_PROXY_READ_TIMEOUT=3600s
NGINX_PROXY_SEND_TIMEOUT=3600s
NGINX_ENABLE_CERTBOT_CHALLENGE=false
NGINX_SOCKET_IO_UPSTREAM=api_websocket:5001

# ---- plugin daemon (defaults from envs/core-services/plugin-daemon.env.example) ----
PLUGIN_DAEMON_PORT=5002
PLUGIN_DAEMON_KEY=${PLUGIN_DAEMON_KEY:-lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+Sjc3ZtU+qUEi}
PLUGIN_DIFY_INNER_API_KEY=${PLUGIN_DIFY_INNER_API_KEY:-QaHbTe77CtuXmsfyhR7+vRjI/+XbV1AaFy691iy+kGDv2Jvy0/eAh8Y1}
PLUGIN_DEBUGGING_HOST=0.0.0.0
PLUGIN_DEBUGGING_PORT=5003
EXPOSE_PLUGIN_DEBUGGING_PORT=5003

# ---- weaviate (default vector store; from envs/vectorstores/weaviate.env.example) ----
VECTOR_STORE=weaviate
WEAVIATE_PERSISTENCE_DATA_PATH=/var/lib/weaviate
WEAVIATE_QUERY_DEFAULTS_LIMIT=25
WEAVIATE_AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED=true
WEAVIATE_DEFAULT_VECTORIZER_MODULE=none
WEAVIATE_CLUSTER_HOSTNAME=node1
WEAVIATE_AUTHENTICATION_APIKEY_ENABLED=true
WEAVIATE_AUTHENTICATION_APIKEY_ALLOWED_KEYS=WVF5YThaHlkYwhGUSmCRgsX3tD5ngdN8pkih
WEAVIATE_AUTHENTICATION_APIKEY_USERS=hello@dify.ai
WEAVIATE_AUTHORIZATION_ADMINLIST_ENABLED=true
WEAVIATE_AUTHORIZATION_ADMINLIST_USERS=hello@dify.ai
WEAVIATE_DISABLE_TELEMETRY=false

# ---- shared-base mode (0 = bundled PG/Redis; 1 = use aibox base) ----
# To enable: aibox base start && aibox base create postgres dify && \\
#            aibox base create postgres dify_plugin && \\
#            set DIFY_SHARED_BASE=1 here, then: aibox dify restart
DIFY_SHARED_BASE=0
ENV
  chmod 600 "${ROOT}/.env"
  log "wrote ${ROOT}/.env (web port $(effective_port 2>/dev/null || printf '%s' "${DIFY_WEB_PORT:-${DEFAULT_PORT}}"))"
  warn "INIT_PASSWORD (admin first login): run 'aibox dify credentials' — DO NOT lose it"
else
  log "kept existing ${ROOT}/.env (not clobbered)"
fi

log "installed → ${ROOT}"
log "Start     : aibox dify start   (first boot 1-2 min; needs >= 4GB RAM)"
log "Web UI    : http://127.0.0.1:$(effective_port 2>/dev/null || printf '%s' "${DIFY_WEB_PORT:-${DEFAULT_PORT}}")"
log "Login     : admin — first-visit password: aibox dify credentials"
