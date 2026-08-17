# net-ssh

安装 `openssh-client` 并在 `~/.ssh` 下非交互生成 SSH 密钥对。`openssh-server` 默认不安装。

## 配置

```bash
SSH_INSTALL_SERVER=false   # true 才安装并验证 openssh-server
SSH_KEY_TYPE=ed25519       # ed25519 或 rsa
SSH_KEY_PASSPHRASE=        # 留空表示无口令
```

`SSH_KEY_PASSPHRASE` 保存在 `config/user.env` 时是明文；如需高安全性，建议安装后交互设置口令，不要把秘密提交到仓库。

## 行为

1. 校验布尔值和密钥类型。
2. 通过 `dpkg-query` 判断缺失的软件包，只安装缺失项。
3. 创建 `~/.ssh` 并设为 `700`。
4. 密钥不存在时生成；已存在时不覆盖。
5. 私钥设为 `600`，公钥设为 `644`。

验证脚本会检查客户端、按配置检查服务端、检查密钥对和私钥权限。
