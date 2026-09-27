# ---------- proxy ----------
# Config lives at $AIBOX_HOME/config (KEY=VALUE, mode 600, hand-editable).
# Scope: aibox itself + the module hooks it spawns (via inherited env vars).
# Not overridden: Docker daemon pulls, and other already-running processes —
# env vars cannot reach them.
AIBOX_PROXY_URL=""
AIBOX_PROXY_ENABLED="1"
AIBOX_NO_PROXY_DEFAULT="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,.local"
AIBOX_NO_PROXY="$AIBOX_NO_PROXY_DEFAULT"
AIBOX_PROXY_SOURCE=""
PROBE_CONFIRMED=0
# Probe target: use the very file aibox actually fetches — testing anything else is meaningless.
case "$AIBOX_RAW" in
  file://*) PROBE_TARGET="https://raw.githubusercontent.com/${AIBOX_REPO}/${AIBOX_BRANCH}/install.sh" ;;
  *)        PROBE_TARGET="$AIBOX_RAW/install.sh" ;;
esac

# Injected into module hooks (hook contract: docs/module-spec.md).
# Previously only documented as injected; actually only AIBOX_MODULE was. Fixed.
# AIBOX_BIN_DIR is exported so modules install into the same dir as the main CLI.
export AIBOX_HOME AIBOX_RAW AIBOX_BIN_DIR

# ---------- output / colors ----------
# Colors only on a TTY and when NO_COLOR is unset — no leakage into pipes/scripts,
# and the probe TUI reuses the same scheme (single source of color truth).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'; C_CYA=$'\033[36m'
  C_CLR=$'\r\033[K'
  TUI_TTY=1
else
  C_RST=''; C_DIM=''; C_BOLD=''; C_GRN=''; C_YEL=''; C_RED=''; C_CYA=''
  C_CLR=''
  TUI_TTY=0
fi
# Exported so module hooks (child processes) inherit the same scheme — single source of
# truth. Modules' log/warn/die use ${C_*:-} (empty fallback when run standalone, not via aibox).
export C_RST C_DIM C_BOLD C_GRN C_YEL C_RED C_CYA

