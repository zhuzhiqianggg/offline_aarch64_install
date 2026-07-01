#!/usr/bin/env bash
# package_docker_bundle.sh - 导出独立 Docker 离线包

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-/opt/install/offline-docker}"
BUNDLE_DIR="$ROOT_DIR/bundle"
TS=$(date +%Y%m%d%H%M%S)

# 读取架构配置
ARCH_CONFIG="$ROOT_DIR/config/arch.env"
if [[ -f "$ARCH_CONFIG" ]]; then
  source "$ARCH_CONFIG"
fi
ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64) PKG_ARCH="aarch64"; ARCH_LABEL="ARM64/aarch64" ;;
  amd64) PKG_ARCH="x86_64"; ARCH_LABEL="AMD64/x86_64" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

OUT_DIR="$BUNDLE_DIR/offline-docker-${PKG_ARCH}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"/{bin,pkgs,scripts}

for dir in bin pkgs scripts; do
  if [[ -d "$ROOT_DIR/$dir" ]]; then
    cp -a "$ROOT_DIR/$dir/." "$OUT_DIR/$dir/"
  else
    warn "目录不存在，已在离线包中保留空目录: $ROOT_DIR/$dir"
  fi
done

chmod +x "$OUT_DIR"/scripts/*.sh 2>/dev/null || true

cat > "$OUT_DIR/VERSION.txt" <<EOF
Offline Docker Engine Package
=============================
构建时间: $(date '+%F %T')
架构: ${ARCH_LABEL}
内容: Docker Engine + Docker Compose 插件 + Docker Buildx 插件
不包含: K8s、不包含数据库镜像、不包含业务数据库 compose
EOF

(cd "$OUT_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum > sha256sum.txt)
(cd "$BUNDLE_DIR" && tar -czf "offline-docker-${PKG_ARCH}-${TS}.tar.gz" "offline-docker-${PKG_ARCH}")
sha256sum "$BUNDLE_DIR/offline-docker-${PKG_ARCH}-${TS}.tar.gz" > "$BUNDLE_DIR/offline-docker-${PKG_ARCH}-${TS}.tar.gz.sha256"
log "完成: $BUNDLE_DIR/offline-docker-${PKG_ARCH}-${TS}.tar.gz"
