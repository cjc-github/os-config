# mirrors —— 国内镜像源一键切换（apt / npm registry）

## 一句话作用
**Ubuntu 24.04 系统 apt 源切清华源，区分 x86_64 / arm64（ports）架构；可选跳过重写仅验证 apt 可用性。**
这是整个项目最先执行的模块，为后续所有 apt 安装提速。

## 前置依赖
- `DEPS=`：空（系统最先跑的模块之一）
- `NEEDS_SUDO=1`：写 `/etc/apt/sources.list.d/ubuntu.sources` + 跑 `apt update` 都需要 sudo

## 安装/配置做了什么
1. **识别架构**：用 `dpkg --print-architecture` 决定换源策略（amd64 → `archive.ubuntu.com` 映射；arm64/riscv64/ppc64el → `ports.ubuntu.com` 映射）
2. **定位实际生效的 apt 源文件**：Ubuntu 24.04 用 deb822 格式的 `/etc/apt/sources.list.d/ubuntu.sources`（URIs 字段）；兼容场景下如果 `/etc/apt/sources.list` 还有海外条目也一并替换
3. **幂等判断**：`grep` 当前 URIs，如果已经是 `archive/ports.ubuntu.com` 之外的镜像或自定义源则跳过；`--force` 强制重写
4. **备份 + 重写**：`register_rollback` 备份源文件；`sed -E` 替换 URIs 字段 + 旧 sources.list 的 deb/deb-src 行，覆盖到目标镜像
5. **`wait_for_apt_lock` 等锁 → `with_retry 2 10 -- sudo apt update`**：确认换源后包索引刷新成功

## 验证项
- `/etc/apt/sources.list.d/ubuntu.sources` 存在
- 若未设置 `MIRROR_SKIP_APT=true`：deb822 URIs 里不应再出现 `archive/ports/security.ubuntu.com`（否则告警）
- `sudo -n apt-get check` 包索引通过

## 可配置参数表

| 变量 | 默认值 | 说明 |
|---|---|---|
| MIRROR_APT_URL | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu` | amd64/i386 目标镜像（阿里云：`https://mirrors.aliyun.com/ubuntu`） |
| MIRROR_APT_PORTS_URL | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports` | arm64/riscv64/ppc64el 等 ports 目标镜像 |
| MIRROR_SKIP_APT | `false` | `true` 跳过 apt 源重写，只验证 apt 可用性（公司内网离线源场景） |
| MIRROR_SKIP_APT_UPDATE | `false` | `true` 不执行 `apt update`（完全空气隔离环境） |
| MIRROR_COUNTRY | `cn` | 预留：未来按国家选镜像 |

位置：`config/user.env.example`（复制为 `user.env` 后修改）

## 幂等行为
- **配置型**：grep 检查 URIs 内容匹配则跳过，不重写文件
- **`--force`**：哪怕已是镜像，也会走一次备份 → sed → 覆盖（方便切源测试）

## 异常处理接入
- `setup_traps`：中断/失败时自动回滚已备份的源文件（sed 覆盖不会留下半状态）
- `wait_for_apt_lock`：`unattended-upgrades` 等并发 apt 进程时自动等锁（最多 60s）
- `register_rollback`：备份 + 回滚清单
- `with_retry`：`apt update` 网络抖动时重试 2 次（间隔 10s）

## 用法
```bash
./setup.sh --module mirrors                # 只换源（apt update）
./setup.sh --module mirrors --dry-run      # 看要改哪几个源文件
MIRROR_APT_URL=https://mirrors.aliyun.com/ubuntu ./setup.sh --module mirrors
MIRROR_SKIP_APT=true ./setup.sh --all      # 跳过敏捷重写，直接跑后续模块（内网已自备源场景）
```
