# aibox module registry — shell-sourced, variables only (no commands).
# 主 CLI `aibox` 通过 source 本文件读取模块清单。模块名含连字符时，
# 变量名用下划线替换：pi-web -> AIBOX_MODULE_pi_web_*
# shellcheck shell=bash disable=SC2034  # 数据声明文件；变量由主 CLI 的 module_field() 动态 eval 读取

AIBOX_MODULES="pi-web"

AIBOX_MODULE_pi_web_version="1.0.0"
AIBOX_MODULE_pi_web_description="Deploy & manage @agegr/pi-web as a macOS launchd service (HTTP Basic auth, auto-restart)"
AIBOX_MODULE_pi_web_platform=""   # 跨平台：macOS launchd / Linux systemd --user
AIBOX_MODULE_pi_web_dir="tools/pi-web"
AIBOX_MODULE_pi_web_files="lib.sh install.sh uninstall.sh update.sh svc.sh"
AIBOX_MODULE_pi_web_install="install.sh"
AIBOX_MODULE_pi_web_uninstall="uninstall.sh"
AIBOX_MODULE_pi_web_update="update.sh"
AIBOX_MODULE_pi_web_svc="svc.sh"
AIBOX_MODULE_pi_web_actions="start stop restart status logs diagnose"
AIBOX_MODULE_pi_web_deps="node:22 npm"   # node 22+（已有 nvm 自动装）+ npm

AIBOX_MODULES="${AIBOX_MODULES} openmaic"

AIBOX_MODULE_openmaic_version="1.0.0"
AIBOX_MODULE_openmaic_description="OpenMAIC ops CLI (install/upgrade/backup/doctor) — runs on the Linux deploy host"
AIBOX_MODULE_openmaic_platform=""
AIBOX_MODULE_openmaic_dir="tools/openmaic"
AIBOX_MODULE_openmaic_files="lib.sh openmaic install.sh uninstall.sh update.sh svc.sh"
AIBOX_MODULE_openmaic_install="install.sh"
AIBOX_MODULE_openmaic_uninstall="uninstall.sh"
AIBOX_MODULE_openmaic_update="update.sh"
AIBOX_MODULE_openmaic_svc="svc.sh"
AIBOX_MODULE_openmaic_actions="status health doctor version up down restart logs render upgrade rollback backup restore db config models install clean powerlog url"
AIBOX_MODULE_openmaic_deps="docker@linux docker-compose@linux git@linux"   # 部署主机运维才需；@linux=仅 Linux 检查

AIBOX_MODULES="${AIBOX_MODULES} windmill"

AIBOX_MODULE_windmill_version="1.1.0"
AIBOX_MODULE_windmill_description="Windmill self-host ops CLI (init/upgrade/backup/drill/doctor) — deploy root \$AIBOX_HOME/apps/windmill, config /etc/windmill"
AIBOX_MODULE_windmill_platform=""
AIBOX_MODULE_windmill_dir="tools/windmill"
AIBOX_MODULE_windmill_files="lib.sh windmill install.sh uninstall.sh update.sh svc.sh"
AIBOX_MODULE_windmill_install="install.sh"
AIBOX_MODULE_windmill_uninstall="uninstall.sh"
AIBOX_MODULE_windmill_update="update.sh"
AIBOX_MODULE_windmill_svc="svc.sh"
AIBOX_MODULE_windmill_actions="status doctor version up down logs shell credentials systemd destroy backup upgrade rollback check deploy restore drill snapshots init"
AIBOX_MODULE_windmill_deps="docker docker-compose python3"   # CLI 主体需 docker（macOS 用 Docker Desktop）+ python3（compose 解析）

AIBOX_MODULES="${AIBOX_MODULES} clash"

AIBOX_MODULE_clash_version="1.0.0"
AIBOX_MODULE_clash_description="Clash 订阅代理池 — mihomo 内核编排（自动测速/切换/失败回退静态代理）"
AIBOX_MODULE_clash_platform=""
AIBOX_MODULE_clash_dir="tools/clash"
AIBOX_MODULE_clash_files="lib.sh install.sh uninstall.sh update.sh svc.sh"
AIBOX_MODULE_clash_install="install.sh"
AIBOX_MODULE_clash_uninstall="uninstall.sh"
AIBOX_MODULE_clash_update="update.sh"
AIBOX_MODULE_clash_svc="svc.sh"
AIBOX_MODULE_clash_actions="start stop restart status refresh set select test logs doctor"
AIBOX_MODULE_clash_deps=""   # mihomo 由 aibox 下发，gunzip 系统自带

