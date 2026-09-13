# aibox module registry — shell-sourced, variables only (no commands).
# 主 CLI `aibox` 通过 source 本文件读取模块清单。模块名含连字符时，
# 变量名用下划线替换：pi-web -> AIBOX_MODULE_pi_web_*

AIBOX_MODULES="pi-web"

AIBOX_MODULE_pi_web_version="1.0.0"
AIBOX_MODULE_pi_web_description="Deploy & manage @agegr/pi-web as a macOS launchd service (HTTP Basic auth, auto-restart)"
AIBOX_MODULE_pi_web_platform="darwin"
AIBOX_MODULE_pi_web_dir="tools/pi-web"
AIBOX_MODULE_pi_web_files="lib.sh install.sh uninstall.sh update.sh svc.sh"
AIBOX_MODULE_pi_web_install="install.sh"
AIBOX_MODULE_pi_web_uninstall="uninstall.sh"
AIBOX_MODULE_pi_web_update="update.sh"
AIBOX_MODULE_pi_web_svc="svc.sh"
AIBOX_MODULE_pi_web_actions="start stop restart status logs diagnose"
