#!/usr/bin/env bash
# package_database_bundle.sh - 导出独立数据库/中间件离线包

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-/opt/install/offline-database}"
BUNDLE_DIR="$ROOT_DIR/bundle"

# 读取全局架构配置 (项目根目录 → bundle 根目录 → 包内 config)
for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/arch.env" "$ROOT_DIR/config/arch.env"; do
  if [[ -f "$_p" ]]; then source "$_p"; break; fi
done
ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64) PKG_ARCH="aarch64"; ARCH_LABEL="ARM64/aarch64" ;;
  amd64) PKG_ARCH="x86_64"; ARCH_LABEL="AMD64/x86_64" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

TS=$(date +%Y%m%d%H%M%S)
PKG_NAME="offline-database-${PKG_ARCH}"
OUT_DIR="$BUNDLE_DIR/$PKG_NAME"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

# 清理并重建 staging 目录
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"/{images,compose,scripts,third-party}

# 复制目录内容 (images 只复制当前架构)
for dir in compose scripts third-party; do
  src="$ROOT_DIR/$dir"
  dst="$OUT_DIR/$dir"
  if [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
    cp -a "$src/." "$dst/"
    log "  [OK] $dir/"
  else
    log "  [EMPTY] $dir/ (保留空目录)"
  fi
done

# images 只复制当前架构
src="$ROOT_DIR/images/${ARCH}"
dst="$OUT_DIR/images/${ARCH}"
if [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
  mkdir -p "$OUT_DIR/images"
  cp -a "$src" "$dst/"
  log "  [OK] images/${ARCH}/"
else
  log "  [EMPTY] images/${ARCH}/ (保留空目录)"
fi

chmod +x "$OUT_DIR"/scripts/*.sh 2>/dev/null || true

# 复制全局架构配置到 bundle 根目录
if [[ -f "$ROOT_DIR/../arch.env" ]]; then
  cp "$ROOT_DIR/../arch.env" "$OUT_DIR/arch.env"
fi

# 确保 .env.example 被复制
for svc_dir in "$OUT_DIR"/compose/*/; do
  svc=$(basename "$svc_dir")
  src_env="$ROOT_DIR/compose/$svc/.env.example"
  if [[ -f "$src_env" ]] && [[ ! -f "$svc_dir/.env.example" ]]; then
    cp "$src_env" "$svc_dir/.env.example"
    log "  [OK] compose/$svc/.env.example"
  fi
done

# 验证关键文件
if [[ ! -d "$OUT_DIR/images/${ARCH}" ]] || [[ -z "$(ls "$OUT_DIR/images/${ARCH}"/*.tar 2>/dev/null)" ]]; then
  warn "镜像目录为空或不存在，请先执行 scripts/download_database_images.sh"
fi
if [[ ! -d "$OUT_DIR/compose" ]]; then
  fatal "缺少 compose 目录"
fi

# 创建版本信息
cat > "$OUT_DIR/VERSION.txt" <<EOF
Offline Database/Middleware Package
===================================
构建时间: $(date '+%F %T')
架构: ${ARCH_LABEL}
内容:
- MySQL: 8.4 (端口 3306, 数据 /data/mysql)
- Redis: 8.8 (端口 6379, 数据 /data/redis)
- Kafka: 4.0.2 (端口 9092, KRaft 模式)
- Kafka UI: latest (端口 9090)
- NebulaGraph: 3.8.0 (端口 9669, metad/storaged/graphd)
- Nebula Console: 3.8.0 (用于初始化 storage host 注册)
- Doris/ES/JDK: 占位目录 (third-party/)
- Nebula Dashboard/Studio: 占位目录 (third-party/)

使用方法:
---------
1. 先安装 Docker 离线包 (offline-docker)
2. ./scripts/load_database_images.sh  # 导入镜像
3. ./scripts/install_db.sh [service...]  # 部署服务
4. 单机版 NebulaGraph 会自动注册 storage host
5. 集群版 NebulaGraph 需手动执行:
   docker exec -it nebula-graphd nebula -addr=127.0.0.1 -port=9669 -u root -p nebula -e 'ADD HOSTS "<storaged_ip>:9779"'
EOF

log "VERSION.txt 已创建"

# 生成校验文件
(cd "$OUT_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum > sha256sum.txt)
log "sha256sum.txt 已生成"

# 打包
log "创建归档..."
(cd "$BUNDLE_DIR" && tar -czf "${PKG_NAME}-${TS}.tar.gz" "$PKG_NAME")
sha256sum "$BUNDLE_DIR/${PKG_NAME}-${TS}.tar.gz" > "$BUNDLE_DIR/${PKG_NAME}-${TS}.tar.gz.sha256"

# 清理 staging
rm -rf "$OUT_DIR"

log "完成: $BUNDLE_DIR/${PKG_NAME}-${TS}.tar.gz ($(du -h "$BUNDLE_DIR/${PKG_NAME}-${TS}.tar.gz" | cut -f1))"
