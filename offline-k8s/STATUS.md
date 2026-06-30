# 离线部署包 - 最终状态

## 当前结论

已按要求拆成四个独立目录和四个独立离线包：

1. `/opt/install/offline-k8s`：只负责 Kubernetes 基础集群和 K8s 组件。
2. `/opt/install/offline-docker`：只负责 Docker Engine + Docker Compose 离线安装。
3. `/opt/install/offline-database`：只负责 MySQL、Redis、NebulaGraph、Doris、ES、JDK 等数据库/中间件。
4. `/opt/install/offline-kuboard`：只负责 Kuboard v4 K8s 管理面板（含专用 MariaDB）。

## K8s 离线包

### 已验证通过

- Kubernetes: v1.33.6
- Calico: v3.28.1
- Sealos: v5.1.1
- ingress-nginx: controller-v1.15.1
- kube-prometheus: Prometheus + Grafana + Alertmanager + node-exporter
- metrics-server: v0.7.1
- NFS StorageClass: `nfs-client`
- kubectl 自动补全
- Sealos 默认 100 年证书

### 当前实测结果

- 节点：Ready
- 异常 Pod：无
- `kubectl top nodes`：可用
- ingress-nginx：宿主机监听 80/443
- NFS 服务：`nfs-server`、`rpcbind` active

### 最终包

- `/opt/install/offline-k8s/bundle/k8s-offline-openEuler-aarch64-20260626182428.tar.gz`
- `/opt/install/offline-k8s/bundle/k8s-offline-openEuler-aarch64-20260626182428.tar.gz.sha256`

### Kuboard 策略

Kuboard 不再作为 K8s 基础包默认部署。

原因：Kuboard v3 官方 YAML 依赖 `eipwork/etcd-host`，在 ARM64 + K8s 1.33 场景下维护成本较高。基础 K8s 包不应被 Kuboard v3 的 etcd-host 问题阻塞。

后续建议：如确实需要 Kuboard，单独评估 Kuboard v4 + 独立数据库，不混入基础 K8s 包。当前 Kuboard v4 已独立为单独离线包（含专用 MariaDB），详见下方"Kuboard 离线包"章节。

## Docker 离线包

只包含 Docker Engine / Docker Compose 安装能力，不包含数据库镜像、不包含 compose 应用。

### 最终包

- `/opt/install/offline-docker/bundle/offline-docker-aarch64-20260626182328.tar.gz`
- `/opt/install/offline-docker/bundle/offline-docker-aarch64-20260626182328.tar.gz.sha256`

目录内容：

- `bin/`: docker-compose 二进制占位
- `pkgs/`: Docker 静态二进制包占位
- `scripts/install_docker_offline.sh`
- `scripts/package_docker_bundle.sh`

## Database / Middleware 离线包

每个数据库/中间件独立目录，不再混放。

### Compose 目录

- `/opt/install/offline-database/compose/mysql/docker-compose.yml`
  - MySQL: `mysql:8.4`
- `/opt/install/offline-database/compose/redis/docker-compose.yml`
  - Redis: `redis:latest`
- `/opt/install/offline-database/compose/nebulagraph/docker-compose.yml`
  - NebulaGraph: `v3.8.0`

### NebulaGraph 辅助组件占位

- `/opt/install/offline-database/third-party/nebula-graph/`
- `/opt/install/offline-database/third-party/nebula-dashboard/`
- `/opt/install/offline-database/third-party/nebula-studio/`

后续你把对应 tar 包放入这些目录，执行：

```bash
./scripts/install_nebula_third_party.sh
```

### 其他中间件占位

- `/opt/install/offline-database/third-party/doris/`
- `/opt/install/offline-database/third-party/elasticsearch/`
- `/opt/install/offline-database/third-party/jdk/`

执行：

```bash
./scripts/install_third_party_placeholders.sh
```

### 最终包

- `/opt/install/offline-database/bundle/offline-database-aarch64-20260626182328.tar.gz`
- `/opt/install/offline-database/bundle/offline-database-aarch64-20260626182328.tar.gz.sha256`

## Kuboard 离线包

只负责 Kuboard v4 K8s 管理面板，含专用 MariaDB 11.3.2，不与 Database 包混用。不再依赖 etcd-host，彻底解决 ARM64 兼容问题。

### 最终包

- `/opt/install/offline-kuboard/bundle/offline-kuboard-v4-20260626182323.tar.gz`
- `/opt/install/offline-kuboard/bundle/offline-kuboard-v4-20260626182323.tar.gz.sha256`

安装脚本：`scripts/install_kuboard.sh`，访问地址：http://<服务器IP>:8080，默认账号 admin/Kuboard123。

## 目标服务器部署顺序

### 1. 安装 K8s

```bash
cd /opt
tar -xzf k8s-offline-openEuler-aarch64-*.tar.gz
cd k8s-offline-openEuler-aarch64
./install_offline.sh
```

### 2. 安装 Docker

```bash
cd /opt
tar -xzf offline-docker-aarch64-*.tar.gz
cd offline-docker-aarch64
./scripts/install_docker_offline.sh
```

### 3. 安装数据库/中间件

```bash
cd /opt
tar -xzf offline-database-aarch64-*.tar.gz
cd offline-database-aarch64
./scripts/load_database_images.sh

cd compose/mysql && docker compose up -d
cd ../redis && docker compose up -d
cd ../nebulagraph && docker compose up -d
```

如果有 Nebula Dashboard / Studio / tar 包：

```bash
cd /opt/offline-database-aarch64
./scripts/install_nebula_third_party.sh
```

## 清理说明

根目录散落的中间镜像 tar 已清理。当前最终需要传输的只有四个包及其 sha256 文件。
