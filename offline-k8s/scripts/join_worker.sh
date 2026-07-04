#!/usr/bin/env bash
# join_worker.sh - Worker 节点加入脚本
# 在已部署 K8s 集群的 worker 节点上执行此脚本，加入现有集群
#
# 使用方式:
#   1. 在 master 节点执行 ./scripts/print_join_command.sh 打印 join 命令
#   2. 复制打印的命令到 worker 节点执行
#   3. 或在 worker 节点上:
#      JOIN_TOKEN=xxx JOIN_CMD="kubeadm join ..." ./scripts/join_worker.sh

set -euo pipefail

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { log "ERROR: $*"; exit 1; }

# ERR trap
trap 'ret=$?; echo "[$(date "+%F %T")] ERROR at line $LINENO (exit code $ret)" >&2' ERR

[[ $EUID -eq 0 ]] || fatal "请使用 root 执行"

# 1. 加载 K8s 集群镜像（sealos-images）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# 读取架构配置
for _p in "$ROOT_DIR/arch.env" "$ROOT_DIR/../arch.env" "$ROOT_DIR/config/arch.env"; do
  if [[ -f "$_p" ]]; then
    # shellcheck disable=SC1090
    source "$_p"
    break
  fi
done
ARCH="${ARCH:-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"

# 2. 安装 sealos (用于加载 cluster image)
if ! command -v sealos >/dev/null 2>&1; then
  if [[ -f "$ROOT_DIR/bin/${ARCH}/sealos" ]]; then
    install -m 0755 "$ROOT_DIR/bin/${ARCH}/sealos" /usr/local/bin/sealos
    log "sealos 已安装: $(sealos version 2>&1 | head -1)"
  else
    fatal "未找到 sealos 二进制 (bin/${ARCH}/sealos)"
  fi
fi

# 3. 安装 kubeadm (用于执行 kubeadm join)
if ! command -v kubeadm >/dev/null 2>&1; then
  if [[ -f "$ROOT_DIR/pkgs/${ARCH}/kubeadm" ]]; then
    install -m 0755 "$ROOT_DIR/pkgs/${ARCH}/kubeadm" /usr/local/bin/kubeadm
    log "kubeadm 已安装"
  else
    # 尝试从 sealos cluster image 中提取 kubeadm
    if [[ -f "$ROOT_DIR/sealos-images/${ARCH}/kubernetes-${KUBERNETES_VERSION:-v1.33.6}-${ARCH}.tar" ]]; then
      log "从 sealos cluster image 提取 kubeadm"
      # cluster image tar 中包含 kubeadm 二进制
      sealos load -i "$ROOT_DIR/sealos-images/${ARCH}/kubernetes-${KUBERNETES_VERSION:-v1.33.6}-${ARCH}.tar" 2>/dev/null || true
    fi
  fi
fi

# 4. 准备系统 (关闭 swap, 加载 br_netfilter 等)
log "准备 worker 节点系统"
swapoff -a 2>/dev/null || true
sed -i '/\sswap\s/d' /etc/fstab 2>/dev/null || true

# 加载内核模块
modprobe br_netfilter 2>/dev/null || true
modprobe overlay 2>/dev/null || true

# 配置 sysctl
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-k8s.conf >/dev/null 2>&1 || true

# 5. 接受 JOIN_TOKEN 或 JOIN_CMD 参数
if [[ -z "${JOIN_CMD:-}" ]]; then
  cat <<'EOF'

[ERROR] 必须提供 JOIN_CMD 参数

使用步骤:
  1. 在 master 节点执行:
       sudo kubeadm token create --print-join-command

  2. 复制完整命令 (例如):
       kubeadm join 192.168.1.10:6443 --token abcdef.0123456789abcdef \
         --discovery-token-ca-cert-hash sha256:xxxxx

  3. 在 worker 节点执行:
       JOIN_CMD="<上面复制的完整命令>" sudo ./scripts/join_worker.sh

EOF
  exit 1
fi

# 6. 执行 kubeadm join
log "执行: $JOIN_CMD"
if $JOIN_CMD; then
  log "========================================"
  log "Worker 节点加入成功！"
  log "在 master 节点执行 'kubectl get nodes' 查看新节点"
  log "========================================"
else
  fatal "Worker 节点加入失败，请检查上面的错误信息"
fi
