# 密钥与配置

**本文件只是说明文档。** 实际的密钥与用户数据都存放在目标服务器的这些路径下，
本仓库**不包含任何真实密钥、密码或证书**：

| 路径 | 内容 |
|---|---|
| `/etc/ikev2-vpn/env` | 部署参数（服务器地址、网卡、地址池、模式） |
| `/etc/ikev2-vpn/users.list` | EAP 用户名与密码**明文**，格式 `用户名:密码` |
| `/etc/swanctl/conf.d/ikev2-psk.conf` | PSK 预共享密钥 |
| `/etc/swanctl/conf.d/ikev2-eap.conf` | 由 users.list 渲染出的 EAP 密钥块 |
| `/etc/swanctl/private/ca.key` | 自签 CA 私钥（**泄露 = 任何人都能冒充你的 VPN 服务器**） |
| `/etc/swanctl/private/server.key` | 服务端证书私钥 |
| `/root/ikev2-ca.crt` | 导出的 CA 证书，可公开，用于手机导入 |

## 安全约定

- 仓库中的脚本**只包含密钥生成逻辑，不包含任何实际密钥**。PSK 由 `openssl rand -hex 32` 在安装时生成。
- `users.list` 是明文密码，**不要提交到任何仓库**，备份请用密码管理器。
- CA 私钥不要外传。

## 换机迁移

```bash
# 旧机器导出非敏感配置
grep -E '^(VPN_HOST|VPN_IF|POOL4|POOL6|DNS4|DNS6|PSK_IDENT|MODE)=' /etc/ikev2-vpn/env
```

把值填进新机器上脚本头部的变量区后 `bash ikev2.sh install` 即可。
EAP 用户需重新 `useradd`（密码不随仓库迁移）。
