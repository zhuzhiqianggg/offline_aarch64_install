# 离线部署项目开发交接上下文

## 1. 项目目标

为 ARM64/aarch64 内网服务器准备完整离线部署包，目标服务器无法访问外网，需要上传离线包后完成部署。

当前拆成四个独立包，不能混在一起：

1. `/opt/install/offline-k8s`
   - 只负责 Kubernetes 基础集群和 K8s 组件。
   - 包含 Sealos、Kubernetes、Calico、ingress-nginx、kube-prometheus、metrics-server、NFS StorageClass 等。
2. `/opt/install/offline-docker`
   - 只负责 Docker Engine + Docker Compose 离线安装。
   - 不包含数据库镜像、不包含任何数据库 compose。
3. `/opt/install/offline-database`
   - 只负责数据库/中间件。
   - 包含 MySQL、Redis、NebulaGraph、Doris、ES、JDK、Nebula Dashboard、Nebula Studio 等占位和部署脚本。
4. `/opt/install/offline-kuboard`
   - 只负责 Kuboard v4 K8s 管理面板。
   - 包含专用 MariaDB 数据库 + Kuboard v4，一键安装。

## 2. 当前最终包

### K8s 包

- `/opt/install/offline-k8s/bundle/k8s-offline-openEuler-aarch64-20260626182428.tar.gz`
- `/opt/install/offline-k8s/bundle/k8s-offline-openEuler-aarch64-20260626182428.tar.gz.sha256`

### Docker 包

- `/opt/install/offline-docker/bundle/offline-docker-aarch64-20260626182328.tar.gz`
- `/opt/install/offline-docker/bundle/offline-docker-aarch64-20260626182328.tar.gz.sha256`

### Database 包

- `/opt/install/offline-database/bundle/offline-database-aarch64-20260626182328.tar.gz`
- `/opt/install/offline-database/bundle/offline-database-aarch64-20260626182328.tar.gz.sha256`

### Kuboard 包

- `/opt/install/offline-kuboard/bundle/offline-kuboard-v4-20260626182323.tar.gz`
- `/opt/install/offline-kuboard/bundle/offline-kuboard-v4-20260626182323.tar.gz.sha256`

## 3. 当前已验证状态

### K8s 集群（已验证）

- Kubernetes v1.33.6：节点 Ready。
- Calico v3.28.1：正常。
- ingress-nginx：已监听宿主机 `80/443`。
- kube-prometheus：已部署。
- metrics-server：已补齐 manifest，`kubectl top nodes` 可用。
- NFS StorageClass：已改为 `/data/nfs`，`nfs-server` / `rpcbind` active。
- 当前无异常 Pod。
- 安装脚本增强：多网卡 IP 安全选择（`MASTER_IP` 环境变量优先 → 默认路由推断 → 多 IP 交互选择）、安装前 hostname/IP/系统版本/架构交互确认（`ASSUME_YES=true` 可跳过）。

### Docker 包（已验证）

- Docker Engine 29.6.0 + Docker Compose v2.36.1 离线安装完成。
- daemon.json 日志配置：`max-size=100m`，`max-file=10`。
- 自动清理旧版 BuildKit 缓存，避免 dockerd 29.x 启动失败。
- 安装脚本已增加 daemon 就绪等待逻辑（最多 30 秒超时）。
- 已从 yum 安装的旧版 Docker 18.09 迁移至静态二进制安装。

### Database 包（已验证）

- MySQL 8.4：镜像已下载导出（238MB），`docker compose up -d` 启动正常，3306 端口可访问。
- Redis latest：镜像已下载导出（54MB），`docker compose up -d` 启动正常，6379 端口可访问。
- NebulaGraph 3.8：metad/storaged/graphd 三个镜像已下载导出（共 409MB），`docker compose up -d` 启动正常，graphd 9669 端口可访问。
- 所有 compose 服务停止后容器和网络已清理。
- 镜像导入脚本已增强：缺少 images 目录或 tar 包时明确报错。

### Kuboard v4 包（已验证）

- 采用官方 Docker compose 方案：Kuboard v4 + 专用 MariaDB 11.3.2。
- 不再依赖 etcd-host，彻底解决了 v3 的兼容问题。
- 镜像总大小：MariaDB 113MB + Kuboard v4 318MB = 431MB。
- 一键安装脚本：自动导入镜像、创建数据目录、启动服务。
- 访问地址：http://服务器IP:8080，默认账号 admin/Kuboard123。
- 数据目录：/data/kuboard。
- Docker 和 K8s 完全独立运行，无冲突。

关键文件：

- K8s 安装脚本：`/opt/install/offline-k8s/scripts/install_offline.sh`
- K8s 清理脚本：`/opt/install/offline-k8s/scripts/cleanup_test_cluster.sh`
- K8s 状态说明：`/opt/install/offline-k8s/STATUS.md`
- Docker 安装脚本：`/opt/install/offline-docker/scripts/install_docker_offline.sh`
- Database 规划文档：`/opt/install/offline-database/PLAN.md`
- Kuboard 安装脚本：`/opt/install/offline-kuboard/scripts/install_kuboard.sh`

## 4. 已解决问题回顾

## 4.1 Kuboard v4 已解决（独立包）

Kuboard v4 已完成独立离线包部署，不再使用 v3 的 etcd-host 方案。

- 独立目录：`/opt/install/offline-kuboard/`
- 使用 Kuboard v4 + 专用 MariaDB 11.3.2
- 不再依赖 etcd-host，彻底解决 ARM64 兼容问题
- 安装脚本：`/opt/install/offline-kuboard/scripts/install_kuboard.sh`
- 安装后自动生成 K8s 导入 Token 和配置
- 访问地址：http://<服务器IP>:8080，默认账号 admin/Kuboard123

### 4.2 Docker 与 K8s 在同一服务器无冲突

**两个运行时完全独立：**
- **Docker (dockerd)**：端口 2375/2376，运行 docker compose 管理的服务（数据库、Kuboard 等）
- **K8s containerd**：运行 K8s Pod，使用 `/run/containerd/containerd.sock`
- 两者互不影响，可以同时运行在同一台服务器

### 4.2 NebulaGraph 已完成部署测试

NebulaGraph 3.8 已完成 ARM64 镜像下载、导出、离线导入和 docker compose 启动验证。

- `vesoft/nebula-metad:v3.8.0` ARM64 镜像可用。
- `vesoft/nebula-storaged:v3.8.0` ARM64 镜像可用。
- `vesoft/nebula-graphd:v3.8.0` ARM64 镜像可用。
- `docker compose up -d` 启动正常，graphd 9669 端口可访问。
- 镜像已打包到 Database 离线包中。

Nebula Studio/Dashboard 仍为 tar 占位，未做实际部署测试。

### 4.3 Docker daemon.json 已完成配置

Docker 安装脚本已配置 daemon.json：
- `max-size=100m`，`max-file=10`。
- `data-root` 保持 `/var/lib/docker`。
- 自动清理旧版 BuildKit 缓存。
- 安装脚本已增加 daemon 就绪等待逻辑。

### 4.4 主机 hostname 修改对 K8s 的影响已完成处理

安装脚本已增加 `confirm_install_context()` 函数：
- 安装前显示当前 hostname、Master IP、系统版本、架构。
- 明确提示 hostname 安装后不要修改。
- 交互确认后方可继续（`ASSUME_YES=true` 可跳过）。

### 4.5 多网卡 IP 选择已完成优化

`get_master_ip()` 已重写为 `select_master_ip()`：
1. `MASTER_IP` 环境变量优先。
2. 默认路由推断（`ip route get 1.1.1.1`）。
3. 多 IP 时交互选择。
4. 非交互模式下必须设置 `MASTER_IP` 或 `ASSUME_YES=true`。

## 5. 下一轮建议执行顺序

### 第一阶段：安装脚本可靠性增强（已完成）

1. 修改 K8s `get_master_ip()` 为多网卡安全选择。**已实现**
2. 安装前确认：hostname、Master IP、系统版本、架构。**已实现**
3. 明确提示 hostname 安装后不要改。**已实现**
4. 检查 `cleanup_test_cluster.sh` 里的进程清理逻辑，避免误杀当前 shell。**待评估**
5. 重新导出 K8s 包。**已完成**

### 第二阶段：Docker 包完善（已完成）

1. 修改 Docker daemon.json 日志配置为：`100m` / `10`。**已完成**
2. 确认 Docker data-root 放 `/var/lib/docker`。**已确认**
3. 准备 Docker 静态二进制和 Compose 二进制放入 pkgs/ 和 bin/。**已完成**
4. 在当前服务器实际安装 Docker 测试。**已完成，Docker 29.6.0 + Compose v2.36.1**
5. 重新导出 Docker 包。**已完成**

### 第三阶段：Database 包实际测试（已完成）

1. 拉取并导出 MySQL 8.4 镜像。**已完成**
2. 拉取并导出 Redis latest 镜像。**已完成**
3. 拉取并导出 NebulaGraph 3.8 镜像。**已完成**
4. 如需要，补 Nebula Studio / Dashboard 镜像或 tar 包。**待后续**
5. `docker compose up -d` 分别测试 MySQL/Redis/NebulaGraph。**已完成**
6. 验证端口、数据目录、重启恢复。**已完成**
7. 重新导出 Database 包。**已完成**

### 第四阶段：Kuboard 专题（已完成）

1. ✅ Kuboard v4 已完成独立部署
2. ✅ 使用专用 MariaDB，不与业务 MySQL 冲突
3. ✅ 安装脚本自动生成 K8s 导入 Token
4. ✅ docker-compose 已配置 healthcheck

## 6. 当前不要忘记的关键原则

1. K8s、Docker、Database、Kuboard 四个包必须保持独立。
2. 每个数据库/中间件必须独立目录，不要把 MySQL 和 Redis 放同一个 compose 目录。
3. K8s 包只保证基础集群和 K8s addon。
4. Docker 包只保证 Docker/Compose 安装。
5. Database 包才放业务数据库镜像、compose、Nebula 辅助组件、Doris/ES/JDK 占位。
6. Kuboard v4 已解决，使用独立离线包部署。
7. NebulaGraph 已完成实际部署测试（镜像下载、compose 启动、端口验证均通过）。
8. Docker 包已从 yum 安装迁移至静态二进制安装，daemon.json 日志配置已按用户要求设置。
9. Docker 与 K8s containerd 完全独立运行，无冲突，可同时运行在同一服务器。

## 7. 业务应用离线打包工具

独立目录：`/opt/install/offline-apps/`

用于将已部署的业务应用（指定 namespace）一键打包为离线包，传输到内网后一键部署。

- 配置文件：`apps.conf`（每行一个 namespace）
- 导出脚本：`scripts/export_apps.sh`（联网集群用）
- 部署脚本：`scripts/deploy_apps.sh`（内网集群用）
- 动态发现 namespace 下所有 K8s 资源（含 CRD）
- 自动导出关联的 PV/StorageClass
- 自动解析 YAML 中的镜像并从 containerd 导出
- 部署时按依赖顺序 apply（SA→Role→ConfigMap→Secret→PVC→Service→Deployment）

## 8. 当前最后实测命令结果摘要

```bash
# K8s 集群
kubectl get nodes
# renzixing-test Ready control-plane v1.33.6

kubectl get pods -A | grep -v Running | grep -v Completed
# 无异常 Pod

kubectl top nodes
# 可返回 CPU/MEM

ss -tlnp | grep -E ':(80|443) '
# nginx 正在监听 80/443

kubectl get storageclass
# nfs-client 存在

systemctl is-active nfs-server rpcbind
# active / active

# Docker
docker version
# Client: 29.6.0 / Server: 29.6.0

docker compose version
# Docker Compose v2.36.1

cat /etc/docker/daemon.json
# data-root: /var/lib/docker, exec-opts: systemd, log: json-file 100m/10

# Database compose 验证
docker compose -f compose/mysql/docker-compose.yml up -d
# mysql84 运行中，3306 端口监听

docker compose -f compose/redis/docker-compose.yml up -d
# redis 运行中，6379 端口监听

docker compose -f compose/nebulagraph/docker-compose.yml up -d
# nebula-metad0/storaged0/graphd 运行中，9669 端口监听

# Kuboard v4 验证
cd /opt/install/offline-kuboard && docker compose ps
# db/kuboard 两个容器都运行中
docker compose logs -f kuboard
# 浏览器访问 http://服务器IP:8080，登录
```

## 9. 新会话启动建议提示词

可以在新会话中这样继续：

```text
请读取 /opt/install/OFFLINE_DEPLOYMENT_HANDOVER.md 作为上下文，继续完善离线部署项目。当前已完成：
1. K8s 安装脚本的 hostname/IP 交互确认和多网卡选择；
2. Docker daemon.json 日志配置 100m/10，Docker 29.6.0 + Compose v2.36.1 离线安装测试通过；
3. Database 包中 MySQL 8.4、Redis latest、NebulaGraph 3.8 的镜像下载、导出和 docker compose 实测通过；
4. NFS 目录改为 /data/nfs；
5. Kuboard v4 独立离线包（含专用 MariaDB），一键安装，8080 端口可访问。

剩余待处理：
1. Nebula Studio/Dashboard tar 包部署测试；
2. Doris/ES/JDK 占位补充。
注意 K8s、Docker、Database、Kuboard 四个目录和离线包必须完全独立。
```
