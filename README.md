# IKEv2/IPsec VPN 服务端（Debian，单脚本部署）

一个 bash 脚本把 Debian 变成安卓原生客户端可直接连接的 IKEv2/IPsec VPN 服务端。支持 **PSK** 与 **EAP-MSCHAPv2** 两种接入方式（可一键切换），IPv4/IPv6 双栈全流量隧道。

- **服务端**：strongSwan（swanctl），Debian 官方源
- **客户端**：Android 11+ 系统自带 VPN，无需安装任何 App
- **产物**：`ikev2.sh` —— 单文件、幂等、可反复执行

## 目录

- [0. 三十秒速览](#0-三十秒速览)
- [1. 前置条件](#1-前置条件)
- [2. 部署](#2-部署)
- [3. 交互式安装](#3-交互式安装)
- [4. 客户端配置](#4-客户端配置)
- [5. 运维命令](#5-运维命令)
- [6. 排障](#6-排障)
- [7. 设计取舍](#7-设计取舍)
- [8. 安全](#8-安全)
- [9. 已知限制](#9-已知限制)
- [10. License](#10-license)

## 0. 三十秒速览

```
① 上传 ikev2.sh 到 Debian 的 /root/
② sed -i 's/\r$//' ikev2.sh      # Windows 传的必须修换行符
③ bash ikev2.sh install          # 一路回车即可
④ 路由器放通 UDP 500 / 4500 到本机
⑤ 照脚本打印的参数填手机
```

## 1. 前置条件

| 项 | 要求 | 备注 |
|---|---|---|
| 操作系统 | Debian / Ubuntu 系 | 其他发行版需自行替换包名与服务名 |
| 权限 | root | 脚本开头会检查，非 root 直接退出 |
| 网络 | 能出公网，且 **UDP 500 / 4500 可从外部访问** | NAT 后需端口转发，见 [§7.1](#71-端口必须放通最高频故障点) |
| 客户端 | Android 11+ | iOS / Windows / macOS / Linux 同样可连，见 [§4.3](#43-其他平台) |
| 磁盘 | 约 50 MB（strongSwan + OpenSSL） | |

IPv6 隧道是**可选增强**，不强制。脚本会自动探测本机是否具备 v6 出网能力，不具备就自动关闭该项。

## 2. 部署

### 2.1 上传到服务器

| 方式 | 操作 |
|---|---|
| Xftp / WinSCP | 把 `ikev2.sh` 拖到 `/root/` |
| scp | `scp ikev2.sh root@服务器IP:/root/` |
| 克隆本仓库 | `git clone <本仓库地址> && cd ikev2-vpn` |
| 没有传输工具 | 服务器上 `cat > /root/ikev2.sh`，粘贴后按 `Ctrl+D` |

### 2.2 执行

```bash
sudo -i                     # 必须 root
cd /root

# Windows 传过去的文件可能带 CRLF 换行，先修一次（否则报 $'\r': command not found）
sed -i 's/\r$//' ikev2.sh

bash ikev2.sh install       # 交互式，一路回车；装完自动打印手机填表参数
bash ikev2.sh status        # 体检
bash ikev2.sh client        # 随时重看手机填表参数
```

要点：

- **不用 `chmod +x`** —— 直接 `bash ikev2.sh` 最稳，传输过程容易丢掉执行权限。
- **中文提示乱码** → 先 `export LANG=C.UTF-8`，纯显示问题，不影响功能。
- **最小化系统没装 curl** → 脚本会自动补装（探测公网 IP 需要）。装不上也能跑，只是探测会退化成网卡地址，此时手动填公网地址即可。
- **脚本幂等** —— 改主意了随时重跑 `install`；防火墙规则"先查后加"不会堆积；**已有 PSK 密钥时默认沿用**，不会让手机上已填的旧密钥失效。

## 3. 交互式安装

`bash ikev2.sh install` 会逐项询问，**每项都带探测出来的默认值和推荐理由，直接回车即采用**：

```
 交互式配置：每项都给出建议值，直接回车即采用建议值
 ─────────────────────────────────────────────────
  [1] 手机连接用的公网地址
      建议: NAT 后填路由器 WAN 口公网 IP；动态 IP 强烈建议填 DDNS 域名，IP 变了证书会校验失败
      回车采用 [1.2.3.4]:
  [2] 出口网卡
      建议: 发出互联网流量的网卡，探测值通常就是对的
      回车采用 [eth0]:
  [3] 客户端 IPv4 地址池
      建议: 避开家里/机房已在用的网段（192.168.x、10.0.x 之类），冲突会导致客户端上不了网
      回车采用 [10.29.7.0/24]:
  [4] 推送给客户端的 IPv4 DNS
      1) 223.5.5.5,119.29.29.29        阿里+腾讯，国内站点解析快
      2) 1.1.1.1,8.8.8.8              Cloudflare+Google，境外站点友好
      3) 114.114.114.114,223.5.5.5     114DNS+阿里，北方联通/电信稳
      输入序号或直接填值，回车采用 [223.5.5.5,119.29.29.29]:
  [5] 启用 IPv6 隧道
      建议: 只有本机确实有 IPv6 出网能力才开，否则客户端 v6 流量会被黑洞
      回车采用 [yes] (y/n):
  [6] 客户端 IPv6 地址池
      建议: 用 fd00::/8 开头的私有段即可，不要和本机现网 v6 段重叠
      回车采用 [fd00:29:7::/64]:
  [7] 推送给客户端的 IPv6 DNS
      1) 2400:3200::1,2402:4e00::                  阿里+腾讯 IPv6
      2) 2606:4700:4700::1111,2001:4860:4860::8888 Cloudflare+Google IPv6
      输入序号或直接填值，回车采用 [2400:3200::1,2402:4e00::]:
  [8] 接入模式
      1) psk   共享密钥：手机不用装证书，最省事（推荐先跑通）；多设备共用一把，无法按人吊销
      2) eap   账号密码：可按人增删，手机可选装 CA 来校验服务器身份
      输入序号或直接填值，回车采用 [psk]:
  [9] PSK 标识符（手机上的 IPsec 标识符）
      建议: 手机 PSK 模式必须填得和这里完全一致，填错会认证失败；填设备名方便识别，如 android、mi13
      回车采用 [android]:
  [10] 自己指定 PSK 密钥
      建议: 选 y 可自己定；留 n 由脚本随机生成 32 字节十六进制，抗爆破更安全
      回车采用 [no] (y/n):
 ─────────────────────────────────────────────────
  连接地址    : 1.2.3.4
  出口网卡    : eth0
  IPv4 地址池 : 10.29.7.0/24   DNS: 223.5.5.5,119.29.29.29
  IPv6 隧道   : 开 fd00:29:7::/64
  接入模式    : psk    标识符: android
 ─────────────────────────────────────────────────
  确认开始安装? [Y/n]:
```

> 选 `eap` 会接着问用户名和两次密码；选 `psk` 则问标识符和是否自定密钥。编号会跟着走，不用记。
> 最后一问输 `n` 会**直接退出且不做任何改动**，可以放心试。

各项说明：

| 项 | 说明 |
|---|---|
| 公网 IP / 域名 | 依次用 **ip.3322.net → myip.ipip.net → myip.aliyun.com** 探测（国内服务优先，境外仅兜底）。若探测到 `192.168.x / 10.x / 172.16-31.x / 100.64-127.x` 这类内网地址，会直接提示"本机在 NAT 后"，此时**必须手动填路由器 WAN 口公网 IP 或 DDNS 域名** |
| IPv6 隧道 | 本机没有 IPv6 默认路由时默认值自动变成 `no`，选了 yes 也白搭 |
| 地址池 | 与现有路由网段重叠时会告警并要求换一个 |
| 接入模式 | `psk`=共享密钥（推荐先跑通），`eap`=账号密码。**同一地址只能生效一种**，原因见 [§7.2](#72-为什么-psk-和-eap-只能二选一) |
| PSK 标识符 | 自定义，默认 `android`。手机 PSK 模式必须原样填写，填错直接认证失败 |
| PSK 密钥 | 默认随机生成 32 字节十六进制；也可自己指定（选 `y`），建议 24 位以上 |
| EAP 密码 | 隐藏输入、输两次校验，不允许空格/冒号/引号/反斜杠 |
| 菜单项 | 输**序号**选推荐项，也可直接填自己的值（DNS、模式都是菜单） |

安装结束后**自动打印客户端填表参数**（密钥、标识符、EAP 账号、CA 证书路径一屏给全），随时可 `bash ikev2.sh client` 重看。

**无人值守 / 脚本化部署**：

```bash
bash ikev2.sh install --auto              # 全程用默认值，不提问
INSTALL_AUTO=yes bash ikev2.sh install   # 等价写法
```

`--auto` 适合放进 cloud-init 或批量部署。此时若脚本头部变量区已填值就用那些值，否则用探测值。手动改脚本头部的变量区仍然有效——**那些值会成为交互时的默认值**。

## 4. 客户端配置

### 4.1 Android

设置 → 网络与互联网 → VPN → 右上角 `+`

**方式一：PSK（简单，一把密钥多设备共用）**

| 字段 | 值 |
|---|---|
| 类型 | IKEv2/IPsec PSK |
| 服务器地址 | `vpn.你的域名.com` |
| IPsec 标识符 | 安装时设定的那个，默认 `android`（**必须完全一致**） |
| IPsec 预共享密钥 | `bash ikev2.sh client` 打印的那串 |

**方式二：EAP-MSCHAPv2（每人独立账号，可单独吊销）**

| 字段 | 值 |
|---|---|
| 类型 | IKEv2/IPsec MSCHAPv2 |
| 服务器地址 | `vpn.你的域名.com` |
| IPsec 标识符 | 你的客户端 ID，如 `alice` |
| 用户名 / 密码 | `useradd` 添加的那组 |
| IPsec CA 证书 | 可选，见下 |

> **关于"IPsec 标识符"**：这是**客户端自己的身份（IDi）**，不是服务端身份。安卓的原生界面把它放在这个标签下，容易误解。服务端身份由安卓强制取"服务器地址"作为 IDr 并校验，所以这一栏填错会导致认证失败。

### 4.2 导入 CA 证书（推荐）

服务端用的是自签 CA。把 `/root/ikev2-ca.crt` 拷到手机：

- **Android**：设置 → 安全 → 加密与凭据 → 安装证书 → **CA 证书** → 选中它
- **iOS**：用 AirDrop / 邮件发给自己 → 设置 → 通用 → VPN 与设备管理 → 安装描述文件 → 装好后到 VPN 设置里选该配置

导入后客户端能**验证服务器身份，防止被冒充**。不导入也能连，只是不校验 —— PSK 模式下尤其建议导入。

### 4.3 其他平台

服务端是标准 strongSwan 配置，**不限于安卓**：

| 平台 | 客户端 | 备注 |
|---|---|---|
| iOS / iPadOS | 系统 VPN，或 strongSwan 官方 App | 系统对证书有效期有 825 天上限，脚本已适配 |
| Windows 10/11 | 设置 → 网络和 Internet → VPN → 添加 | 选 IKEv2，可用用户名密码 |
| macOS | 系统 VPN，或 strongSwan 官方 App | |
| Linux | strongSwan 官方 App / NetworkManager | |
| 路由器 / 软路由 | 多数支持 IKEv2 的设备 | 需注意部分设备不支持 EAP 或不支持 PSK 自定义 IDi |

各平台在 **"服务端标识 / Remote ID"** 那一栏都应填**服务器地址**（与安卓同源约束），详见 [§7.2](#72-为什么-psk-和-eap-只能二选一)。

## 5. 运维命令

```bash
bash ikev2.sh install                 # 安装 / 重装备（默认交互式，--auto 免提问）
bash ikev2.sh status                  # 体检：服务 / 连接 / 在线客户端 / 端口 / 转发 / NAT / 日志
bash ikev2.sh client                  # 重新打印客户端填表参数
bash ikev2.sh users                   # 列出 EAP 用户
bash ikev2.sh useradd alice '密码'     # 加用户（同名覆盖 = 改密）
bash ikev2.sh userdel alice           # 删用户
bash ikev2.sh rotate-psk              # 换 PSK，旧密钥立即失效（全体需重填）
bash ikev2.sh mode psk|eap            # 切换接入模式
bash ikev2.sh diag                    # 连不上时的诊断：体检 + 抓包 25 秒 + 过滤错误日志
bash ikev2.sh uninstall               # 清除配置
```

实时看连接日志：

```bash
journalctl -u strongswan -f
```

在线客户端与 SA 状态：

```bash
swanctl --list-conns       # 已加载的连接
swanctl --list-sas         # 当前活跃的 SA
ip pool show               # 地址池分配情况
```

## 6. 排障

### 6.1 一键诊断（推荐先跑这个）

```bash
bash ikev2.sh diag
```

它会一次性完成：体检 → 打印身份一致性核对 → 抓 25 秒包 → 过滤出错误日志。

**提示出现后，用客户端发起一次连接**，然后看结果：

| 抓包结果 | 含义 | 下一步 |
|---|---|---|
| **一行都没有** | 包没到服务器 | 端口转发 / 安全组没放行 UDP 500+4500 |
| 有包，但只有 UDP 500 阶段 | 走到 NAT-T 切换 | 检查 UDP 4500 转发 |
| 有包但认证失败 | 身份或密钥不匹配 | 看下方排障表对应条目 |

### 6.2 排障表

| 现象 / 日志关键字 | 原因 | 处理 |
|---|---|---|
| 点连接立刻失败，服务端日志**完全没有包** | 端口没通 | 查路由器端口转发 / 云安全组 UDP 500+4500 |
| `no proposal chosen` | 算法或 IKE 版本不匹配 | 确认选的是 **IKEv2** 开头的类型，不是 L2TP / IPsec Xauth |
| `AUTHENTICATION_FAILED`、`no shared key found` | PSK 密钥不对 | 用 `client` 核对，注意别多粘空格 |
| `constraint check failed: identity 'xxx' required` | 客户端 IDi 与服务端要求的不一致 | PSK 模式标识符必须原样填你设定的那个（默认 `android`） |
| `looking for peer configs matching ...` 中 IDr 与 local id 不符 | 服务端身份 ≠ 客户端填的服务器地址 | 重跑 `install`，或用 `mode` 切到当前模式 |
| `no matching connection` / `no peer config found` | 当前模式的连接没加载 | `swanctl --list-conns` 看有没有 `rw-psk` / `rw-eap`，没有就重跑 `install` |
| `EAP failure`、`MSCHAPv2` 失败 | 账号密码错 | `users` 核对，重新 `useradd` 覆盖 |
| 连上后能 ping 通 IP 但**网页打不开** | MTU / MSS 黑洞 | 检查 mangle 表 `TCPMSS --set-mss 1360` 规则是否生效 |
| 连上后 IPv6 网站不通 | 服务端无 v6 出网 | `ip -6 route show default`，无则属预期（脚本已自动关闭 v6 隧道） |
| 第二台设备连上后第一台掉线 | `unique` 设置问题 | 脚本已设 `unique = never`，若手改过配置请改回 |
| 证书校验失败 | 服务器地址变了（动态 IP） | 换 DDNS 域名，或删掉 `server.crt` 后重跑 `install` 重签 |

### 6.3 手工抓包

```bash
tcpdump -ni any 'udp port 500 or udp port 4500 or proto 50'
```

## 7. 设计取舍

这一节解释脚本里那些"看起来奇怪"的做法，都是踩过坑之后的选择。

### 7.1 端口必须放通（最高频故障点）

| 端口 | 用途 | 必须 |
|---|---|---|
| UDP 500 | IKE | ✅ |
| UDP 4500 | NAT-T（封装后的 ESP） | ✅ |
| IP 协议 50（ESP） | 非 NAT 直连时的加密流量 | 建议 |

- **云主机** → 安全组放行 UDP 500、4500。
- **NAT 后（家宽 / 内网部署）** → 在路由器把 **UDP 500 和 4500 转发到 Debian 内网 IP**。交互安装第 [1] 问要填**客户端能连到的公网 IP 或 DDNS 域名**（脚本探测到的是出网 IP，NAT 场景通常不能直连）。

> 动态公网 IP **一定用 DDNS 域名**：服务端身份的 IDr 与客户端填的服务器地址都基于这个值，IP 变了不改就会出现身份不匹配或证书校验失败。

### 7.2 为什么 PSK 和 EAP 只能二选一

安卓原生客户端的身份处理是硬编码的（AOSP `VpnIkev2Utils.java`）：

```java
localId  = parseIkeIdentification(profile.getUserIdentity()); // 客户端填的"IPsec 标识符" → 客户端身份 IDi
remoteId = parseIkeIdentification(profile.getServerAddr());   // 服务端身份 IDr，强制 = 服务器地址
```

由此推出三条硬约束：

1. **服务端身份必须等于客户端填的服务器地址** —— 不能自造一个 `psk.xxx` 之类的名字，否则安卓直接拒绝。
2. **客户端填的"IPsec 标识符"是它自己的身份**，不是服务端的。
3. 既然 IDr 被安卓写死成服务器地址，**服务端就没法靠身份区分"这是 PSK 客户端还是 EAP 客户端"** —— 两个连接只会命中同一个，另一个必失败。

所以脚本**不提供 both 选项**：

| 模式 | 服务端身份 | 客户端 identifier | 适用场景 |
|---|---|---|---|
| `psk` | `VPN_HOST` | 你设定的 PSK 标识符（默认 `android`） | 自己用、设备少、图省事 |
| `eap` | `VPN_HOST`（证书 CN/SAN） | 任意，习惯上填用户名 | 需要按人增删、单独吊销 |

想换模式随时切，不用重装：

```bash
bash ikev2.sh mode eap      # 切到账号密码模式
bash ikev2.sh mode psk      # 切回共享密钥模式（会重新生成密钥）
```

### 7.3 PSK 模式下有两条连接（日志里会看到）

脚本为 PSK 模式生成**两条**连接：

| 连接 | remote id | 作用 |
|---|---|---|
| `rw-psk` | 等于你设定的标识符 | 正常走这条，日志可读性好 |
| `rw-psk-any` | `%any` | 兜底。部分安卓 ROM / 运营商定制版会发空 IDi 或非预期身份，严格匹配会直接 `no matching connection`，连握手都进不去 |

日志里出现 `switching to connection 'rw-psk-any'` **是正常的**，不是错误。两条连接用同一把密钥、同一组地址池，安全性不变。

### 7.4 IPv6 双栈是自动开关

脚本检测本机有没有 IPv6 默认路由：

- **有** → 下发 IPv6 虚拟地址 + IPv6 DNS，`local_ts` 含 `::/0`，v6 流量同样走隧道并做 MASQUERADE。
- **没有** → 自动关闭 IPv6 隧道，避免把客户端的 v6 流量送进黑洞。

前提：Debian 机器本身有全局 IPv6 且能出网。路由器侧 v6 防火墙同样要放行 UDP 500/4500。

### 7.5 为什么装了两个 mangle 规则

| 规则 | 解决什么 |
|---|---|
| `FORWARD -s <客户端池> -j TCPMSS --set-mss 1360` | **最高频"假故障"**：不加这条手机能 ping 通、能握手，但网页打不开（TCP 包在隧道里被分片丢弃） |
| `FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` | 通用兜底，处理其他路径的 PMTU 发现 |

MSS clamp 限定了来源地址，**不会误伤服务器上其它转发流量**。

## 8. 安全

### 8.1 密钥与凭据位置

| 内容 | 路径 | 权限 |
|---|---|---|
| PSK 共享密钥 | `/etc/swanctl/conf.d/ikev2-psk.conf` | 600 |
| 服务端证书 / 私钥 | `/etc/swanctl/{certs,private}/` | 600 |
| 自签 CA 证书（拷到客户端用） | `/root/ikev2-ca.crt` | 644 |
| 自签 CA **私钥** | `/etc/swanctl/private/ca.key` | **600，绝不外传** |
| EAP 用户表（明文） | `/etc/ikev2-vpn/users.list` | 600 |
| 安装状态 | `/etc/ikev2-vpn/env` | 600 |

**EAP 用户密码是明文存储的**（strongSwan 的 `eap-mschapv2` 机制如此），因此该文件权限必须是 600。

### 8.2 必须知道的三个短板

1. **PSK 模式没有服务器身份验证**
   客户端先发认证载荷、后验证服务端 —— 任何拿到密钥的人都能冒充你的服务器，弱密钥还可被离线爆破。
   → 缓解：脚本用 `openssl rand -hex 32` 生成（已如此），**不要改成你能记住的密码**；并**导入 CA 证书**。

2. **PSK 无法按人吊销**
   一把密钥共用，要踢人只能 `rotate-psk` 全体换密钥。
   → 需要按人管理请用 EAP 模式（`userdel` 即可）。

3. **自签 CA 私钥泄露 = 服务端可被完全冒充**
   → `/etc/swanctl/private/ca.key` 不要外传、不要进版本库。

### 8.3 证书有效期

服务端证书有效期 **825 天**（iOS 对更长有效期会直接拒绝）。
到期前重新签发：

```bash
rm /etc/swanctl/certs/server.crt
bash ikev2.sh install
```

### 8.4 报告安全问题

请勿开公开 Issue。见 [SECURITY.md](SECURITY.md)。

## 9. 已知限制

- **只支持 Debian/Ubuntu 系**。其他发行版需自行替换包名、服务名与防火墙后端。
- **PSK 与 EAP 不能同时生效**（安卓把服务端身份写死为服务器地址，服务端无法区分认证方式）。选一种，用 `mode` 切换。
- PSK 模式下密钥是"一把多设备共用"。想按设备 / 按人管理，请用 EAP 模式。
- IPv6 隧道依赖服务器自身有 v6 出网能力，脚本只做探测与开关，不负责申请 v6。
- `uninstall` **不卸载 strongSwan 软件包，也不回滚防火墙规则**（避免误删你自己的规则），需手动清理。
- 脚本不做用户数据备份；重跑 `install` 会覆盖配置文件。

## 10. License

[MIT](LICENSE) © ikev2-vpn contributors

## 致谢

- [strongSwan](https://www.strongswan.org/) —— 实际的 IKE/IPsec 实现
- 本项目踩过的坑已尽量写进 [§6 排障](#6-排障) 与 [§7 设计取舍](#7-设计取舍)，欢迎提 Issue 补充





