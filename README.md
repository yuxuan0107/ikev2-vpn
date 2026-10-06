# IKEv2/IPsec VPN 服务端（Linux）

用单个 bash 脚本把 Linux 部署成安卓原生客户端可连接的 IKEv2/IPsec VPN 服务端。支持 PSK 与 EAP-MSCHAPv2 两种接入方式，可随时切换，IPv4/IPv6 双栈全流量隧道。

- 服务端：strongSwan（swanctl），各发行版官方源
- 客户端：Android 11 及以上系统自带 VPN，无需安装 App
- 产物：`ikev2.sh` 单文件，幂等，可重复执行

## 目录

- [0. 快速上手](#0-快速上手)
- [1. 支持的系统](#1-支持的系统)
- [2. 前置条件](#2-前置条件)
- [3. 部署](#3-部署)
- [4. 交互式安装](#4-交互式安装)
- [5. 客户端配置](#5-客户端配置)
- [6. 运维命令](#6-运维命令)
- [7. 排障](#7-排障)
- [8. 实现说明](#8-实现说明)
- [9. 安全](#9-安全)
- [10. 已知限制](#10-已知限制)
- [11. License](#11-license)

## 0. 快速上手

```
① 上传 ikev2.sh 到目标机的 /root/
② bash ikev2.sh selftest     # 先自检，确认发行版识别正确
③ sed -i 's/\r$//' ikev2.sh  # Windows 传的必须修换行符
④ bash ikev2.sh install      # 一路回车
⑤ 放通 UDP 500 与 4500 到本机
⑥ 按脚本打印的参数配置手机
```

## 1. 支持的系统

脚本读取 `/etc/os-release` 自动识别，覆盖以下五类：

| 类别 | 包含的发行版 | 包管理器 | 配置目录 | 服务管理 | 防火墙 |
|---|---|---|---|---|---|
| `debian` | Debian、Ubuntu、Linux Mint、Proxmox、树莓派 OS | apt | `/etc/swanctl` | systemd | iptables |
| `rhel` | RHEL、CentOS Stream、Rocky、AlmaLinux、Fedora、Oracle Linux | dnf | `/etc/strongswan/swanctl` | systemd | firewalld + iptables |
| `arch` | Arch Linux、Manjaro、EndeavourOS | pacman | `/etc/swanctl` | systemd | iptables |
| `opensuse` | openSUSE Leap、openSUSE Tumbleweed、SLE | zypper | `/etc/swanctl` | systemd | iptables |
| `alpine` | Alpine Linux | apk | `/etc/swanctl` | OpenRC | iptables |

几点差异说明：

- **RHEL 系的配置目录不同**，是 `/etc/strongswan/swanctl/`，其余四类都是 `/etc/swanctl/`。这是编译期决定的，脚本会按发行版自动选择。
- **RHEL 系需要 EPEL 仓库**。strongSwan 不在 RHEL 官方源中，脚本会尝试自动引导，引导失败时会给出手动命令。
- **Alpine 需要 community 仓库**。脚本会检查并在缺失时追加到 `/etc/apk/repositories`。
- **Alpine 使用 OpenRC**，服务管理命令是 `rc-service` 与 `rc-update`，脚本已适配。

容器环境（Docker、LXC、containerd）会被检测并拒绝，IPsec 依赖内核 XFRM 模块，容器内无法正常工作。

不在上表中的发行版（如 Gentoo、Slackware、NixOS）会被明确拒绝并提示。此时可在脚本头部手动设置 `DISTRO=debian` 强制走 apt 分支，前提是系统里有可用的 apt 与 strongSwan。

### 1.1 先自检

在目标机上执行：

```bash
bash ikev2.sh selftest
```

只读检查，不修改任何内容，输出七个板块：运行环境、发行版识别、内核 IPsec 能力、依赖工具、软件源、端口占用、已有配置。

**这一步不能省**。发行版识别错了，后面装包、写配置都会失败，而报错信息往往不直观。先看自检输出确认识别结果正确，再执行 install。

`selftest` 本身不需要 root，可以普通用户执行。但第七板块会读取安装状态文件，该文件权限为 600，普通用户读不到时会提示改用 `sudo bash ikev2.sh selftest`。

## 2. 前置条件

| 项 | 要求 | 备注 |
|---|---|---|
| 操作系统 | 见 [§1 支持的系统](#1-支持的系统) | |
| 权限 | root | 脚本开头会检查，非 root 直接退出 |
| 网络 | 能出公网，UDP 500 与 4500 需从外部可达 | NAT 后需端口转发，见 [§8.1](#81-端口必须放通) |
| 软件源 | 可用。RHEL 系需能访问 dl.fedoraproject.org | 内网离线环境需自备源 |
| 客户端 | Android 11 及以上 | iOS / Windows / macOS / Linux 亦可连接 |
| 磁盘 | 约 50 MB | strongSwan 与 OpenSSL 占用 |

IPv6 隧道为可选项。脚本会探测本机是否具备 IPv6 出网能力，不具备时自动关闭该项。

## 3. 部署

### 3.1 上传到服务器

| 方式 | 操作 |
|---|---|
| Xftp / WinSCP | 把 `ikev2.sh` 拖到 `/root/` |
| scp | `scp ikev2.sh root@服务器IP:/root/` |
| 克隆本仓库 | `git clone <本仓库地址> && cd ikev2-vpn` |
| 没有传输工具 | 服务器上 `cat > /root/ikev2.sh`，粘贴后按 `Ctrl+D` |

### 3.2 执行

```bash
sudo -i                     # 必须 root
cd /root

# Windows 传过去的文件可能带 CRLF 换行，先修一次（否则报 $'\r': command not found）
sed -i 's/\r$//' ikev2.sh

bash ikev2.sh selftest       # 先自检，确认发行版识别正确
bash ikev2.sh install       # 交互式，一路回车；装完自动打印客户端填表参数
bash ikev2.sh status        # 体检
bash ikev2.sh client        # 随时重看填表参数
```

几个注意点：

- 不需要 `chmod +x`，直接 `bash ikev2.sh` 调用。传输过程中执行权限容易丢失，显式调用更稳妥。
- 提示信息显示为乱码时，执行 `export LANG=C.UTF-8`。这只是显示问题。
- 最小化系统若未安装 curl，脚本会自动补装（探测公网 IP 需要）。装不上也能继续，只是探测结果会退化为网卡地址，此时手动填写公网地址。
- 脚本是幂等的，改动配置后重跑 `install` 即可。防火墙规则采用先查后加，不会重复堆积；已有的 PSK 密钥默认沿用，手机上已填的旧密钥不会因此失效。

## 4. 交互式安装

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
      1) psk   共享密钥：客户端无需安装证书，配置项较少；多台设备共用一把密钥，无法按人吊销
      2) eap   账号密码：可按人增删，客户端可选择导入 CA 证书以校验服务器身份
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
| 公网 IP / 域名 | 依次用 ip.3322.net、myip.ipip.net、myip.aliyun.com 探测，国内服务优先，境外仅作兜底。若探测到 192.168.x、10.x、172.16-31.x、100.64-127.x 这类内网地址，会提示本机位于 NAT 后，此时需要手动填写路由器 WAN 口公网 IP 或 DDNS 域名 |
| IPv6 隧道 | 本机没有 IPv6 默认路由时默认值自动为 no，此时选 yes 无效 |
| 地址池 | 与现有路由网段重叠时会告警并要求更换 |
| 接入模式 | psk 为共享密钥，eap 为账号密码。同一地址只能生效一种，原因见 [§8.3](#83-psk-与-eap-只能二选一) |
| PSK 标识符 | 可自定义，默认 android。客户端 PSK 模式必须原样填写，填错直接认证失败 |
| PSK 密钥 | 默认随机生成 32 字节十六进制。也可自行指定（选 y），建议不少于 24 位 |
| EAP 密码 | 隐藏输入并校验两次，不允许空格、冒号、引号与反斜杠 |
| 菜单项 | 输入序号选择推荐项，也可直接填写自定义值。DNS 与接入模式均为菜单形式 |

安装结束后会自动打印客户端填表参数，包含密钥、标识符、EAP 账号与 CA 证书路径。随时可用 `bash ikev2.sh client` 重新查看。

无人值守或脚本化部署：

```bash
bash ikev2.sh install --auto              # 全程使用默认值，不提问
INSTALL_AUTO=yes bash ikev2.sh install   # 等价写法
```

`--auto` 适用于 cloud-init 与批量部署场景。此时若脚本头部变量区已填值则使用该值，否则使用探测值。手动修改脚本头部变量区始终有效，这些值会成为交互提问时的默认值。

## 5. 客户端配置

### 5.1 Android

设置 → 网络与互联网 → VPN → 右上角 `+`

方式一：PSK，多台设备共用一把密钥

| 字段 | 值 |
|---|---|
| 类型 | IKEv2/IPsec PSK |
| 服务器地址 | `vpn.example.com` |
| IPsec 标识符 | 安装时设定的值，默认 `android`，需与服务端完全一致 |
| IPsec 预共享密钥 | `bash ikev2.sh client` 输出的值 |

方式二：EAP-MSCHAPv2，每个账号独立，可单独吊销

| 字段 | 值 |
|---|---|
| 类型 | IKEv2/IPsec MSCHAPv2 |
| 服务器地址 | `vpn.example.com` |
| IPsec 标识符 | 客户端 ID，如 `alice` |
| 用户名 / 密码 | 由 `useradd` 创建的账号 |
| IPsec CA 证书 | 可选，见 5.2 |

> **关于"IPsec 标识符"**：这是**客户端自己的身份（IDi）**，不是服务端身份。安卓的原生界面把它放在这个标签下，容易误解。服务端身份由安卓强制取"服务器地址"作为 IDr 并校验，所以这一栏填错会导致认证失败。

### 5.2 导入 CA 证书

服务端使用自签 CA。安装完成后证书位于 `/root/ikev2-ca.crt`，取出后传到设备：

```bash
# 传到当前目录的 ca.crt，便于后续拷贝
cp /root/ikev2-ca.crt ~/ca.crt
```

- Android：把 `ca.crt` 传到手机，设置 → 安全 → 加密与凭据 → 安装证书 → CA 证书，选中该文件
- iOS：用 AirDrop 或邮件发送到本机，设置 → 通用 → VPN 与设备管理，安装描述文件，之后在 VPN 设置中选择该配置

导入后客户端可以验证服务器身份，避免被冒充。不导入也能建立连接，只是不做校验。PSK 模式下建议导入。

该文件权限为 644 但位于 `/root/` 下，只有 root 能读取，因此需要用 `sudo cp` 导出。

### 5.3 其他平台

服务端是标准 strongSwan 配置，不限于安卓：

| 平台 | 客户端 | 备注 |
|---|---|---|
| iOS / iPadOS | 系统 VPN 或 strongSwan 官方 App | 系统对证书有效期有 825 天上限，脚本已适配 |
| Windows 10/11 | 设置 → 网络和 Internet → VPN → 添加 | 选择 IKEv2，可用用户名密码 |
| macOS | 系统 VPN 或 strongSwan 官方 App | |
| Linux | strongSwan 官方 App 或 NetworkManager | |
| 路由器 / 软路由 | 视设备而定 | 部分设备不支持 EAP，或不支持自定义 PSK 的 IDi |

各平台在"服务端标识 / Remote ID"一栏都应填写服务器地址，原因见 [§8.3](#83-psk-与-eap-只能二选一)。

## 6. 运维命令

```bash
bash ikev2.sh selftest                 # 环境自检：只读，不修改系统
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
# systemd 系（debian / rhel / arch / opensuse）
journalctl -u strongswan -f

# Alpine（OpenRC）
rc-service strongswan --nodaemon
```

在线客户端与 SA 状态：

```bash
swanctl --list-conns       # 已加载的连接
swanctl --list-sas         # 当前活跃的 SA
ip pool show               # 地址池分配情况
```

## 7. 排障

### 7.1 一键诊断

```bash
bash ikev2.sh diag
```

该命令会依次完成体检、打印身份一致性核对、抓取 25 秒数据包并过滤错误日志。

命令提示后，用客户端发起一次连接，然后对照抓包结果判断：

| 抓包结果 | 含义 | 处理方向 |
|---|---|---|
| 没有任何输出 | 数据包未到达服务器 | 检查端口转发与安全组是否放行 UDP 500 与 4500 |
| 有数据包，仅停留在 UDP 500 阶段 | 停留在 NAT-T 切换 | 检查 UDP 4500 转发 |
| 有数据包但认证失败 | 身份或密钥不匹配 | 参见下方排障表 |

### 7.2 排障表

| 现象 / 日志关键字 | 原因 | 处理 |
|---|---|---|
| 点连接立刻失败，服务端日志**完全没有包** | 端口没通，或被本机其他 VPN 服务占用 | 先用 `ss -lunp` 看 500/4500 占用者；若为 SoftEther 等，见 [§8.2 与已有 VPN 服务共存](#82-与已有-vpn-服务共存) |
| `no proposal chosen` | 算法或 IKE 版本不匹配 | 确认选的是 **IKEv2** 开头的类型，不是 L2TP / IPsec Xauth |
| `AUTHENTICATION_FAILED`、`no shared key found` | PSK 密钥不对 | 用 `client` 核对，注意别多粘空格 |
| `constraint check failed: identity 'xxx' required` | 客户端 IDi 与服务端要求的不一致 | PSK 模式标识符需原样填写安装时设定的值，默认 `android` |
| `looking for peer configs matching ...` 中 IDr 与 local id 不符 | 服务端身份 ≠ 客户端填的服务器地址 | 重跑 `install`，或用 `mode` 切到当前模式 |
| `no matching connection` / `no peer config found` | 当前模式的连接没加载 | `swanctl --list-conns` 看有没有 `rw-psk` / `rw-eap`，没有就重跑 `install` |
| `EAP failure`、`MSCHAPv2` 失败 | 账号密码错 | `users` 核对，重新 `useradd` 覆盖 |
| 连上后能 ping 通 IP 但**网页打不开** | MTU / MSS 黑洞 | 检查 mangle 表 `TCPMSS --set-mss 1360` 规则是否生效 |
| 连上后 IPv6 网站不通 | 服务端无 v6 出网 | `ip -6 route show default`，无则属预期（脚本已自动关闭 v6 隧道） |
| 第二台设备连上后第一台掉线 | `unique` 设置问题 | 脚本已设 `unique = never`，若手改过配置请改回 |
| 证书校验失败 | 服务器地址变了（动态 IP） | 换 DDNS 域名，或删掉 `server.crt` 后重跑 `install` 重签 |

### 7.3 手工抓包

```bash
tcpdump -ni any 'udp port 500 or udp port 4500 or proto 50'
```

## 8. 实现说明

本节记录脚本中若干看起来不合常规的处理及其原因。

### 8.1 端口必须放通

| 端口 | 用途 | 要求 |
|---|---|---|
| UDP 500 | IKE | 必须 |
| UDP 4500 | NAT-T（封装后的 ESP） | 必须 |
| IP 协议 50（ESP） | 非 NAT 直连时的加密流量 | 建议 |

云主机需在安全组放行 UDP 500 与 4500。NAT 场景（家宽、内网部署）需在路由器将这两个端口转发到运行 strongSwan 那台机器的内网 IP。交互安装第 [1] 问需填写客户端能连到的公网 IP 或 DDNS 域名，脚本探测到的是出网 IP，在 NAT 场景下通常无法直连。

> 动态公网 IP 建议使用 DDNS 域名。服务端身份的 IDr 与客户端填写的服务器地址都基于该值，IP 变化后未同步会表现为身份不匹配或证书校验失败。

### 8.2 与已有 VPN 服务共存

UDP 500 与 4500 是 IKE 协议的固定端口，**同一 IP 上只能被一个进程监听**。如果目标机器上已运行其他 VPN 服务，是否冲突取决于对方是否启用了 IPsec 功能：

| 已有服务 | 占用端口 | 是否冲突 |
|---|---|---|
| SoftEther 仅 SSL-VPN（默认 443） | 443/tcp | 不冲突 |
| SoftEther + OpenVPN | 1194 | 不冲突 |
| SoftEther + L2TP/IPsec | 500、4500/udp | 冲突 |
| racoon / libreswan / 其他 IPsec | 500、4500/udp | 冲突 |
| OpenVPN / WireGuard / ocserv | 1194 / 51820 / 443 | 不冲突 |

SoftEther 的 IPsec 功能默认关闭，若未执行过 `IPsecEnable` 则不占用 500/4500。确认方法：

```bash
# 看端口被谁占用
ss -lunp | grep -E ':(500|4500)\b'

# 查 SoftEther 是否启用了 IPsec
/usr/local/vpnserver/vpncmd localhost:5555 /SERVER /PASSWORD:管理密码
# 进入后执行：IPsecGet
```

`install` 会在装包前自动检测，若发现非 strongSwan 进程占用这两个端口会中止并提示，不会留下装到一半的状态。`selftest` 的第 6 板块也会显示占用情况。

确认冲突后需二选一：

- 关闭对方的 IPsec 功能。SoftEther 在 vpncmd 中执行 `IPsecEnable /L2TP:no`，再重启 vpnserver
- 改用其他端口的 IPsec 服务，客户端配置也需同步修改端口

### 8.3 PSK 与 EAP 只能二选一

安卓原生客户端的身份处理是硬编码的（AOSP `VpnIkev2Utils.java`）：

```java
localId  = parseIkeIdentification(profile.getUserIdentity()); // 客户端填的"IPsec 标识符" → 客户端身份 IDi
remoteId = parseIkeIdentification(profile.getServerAddr());   // 服务端身份 IDr，强制 = 服务器地址
```

由此推出三条约束：

1. 服务端身份必须等于客户端填写的服务器地址，不能自造 `psk.xxx` 之类的名称，否则安卓直接拒绝。
2. 客户端填写的"IPsec 标识符"是它自己的身份，不是服务端的。
3. IDr 被安卓写死为服务器地址，服务端因此无法依据身份区分 PSK 客户端与 EAP 客户端，两个连接只会命中其中一个。

所以脚本不提供 both 选项：

| 模式 | 服务端身份 | 客户端 identifier | 适用场景 |
|---|---|---|---|
| `psk` | `VPN_HOST` | 自定义的 PSK 标识符，默认 android | 设备数量少，希望减少配置步骤 |
| `eap` | `VPN_HOST`（证书 CN/SAN） | 任意，习惯上填用户名 | 需要按人增删与单独吊销 |

模式可随时切换，无需重装：

```bash
bash ikev2.sh mode eap      # 切换到账号密码模式
bash ikev2.sh mode psk      # 切回共享密钥模式
```

切到 psk 时脚本会重新生成一把随机密钥。若此前已有客户端用旧密钥连接，切换后需要重新填写。切到 eap 不影响已有 EAP 账号。

### 8.4 PSK 模式下有两条连接

脚本在 PSK 模式下会生成两条连接：

| 连接 | remote id | 作用 |
|---|---|---|
| `rw-psk` | 等于自定义的标识符 | 常规路径，日志可读性较好 |
| `rw-psk-any` | `%any` | 兜底。部分安卓 ROM 与运营商定制版本会发送空 IDi 或非预期身份，严格匹配会直接报 `no matching connection`，握手无法建立 |

日志中出现 `switching to connection 'rw-psk-any'` 属正常现象。两条连接使用同一把密钥与同一组地址池，安全性一致。

### 8.5 IPv6 双栈为自动开关

脚本会检测本机是否存在 IPv6 默认路由。存在时下发 IPv6 虚拟地址与 IPv6 DNS，`local_ts` 包含 `::/0`，IPv6 流量同样经过隧道并做 MASQUERADE。不存在时自动关闭 IPv6 隧道，避免客户端的 IPv6 流量被送入黑洞。

前提是运行 strongSwan 的机器本身拥有全局 IPv6 且能出网。路由器侧的 IPv6 防火墙同样需要放行 UDP 500 与 4500。

### 8.6 为什么装了两个 mangle 规则

| 规则 | 作用 |
|---|---|
| `FORWARD -s <客户端池> -j TCPMSS --set-mss 1360` | 处理最常见的一类故障：缺少该规则时客户端可以完成握手、可以 ping 通，但网页打不开，原因是 TCP 包在隧道内被分片丢弃 |
| `FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` | 通用兜底，处理其他路径的 PMTU 发现 |

MSS clamp 限定了来源地址，不会影响服务器上其他转发流量。

## 9. 安全

### 9.1 密钥与凭据位置

下表路径以 debian / arch / opensuse / alpine 为例。RHEL 系的前四项位于 `/etc/strongswan/swanctl/` 下，其余不变。实际路径以 `bash ikev2.sh selftest` 输出的配置目录为准。

| 内容 | 路径 | 权限 |
|---|---|---|
| PSK 共享密钥 | `/etc/swanctl/conf.d/ikev2-psk.conf` | 600 |
| 服务端证书与私钥 | `/etc/swanctl/{x509,private}/` | 600 |
| 自签 CA 证书，需传给客户端 | `/root/ikev2-ca.crt` | 644 |
| 自签 CA 私钥 | `/etc/swanctl/private/ca.key` | 600，不应外传 |
| EAP 用户表，明文 | `/etc/ikev2-vpn/users.list` | 600 |
| 安装状态 | `/etc/ikev2-vpn/env` | 600 |

EAP 用户密码以明文存储，这是 strongSwan 的 `eap-mschapv2` 机制决定的，因此该文件权限必须为 600。

### 9.2 三个需要注意的限制

1. PSK 模式下没有服务器身份验证。客户端先发送认证载荷，之后才验证服务端，掌握密钥的一方可以冒充服务器，弱密钥还可能被离线爆破。缓解方式是使用脚本生成的 32 字节随机密钥，不要替换为便于记忆的字符串，并导入 CA 证书。
2. PSK 模式无法按人吊销。多台设备共用一把密钥，需要让某台设备失效只能执行 `rotate-psk` 更换全部密钥。需要按人管理时使用 EAP 模式配合 `userdel`。
3. 自签 CA 私钥泄露后，服务端可被完全冒充。`/etc/swanctl/private/ca.key` 不应外传，也不应提交到版本库。

### 9.3 证书有效期

服务端证书有效期为 825 天，iOS 会拒绝有效期更长的证书。到期前重新签发，路径中的配置目录请按实际发行版调整：

```bash
# debian / arch / opensuse / alpine
rm /etc/swanctl/x509/server.crt

# rhel 系
rm /etc/strongswan/swanctl/x509/server.crt

bash ikev2.sh install
```

### 9.4 报告安全问题

请勿提交公开 Issue，见 [SECURITY.md](SECURITY.md)。

## 10. 已知限制

- 仅支持 [§1 列出的五类发行版](#1-支持的系统)。Gentoo、Slackware、NixOS 等会被拒绝，可用脚本头部的 `DISTRO=` 强制指定，但需自行确认包名与服务名一致。
- RHEL 系安装 strongSwan 必须有 EPEL 仓库，且需要能访问 dl.fedoraproject.org。离线内网环境需自备源。
- 容器环境（Docker、LXC、containerd）会被拒绝。IPsec 依赖内核 XFRM 模块，容器内无法工作。
- PSK 与 EAP 不能同时生效，原因是安卓将服务端身份固定为服务器地址，服务端无法区分认证方式。可通过 `mode` 切换。
- PSK 模式下一把密钥由多台设备共用。需要按设备或按人管理时使用 EAP 模式。
- IPv6 隧道依赖服务器自身的 IPv6 出网能力，脚本只做探测与开关，不负责申请 IPv6 地址。
- 防火墙规则持久化在各发行版上的机制不同，Arch 与 openSUSE 未做自动持久化，重启后需自行处理。
- `uninstall` 不卸载 strongSwan 软件包，也不回滚防火墙规则，以免删除用户已有的规则，需要时手动清理。
- 脚本不备份用户数据，重跑 `install` 会覆盖配置文件。

## 11. License

[MIT](LICENSE) © ikev2-vpn contributors

## 致谢

- [strongSwan](https://www.strongswan.org/)，实际的 IKE 与 IPsec 实现
- 项目中遇到的多数问题已整理在 [§7 排障](#7-排障) 与 [§8 实现说明](#8-实现说明)，欢迎补充 Issue
