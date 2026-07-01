#!/usr/bin/env bash
# 04_export_offline_bundle.sh - 导出离线部署包
# 将所有组件打包成单一压缩文件，便于传输到目标服务器

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/install/offline-k8s}"
CONFIG_DIR="$ROOT_DIR/config"
VERSIONS_LOCK="$CONFIG_DIR/versions.lock"
BUNDLE_DIR="$ROOT_DIR/bundle"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { log "ERROR: $*"; exit 1; }

# 加载版本锁定
[[ -f "$VERSIONS_LOCK" ]] || fatal "缺少版本锁定文件: $VERSIONS_LOCK"
# shellcheck disable=SC1090
source "$VERSIONS_LOCK"

STAGING_NAME="k8s-offline-openEuler-${RPM_ARCH}"
STAGING_DIR="$BUNDLE_DIR/$STAGING_NAME"

# 使用 pigz 并行压缩（如可用）
GZIP_CMD="gzip"
if command -v pigz >/dev/null 2>&1; then
  GZIP_CMD="pigz"
  log "检测到 pigz，将启用并行压缩"
fi

prepare_bundle_dir() {
  log "准备 staging 目录: $STAGING_DIR"

  # 使用临时 staging 目录，避免 rm -rf 后残留
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR"

  local items=(
    "bin:可执行文件 (sealos, helm)"
    "config:配置文件和版本锁定"
    "images:应用镜像 tar 包"
    "sealos-images:K8s cluster images"
    "manifests:K8s manifest 文件"
    "pkgs:RPM 系统依赖包"
  )

  for item in "${items[@]}"; do
    local dir="${item%%:*}"
    local label="${item#*:}"
    local src="${ROOT_DIR}/${dir}"
    if [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
      cp -a "$src" "$STAGING_DIR/"
      log "  [OK] $dir ($label)"
    else
      log "  [SKIP] $dir ($label) - 目录为空或不存在"
    fi
  done

  # 验证关键文件存在
  local required=(
    "bin/sealos"
    "config/versions.lock"
    "sealos-images/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar"
    "sealos-images/calico-${CALICO_VERSION}-${ARCH}.tar"
    "manifests/ingress-nginx/deploy.yaml"
  )
  local missing=0
  for f in "${required[@]}"; do
    if [[ ! -f "$STAGING_DIR/$f" ]]; then
      warn "缺失关键文件: $f"
      missing=$((missing + 1))
    fi
  done
  if [[ $missing -gt 0 ]]; then
    fatal "缺少 $missing 个关键文件，无法打包"
  fi
}

copy_scripts() {
  log "复制安装脚本"
  mkdir -p "$STAGING_DIR/scripts"

  cp "${ROOT_DIR}/scripts/install_offline.sh" "$STAGING_DIR/install_offline.sh"
  chmod +x "$STAGING_DIR/install_offline.sh"
  log "  [OK] install_offline.sh"

  if [[ -d "${ROOT_DIR}/scripts" ]]; then
    cp -a "${ROOT_DIR}/scripts/." "$STAGING_DIR/scripts/"
    chmod +x "$STAGING_DIR/scripts/"*.sh 2>/dev/null || true
    log "  [OK] scripts/ 目录"
  fi
}

create_version_info() {
  cat > "$STAGING_DIR/VERSION.txt" <<EOF
Kubernetes Offline Deployment Package
=====================================
构建时间: $(date '+%Y-%m-%d %H:%M:%S')
架构: ${ARCH} (${RPM_ARCH})
目标系统: openEuler 22.03 LTS

组件版本:
---------
Kubernetes: ${KUBERNETES_VERSION}
Calico: ${CALICO_VERSION}
ingress-nginx: ${INGRESS_NGINX_VERSION}
Sealos: ${SEALOS_VERSION}
Helm: ${HELM_VERSION}
Prometheus: v3.12.0
Grafana: 13.0.2

版本策略: ${VERSION_POLICY}
${VERSION_NOTES}

使用方法:
---------
1. 解压包: tar -xzf k8s-offline-*.tar.gz
2. 执行安装: ./install_offline.sh

EOF
  log "VERSION.txt 已创建"
}

generate_checksums() {
  log "生成 sha256 校验文件"
  (cd "$STAGING_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum > sha256sum.txt)
  log "sha256sum.txt 已生成 ($(wc -l < "$STAGING_DIR/sha256sum.txt") 个文件)"
}

create_archive() {
  local archive_name="k8s-offline-openEuler-${RPM_ARCH}-${TIMESTAMP}.tar.gz"
  local archive_path="$BUNDLE_DIR/$archive_name"

  log "创建归档 (使用 $GZIP_CMD): $archive_name"

  # 使用 tar + 选择的压缩工具
  (cd "$BUNDLE_DIR" && tar -cf - "$STAGING_NAME" | $GZIP_CMD -c > "$archive_path")

  local size
  size=$(du -h "$archive_path" | cut -f1)
  log "归档完成: $archive_path (${size})"

  sha256sum "$archive_path" > "${archive_path}.sha256"
  log "sha256 校验码: ${archive_path}.sha256"
}

print_summary() {
  log "========================================"
  log "离线包导出完成"
  log "========================================"
  log "归档文件: $BUNDLE_DIR/k8s-offline-openEuler-${RPM_ARCH}-${TIMESTAMP}.tar.gz"
  log "文件大小: $(du -h "$BUNDLE_DIR/k8s-offline-openEuler-${RPM_ARCH}-${TIMESTAMP}.tar.gz" | cut -f1)"
  log ""
  log "传输到目标服务器后:"
  log "  1. 解压: tar -xzf k8s-offline-openEuler-${RPM_ARCH}-*.tar.gz"
  log "  2. 安装: sudo ./install_offline.sh"
  log ""
  log "注意: 安装脚本需 root 权限运行"
  log "========================================"
}

main() {
  log "开始导出离线部署包"

  prepare_bundle_dir
  copy_scripts
  create_version_info
  generate_checksums
  create_archive
  rm -rf "$STAGING_DIR"
  print_summary

  log "完成"
}

main "$@"
