#!/usr/bin/env bash
# install_db.sh - 数据库/中间件离线一键部署入口
# 流程: 校验镜像 -> 加载镜像 -> 复制 compose 到部署根目录 -> 启动 compose 服务 -> 健康检查
#
# 用法:
#   ./install_db.sh                    # 加载镜像并启动全部服务
#   ./install_db.sh mysql              # 仅部署 MySQL
#   ./install_db.sh redis kafka        # 仅部署 Redis + Kafka
#   ./install_db.sh all                # 全部(与无参数等价)
#   ./install_db.sh nebulagraph        # 单机版 NebulaGraph
#   ./install_db.sh nebulagraph-cluster # 集群版 NebulaGraph
#   ./install_db.sh --start-only       # 仅启动服务(镜像已加载)
#   ./install_db.sh --status           # 仅查看服务状态

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

# ---- 权限修复 ----
# 为各服务预创建数据目录并设置正确的权限，避免容器启动时因权限不足而失败
fix_permissions() {
  local svc="$1"
  local deploy_dir="$2"

  case "$svc" in
    kafka)
      # apache/kafka:4.0.2 以 appuser (uid=1000) 运行
      mkdir -p "$deploy_dir/data" "$deploy_dir/logs"
      # 强制递归修改属主，覆盖可能残留的旧文件
      chown -R 1000:1000 "$deploy_dir" 2>/dev/null || true
      chmod -R 0755 "$deploy_dir" 2>/dev/null || true
      log "  -> kafka 权限设置: owner=1000:1000, dir=$deploy_dir"
      ;;
    mysql)
      mkdir -p "$deploy_dir"/{data,conf,logs}
      # MySQL 容器以 mysql (uid=999) 运行
      chown -R 999:999 "$deploy_dir/data" 2>/dev/null || true
      ;;
    redis)
      mkdir -p "$deploy_dir/data"
      # Redis 容器以 redis (uid=999) 运行
      chown -R 999:999 "$deploy_dir/data" 2>/dev/null || true
      ;;
    nebulagraph|nebulagraph-cluster)
      # NebulaGraph 容器以 root 运行, 确保目录结构存在
      mkdir -p "$deploy_dir"/{metad,storaged,graphd}/{data,logs}
      ;;
  esac
}

# ---- 检测可用的 compose 命令 ----
detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi
  return 1
}

ensure_compose() {
  # 自动搜索 compose 二进制
  local compose_src=""
  for candidate in \
    /opt/install/offline-docker/bin/docker-compose \
    "$ROOT_DIR/../offline-docker/bin/docker-compose" \
    "$(dirname "$ROOT_DIR")/offline-docker/bin/docker-compose"; do
    if [[ -f "$candidate" ]]; then
      compose_src="$candidate"
      break
    fi
  done

  # 如果还没找到，尝试直接执行 offline-docker 安装脚本
  if [[ -z "$compose_src" ]]; then
    for install_script in \
      /opt/install/offline-docker/scripts/install_docker_offline.sh \
      "$ROOT_DIR/../offline-docker/scripts/install_docker_offline.sh"; do
      if [[ -f "$install_script" ]]; then
        log "未检测到 compose，自动执行 offline-docker 安装脚本"
        bash "$install_script" || warn "offline-docker 安装脚本执行有警告"
        if detect_compose; then
          return 0
        fi
      fi
    done
  fi

  if [[ -z "$compose_src" ]]; then
    fatal "$(cat <<EOF
未找到可用的 compose 命令，且 offline-docker 包中无 docker-compose 二进制。
请先执行 offline-docker/scripts/install_docker_offline.sh 安装 compose 插件，
或将 docker-compose 二进制放到 /usr/local/lib/docker/cli-plugins/ 目录。
EOF
)"
  fi

  log "从 offline-docker 包安装 compose 插件: $compose_src"
  local plugin_dir="/usr/local/lib/docker/cli-plugins"
  mkdir -p "$plugin_dir"
  install -m 0755 "$compose_src" "$plugin_dir/docker-compose"

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    log "compose 插件安装成功: $(docker compose version)"
  else
    fatal "compose 插件安装后仍不可用，请检查 docker 版本是否支持 compose v2"
  fi
}

# ---- 服务配置 ----
ALL_SERVICES=(mysql redis kafka nebulagraph nebulagraph-cluster)

# 服务名 -> 部署根目录(/data 下,统一结构: /data/{svc}/{data,conf,logs})
declare -A DATA_DIRS=(
  [mysql]="/data/mysql"
  [redis]="/data/redis"
  [kafka]="/data/kafka"
  [nebulagraph]="/data/nebulagraph"
  [nebulagraph-cluster]="/data/nebulagraph"
)

declare -a SELECTED_SERVICES=()
MODE="all"

# ---- 参数解析 ----
for arg in "$@"; do
  case "$arg" in
    --start-only) MODE="start" ;;
    --status)     MODE="status" ;;
    --help|-h)    MODE="help" ;;
    all)
      SELECTED_SERVICES=("${ALL_SERVICES[@]}")
      ;;
    mysql|redis|kafka|nebulagraph|nebulagraph-cluster)
      SELECTED_SERVICES+=("$arg")
      ;;
    *)
      fatal "未知参数: $arg (可用服务: mysql / redis / kafka / nebulagraph / nebulagraph-cluster, 选项: --start-only / --status / --help)"
      ;;
  esac
done

if [[ "$MODE" == "help" ]] || { [[ "$MODE" == "all" ]] && [[ ${#SELECTED_SERVICES[@]} -eq 0 ]] && [[ $# -gt 0 ]]; }; then
  cat <<EOF
用法: $(basename "$0") [选项] [服务名...]
服务名(可多个):
  mysql redis kafka nebulagraph nebulagraph-cluster
  all  # 全部
选项:
  (无参数/ all)  加载镜像并启动全部数据库服务
  --start-only   仅启动服务(镜像已加载)
  --status       仅查看服务运行状态
示例:
  $(basename "$0") mysql                       # 仅部署 MySQL
  $(basename "$0") redis kafka                 # 部署 Redis + Kafka
  $(basename "$0") nebulagraph                 # 单机版 NebulaGraph
  $(basename "$0") nebulagraph-cluster         # 集群版 NebulaGraph
  $(basename "$0") --start-only nebulagraph    # 仅启动(镜像已加载)
  $(basename "$0") --status                    # 查看状态
EOF
  exit 0
fi

# 未指定服务时默认全部
if [[ ${#SELECTED_SERVICES[@]} -eq 0 ]]; then
  SELECTED_SERVICES=("${ALL_SERVICES[@]}")
fi

# ---- 状态检查 ----
show_status() {
  log "数据库服务容器状态:"
  docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" \
    | grep -iE "mysql84|redis|kafka|nebula|^NAMES" || true
}

# ---- 健康检查 ----
# 使用 docker inspect 检查容器真实健康状态，不依赖 compose ps 表格解析
# 返回: 0=健康, 1=未就绪(仅警告，不阻塞后续部署)
wait_for_health() {
  local svc="$1"
  local deploy_dir="$2"
  local timeout=60
  local interval=5

  case "$svc" in
    mysql)   timeout=90 ;;
    redis)   timeout=30 ;;
    kafka)   timeout=120 ;;
    nebulagraph|nebulagraph-cluster) timeout=120 ;;
    *)       timeout=60 ;;
  esac

  log "  等待 $svc 就绪 (最多 ${timeout}s)..."

  # 获取该 compose 文件中所有服务对应的容器名
  local container_names
  container_names=$(cd "$deploy_dir" && "${COMPOSE_CMD[@]}" config --services 2>/dev/null || echo "")
  if [[ -z "$container_names" ]]; then
    warn "  [WARN] $svc 无法获取服务列表，跳过健康检查"
    return 1
  fi

  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local all_healthy=true
    local has_running=false

    for service_name in $container_names; do
      # 获取容器名 (container_name 或 compose自动生成的)
      local ctnr
      ctnr=$(cd "$deploy_dir" && "${COMPOSE_CMD[@]}" ps -q "$service_name" 2>/dev/null | head -1)
      [[ -z "$ctnr" ]] && { all_healthy=false; continue; }

      # 用 docker inspect 获取容器状态
      local state health_status exit_code
      state=$(docker inspect --format '{{.State.Status}}' "$ctnr" 2>/dev/null || echo "unknown")
      exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$ctnr" 2>/dev/null || echo "-1")

      if [[ "$state" == "running" ]]; then
        has_running=true
        # 检查 healthcheck 状态 (如果有)
        health_status=$(docker inspect --format '{{.State.Health.Status}}' "$ctnr" 2>/dev/null || echo "none")
        if [[ "$health_status" == "unhealthy" ]]; then
          all_healthy=false
        fi
        # health_status 为 "none" 表示没有配置 healthcheck，视为通过
      elif [[ "$state" == "exited" ]] || [[ "$state" == "dead" ]]; then
        # one-shot 服务 (如 storage-activator) 退出码 0 是正常的
        if [[ "$exit_code" == "0" ]] && [[ "$service_name" == *"activator"* ]]; then
          continue
        fi
        # 其他服务退出则不健康
        all_healthy=false
      else
        all_healthy=false
      fi
    done

    if $all_healthy && $has_running; then
      log "  [OK] $svc 已就绪"
      return 0
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
  done

  # 超时后仅警告，不返回错误码导致脚本退出
  warn "  [WARN] $svc 未在 ${timeout}s 内完全就绪，请手动检查: cd $deploy_dir && ${COMPOSE_CMD[*]} ps"
  return 1
}

# status 模式不加载镜像
if [[ "$MODE" == "status" ]]; then
  command -v docker >/dev/null 2>&1 || fatal "未安装 docker"
  show_status
  exit 0
fi

command -v docker >/dev/null 2>&1 || fatal "未安装 docker，请先安装 offline-docker 包"
detect_compose || ensure_compose
log "使用 compose 命令: ${COMPOSE_CMD[*]}"

# ---- 加载镜像 ----
if [[ "$MODE" == "all" ]]; then
  log "校验并加载数据库镜像..."
  bash "$ROOT_DIR/scripts/load_database_images.sh"
fi

# ---- 启动 compose 服务 ----
# 关键设计: 单个服务失败不会阻塞其他服务部署
log "启动 compose 服务: ${SELECTED_SERVICES[*]}"
started=0 skipped=0 failed_svc=0

# 声明关联数组记录每个服务的健康检查 PID
declare -a health_pids=()

# ---- 随机密码生成 ----
# 首尾字母数字, 中间: 字母数字 + -_.+=, 不含 @:?#!$%^&*()[]{} 等特殊字符
gen_password() {
  local length=${1:-20}
  local middle_len=$((length - 2))
  local safe_chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.+='
  local alnum='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

  local first="${alnum:RANDOM%${#alnum}:1}"
  local last="${alnum:RANDOM%${#alnum}:1}"
  local middle=""
  for ((i=0; i<middle_len; i++)); do
    middle+="${safe_chars:RANDOM%${#safe_chars}:1}"
  done
  echo "${first}${middle}${last}"
}

PASSWORD_FILE="$ROOT_DIR/.password"
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$HOST_IP" ]] && HOST_IP="127.0.0.1"

# 初始化密码文件
cat > "$PASSWORD_FILE" <<EOF
# ============================================
# 数据库连接信息 - $(date '+%F %T')
# 服务器地址: ${HOST_IP}
# ============================================

EOF
log "密码文件: $PASSWORD_FILE"

for svc in "${SELECTED_SERVICES[@]}"; do
  compose_file="$ROOT_DIR/compose/$svc/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    warn "缺少 compose 文件，跳过 $svc: $compose_file"
    skipped=$((skipped + 1))
    continue
  fi

  deploy_dir="${DATA_DIRS[$svc]:-/data/$svc}"
  mkdir -p "$deploy_dir"

  # ---- 生成随机密码 + .env 文件 ----
  case "$svc" in
    mysql)
      MYSQL_ROOT_PASSWORD=$(gen_password)
      MYSQL_USER="app"
      MYSQL_PASSWORD=$(gen_password)
      MYSQL_DATABASE="app"
      cat > "$deploy_dir/.env" <<EOF
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_USER=${MYSQL_USER}
MYSQL_DATABASE=${MYSQL_DATABASE}
EOF
      log "  -> MySQL 密码已生成"
      ;;
    redis)
      REDIS_PASSWORD=$(gen_password)
      cat > "$deploy_dir/.env" <<EOF
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF
      log "  -> Redis 密码已生成"
      ;;
    kafka)
      # Kafka 无认证，无需密码
      ;;
    nebulagraph|nebulagraph-cluster)
      # NebulaGraph 使用默认 root/nebula，无需密码生成
      ;;
  esac

  # ---- 权限修复 ----
  fix_permissions "$svc" "$deploy_dir"

  # 复制 compose 到部署根目录，便于后续运维
  deploy_compose="$deploy_dir/docker-compose.yml"
  /bin/cp "$compose_file" "$deploy_compose"
  log "  -> $svc: 复制 compose 到 $deploy_compose"

  # nebulagraph-cluster 需要配置 LOCAL_IP 和 METAD_ADDRS
  if [[ "$svc" == "nebulagraph-cluster" ]]; then
    env_example="$ROOT_DIR/compose/nebulagraph-cluster/.env.example"
    [[ -f "$env_example" ]] && /bin/cp "$env_example" "$deploy_dir/.env.example"

    if [[ -z "${LOCAL_IP:-}" ]] || [[ -z "${METAD_ADDRS:-}" ]]; then
      warn "nebulagraph-cluster 需要环境变量 LOCAL_IP 和 METAD_ADDRS"
      warn "已复制 compose 和 .env.example 到 $deploy_dir/"
      warn "请在每台机器上修改 $deploy_dir/.env 后执行: cd $deploy_dir && ${COMPOSE_CMD[*]} up -d"
      skipped=$((skipped + 1))
      continue
    fi

    cat > "$deploy_dir/.env" <<EOF
LOCAL_IP=${LOCAL_IP}
METAD_ADDRS=${METAD_ADDRS}
EOF
    log "  -> 生成集群配置 .env: LOCAL_IP=${LOCAL_IP}, METAD_ADDRS=${METAD_ADDRS}"
  fi

  # ---- 启动 compose 服务（带重试） ----
  log "  -> ${COMPOSE_CMD[*]} up -d [$svc]"
  up_ok=false
  for attempt in $(seq 1 3); do
    if (cd "$deploy_dir" && "${COMPOSE_CMD[@]}" up -d 2>&1); then
      up_ok=true
      break
    fi
    warn "  $svc 启动失败 (attempt $attempt/3)，5 秒后重试..."
    sleep 5
  done

  if [[ "$up_ok" == "true" ]]; then
    started=$((started + 1))
    # 写入密码文件
    case "$svc" in
      mysql)
        cat >> "$PASSWORD_FILE" <<EOF
# ----- MySQL -----
MYSQL_HOST=${HOST_IP}
MYSQL_PORT=3306
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_JDBC_URL=jdbc:mysql://${HOST_IP}:3306/${MYSQL_DATABASE}?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Shanghai

EOF
        ;;
      redis)
        cat >> "$PASSWORD_FILE" <<EOF
# ----- Redis -----
REDIS_HOST=${HOST_IP}
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_URL=redis://:${REDIS_PASSWORD}@${HOST_IP}:6379/0

EOF
        ;;
      kafka)
        cat >> "$PASSWORD_FILE" <<EOF
# ----- Kafka (无认证) -----
KAFKA_HOST=${HOST_IP}
KAFKA_PORT=9092
KAFKA_BOOTSTRAP_SERVERS=${HOST_IP}:9092
KAFKA_UI_URL=http://${HOST_IP}:8080

EOF
        ;;
      nebulagraph|nebulagraph-cluster)
        cat >> "$PASSWORD_FILE" <<EOF
# ----- NebulaGraph (默认密码) -----
NEBULA_HOST=${HOST_IP}
NEBULA_GRAPH_PORT=9669
NEBULA_USER=root
NEBULA_PASSWORD=nebula
NEBULA_CONNECTION=graphd://root:nebula@${HOST_IP}:9669

EOF
        ;;
    esac
    log "  -> 连接信息已写入 $PASSWORD_FILE"

    # 等待该服务就绪（后台不阻塞后续服务启动）
    wait_for_health "$svc" "$deploy_dir" &
    health_pids+=($!)
  else
    warn "  [FAIL] $svc 启动失败 (已重试 3 次)"
    (cd "$deploy_dir" && "${COMPOSE_CMD[@]}" logs --tail=20 2>/dev/null) || true
    failed_svc=$((failed_svc + 1))
  fi
done

# 等待所有健康检查完成，但不因健康检查失败而退出脚本
for pid in "${health_pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# ---- 第三方占位(可选) ----
if [[ " ${SELECTED_SERVICES[*]} " =~ " nebulagraph " ]] || [[ " ${SELECTED_SERVICES[*]} " =~ " nebulagraph-cluster " ]]; then
  if [[ -x "$ROOT_DIR/scripts/install_nebula_third_party.sh" ]]; then
    log "部署 NebulaGraph 第三方占位组件..."
    bash "$ROOT_DIR/scripts/install_nebula_third_party.sh" || warn "Nebula 第三方组件部署有警告(可忽略)"
  fi
fi
if [[ -x "$ROOT_DIR/scripts/install_third_party_placeholders.sh" ]]; then
  log "部署 Doris/ES/JDK 第三方占位组件..."
  bash "$ROOT_DIR/scripts/install_third_party_placeholders.sh" || warn "第三方占位组件部署有警告(可忽略)"
fi

# ---- 状态汇总 ----
echo ""
show_status
echo ""
log "========================================"
log "部署汇总: 启动 $started, 跳过 $skipped, 失败 $failed_svc"
log "========================================"
log "验证命令:"
log "  mysql    : docker exec -it mysql84 mysql -uroot -p"
log "  redis    : docker exec -it redis redis-cli -a \$(grep REDIS_PASSWORD $ROOT_DIR/.password | head -1 | cut -d= -f2) ping"
log "  kafka    : docker exec -it kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list"
log "  kafka-ui : http://<host>:9090"
log "  nebula   : docker exec -it nebula-graphd nebula -addr=127.0.0.1 -port=9669"
log "========================================"

if [[ "$failed_svc" -gt 0 ]]; then
  warn "有 $failed_svc 个服务启动失败，请查看日志: docker compose -f <deploy_dir>/docker-compose.yml logs"
fi

# 即使有服务失败，脚本也正常退出(返回0)，避免阻塞后续部署流程
exit 0
