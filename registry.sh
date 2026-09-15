# aibox module registry — 模块名索引。
# 字段（version/platform/deps/ports/files/hooks/actions/upstream/dashboard）
# 在各模块的 tools/<name>/module.yaml 声明，主 CLI load_registry 解析注入。
# shellcheck shell=bash disable=SC2034  # AIBOX_MODULES 由 load_registry eval 后用

AIBOX_MODULES="pi-web openmaic windmill clash base"
