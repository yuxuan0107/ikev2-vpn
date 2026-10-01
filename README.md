# IKEv2/IPsec VPN 服务端（Debian，单脚本部署）

一个 bash 脚本搞定：安卓原生客户端可直接连的 IKEv2 VPN，同时提供 **PSK** 和 **EAP-MSCHAPv2** 两种接入方式，支持 IPv4/IPv6 双栈全流量隧道。

- 服务端：strongSwan（swanctl），Debian 官方源
- 客户端：Android 11+ 系统自带 VPN，无需装 App
- 产物：`ikev2.sh`（单文件，幂等，可反复执行）

## 一、上传与首次执行

### 上传到服务器

| 方式 | 操作 |
|---|---|
| Xftp / WinSCP（推荐） | 把 `ikev2.sh` 直接拖到 `/root/` 目录 |
| scp | `scp ikev2.sh root@服务器IP:/root/` |
| 没有传输工具 | 服务器上执行 `cat > /root/ikev2.sh`，粘贴内容后按 `Ctrl+D` |

### 执行

```bash
sudo -i                     # 必须 root，脚本开头会检查
cd /root

# Windows 传过去的文件可能带 CRLF 换行，先修一次（否则会报 $'\r': command not found）
sed -i 's/\r$//' ikev2.sh

bash ikev2.sh install       # 交互式，一路回车即可，装完自动打印手机填表参数
bash ikev2.sh status        # 体检
bash ikev2.sh client        # 随时重看手机填表参数
```

要点：

- **不用 `chmod +x`**，直接 `bash ikev2.sh` 跑最稳——传输过程可能丢掉执行权限。
- 脚本含中文提示，终端若显示乱码，执行 `export LANG=C.UTF-8` 即可，不影响功能。
- 最小化系统没装 curl 时，脚本会自动补装（用于探测公网 IP），装不上也能跑，只是探测会退化成网卡内网地址，手动填公网地址即可。
| 脚本幂等 | 改主意了随时改配置重跑 `install`，防火墙规则"先查后加"不会堆积；**已有 PSK 密钥时默认沿用**，不会让手机上填的旧密钥失效 |

## 二、交互式安装

直接 `bash ikev2.sh install` 会逐项询问，**每个问题都有探测出来的默认值，直接回车就采用**：

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
```

> 选 `eap` 时会接着问用户名和两次密码；选 `psk` 时则问标识符和是否自定密钥。编号会跟着走，不用记。
 ─────────────────────────────────────────────────
  确认开始安装? [Y/n]:
```

要点：

| 项 | 说明 |
|---|---|
| 公网 IP / 域名 | 依次用 **ip.3322.net → myip.ipip.net → myip.aliyun.com** 探测（国内服务优先，境外仅兜底）。若探测到的是 `192.168.x / 10.x / 172.16-31.x / 100.64-127.x` 这类内网地址，会直接提示"本机在 NAT 后"，此时**必须手动填路由器 WAN 口公网 IP 或 DDNS 域名** |
| IPv6 隧道 | 本机没有 IPv6 默认路由时默认值自动变成 `no`，选了 yes 也白搭 |
| 地址池 | 与现有路由网段重叠时会告警并要求换一个 |
| 接入模式 | `psk`=共享密钥（推荐先跑通），`eap`=账号密码。**同一地址只能生效一种**，原因见下一节 |
| PSK 标识符 | 自定义，默认 `android`。手机 PSK 模式必须原样填写，填错直接认证失败 |
| PSK 密钥 | 默认随机生成 32 字节十六进制；也可以自己指定（选 `y`），建议 24 位以上 |
| EAP 密码 | 隐藏输入、输两次校验，不允许空格/冒号/引号/反斜杠 |
| 菜单项 | 输**序号**选推荐项，也可以直接填自己的值（DNS、模式都是菜单） |

**安装结束后自动打印安卓填表参数**（PSK 密钥、标识符、EAP 账号、CA 证书路径一屏给全），不用再单独跑命令；随时可以 `bash ikev2.sh client` 重看。

**无人值守 / 脚本化部署**：

```bash
bash ikev2.sh install --auto          # 全程用默认值，不提问
INSTALL_AUTO=yes bash ikev2.sh install   # 等价写法
```

`--auto` 适合放进 cloud-init 或批量部署；此时若脚本头部变量区已填值，就用那些值，否则用探测值。手动改脚本头部的变量区仍然有效——**那些值会成为交互时的默认值**。

## 三、安装前必读

### 1. 端口必须放通（最高频故障点）

| 端口 | 用途 | 必须 |
|---|---|---|
| UDP 500 | IKE | ✅ |
| UDP 4500 | NAT-T（封装后的 ESP） | ✅ |
| IP 协议 50（ESP） | 非 NAT 直连时的加密流量 | 建议 |

- **云主机**：去安全组放行 UDP 500、4500。
- **NAT 后（你的场景）**：在路由器上把 **UDP 500 和 UDP 4500 端口转发到 Debian 机器的内网 IP**。交互安装第一步会问公网地址，**这里要填手机能连到的公网 IP 或 DDNS 域名**（脚本探测到的是出网 IP，NAT 场景下通常不能直连）。

> 动态公网 IP 请一定用 DDNS 域名：证书 CN/SAN 和手机填的服务器地址都基于这个值，IP 变了不改就会出现证书校验失败。

### 2. IPv6 双栈

脚本会检测本机有没有 IPv6 默认路由：
- **有** → 自动下发 IPv6 虚拟地址 + IPv6 DNS，`local_ts` 含 `::/0`，v6 流量同样走隧道并做 MASQUERADE。
- **没有** → 自动关闭 IPv6 隧道，避免把客户端的 v6 流量送进黑洞。

前提：Debian 机器本身要有全局 IPv6 地址且能出网。路由器侧 v6 防火墙同样要放行 UDP 500/4500。

### 3. 为什么 PSK 和 EAP 只能二选一（重要）

安卓原生客户端的身份处理是硬编码的（AOSP `VpnIkev2Utils.java`）：

```java
localId  = parseIkeIdentification(profile.getUserIdentity()); // 手机填的"IPsec 标识符"→ 客户端身份 IDi
remoteId = parseIkeIdentification(profile.getServerAddr());   // 服务端身份 IDr 强制 = 服务器地址
```

由此推出三条硬约束：

1. **服务端身份必须等于手机填的服务器地址**——不能自造一个 `psk.xxx` 之类的名字，否则安卓直接拒绝。
2. **手机填的"IPsec 标识符"是客户端自己的身份**，不是服务端的。
3. 既然 IDr 被安卓写死成服务器地址，**服务端就没法靠身份区分"这是 PSK 客户端还是 EAP 客户端"**，两个连接方式只会命中同一个，另一个必失败。

所以脚本的交互里**不提供 both 选项**，只能选一种：

| 模式 | 服务端身份 | 手机 identifier | 适用场景 |
|---|---|---|---|
| `psk` | `VPN_HOST` | 你设定的 PSK 标识符（默认 `android`） | 自己用、设备少、图省事 |
| `eap` | `VPN_HOST`（证书 CN/SAN） | 随便填，习惯上填用户名 | 需要按人增删、单独吊销 |

想换模式随时切，不用重装：

```bash
bash ikev2.sh mode eap      # 切到账号密码模式
bash ikev2.sh mode psk      # 切回共享密钥模式（会重新生成密钥）
```

### 3.1 PSK 模式下有两条连接（日志里会看到）

脚本会为 PSK 模式生成**两条**连接：

| 连接 | remote id | 作用 |
|---|---|---|
| `rw-psk` | 等于你设定的标识符 | 正常走这条，日志可读性好 |
| `rw-psk-any` | `%any` | 兜底。部分安卓 ROM / 运营商定制版会发空 IDi 或非预期身份，严格匹配会直接 `no matching connection`，连握手都进不去 |

看到日志里 `switching to connection 'rw-psk-any'` **是正常的**，不是错误。两条连接用同一把密钥、同一组地址池，安全性不变。

## 四、手机配置

设置 → 网络与互联网 → VPN → 右上角 `+`

**方式一：PSK（简单，一把密钥多人共用）**

| 字段 | 值 |
|---|---|
| 类型 | IKEv2/IPsec PSK |
| 服务器地址 | `vpn.你的域名.com` |
| IPsec 标识符 | 你安装时设定的那个，默认 `android`（**必须完全一致**） |
| IPsec 预共享密钥 | `bash ikev2.sh client` 打印的那串 |

**方式二：EAP-MSCHAPv2（每人独立账号，可单独吊销）**

| 字段 | 值 |
|---|---|
| 类型 | IKEv2/IPsec MSCHAPv2 |
| 服务器地址 | `vpn.你的域名.com` |
| IPsec 标识符 | 用户名，如 `alice` |
| 用户名 / 密码 | `useradd` 添加的那组 |
| IPsec CA 证书 | 可选，见下 |

关于 CA 证书：把服务端的 `/root/ikev2-ca.crt` 拷到手机，设置 → 安全 → 加密与凭据 → 安装证书 → CA 证书，然后在 VPN 里选中它。**导入后客户端能验证服务器身份，防止被冒充；不导入也能连，只是不校验**。

## 五、运维命令

```bash
bash ikev2.sh status                  # 体检：服务/连接/在线客户端/端口/转发/NAT/日志
bash ikev2.sh client                  # 重新打印手机填表参数
bash ikev2.sh users                   # 列出 EAP 用户
bash ikev2.sh useradd alice '密码'     # 加用户（同名覆盖）
bash ikev2.sh userdel alice           # 删用户
bash ikev2.sh rotate-psk              # 换 PSK，旧密钥立即失效
bash ikev2.sh mode psk|eap            # 切换接入模式
bash ikev2.sh diag                    # 连不上时的诊断（体检 + 抓包 25 秒）
bash ikev2.sh install                 # 改完变量区重跑，覆盖配置（证书不会重签）
bash ikev2.sh uninstall               # 清除配置
```

实时看连接日志：

```bash
journalctl -u strongswan -f
```

## 六、排障表

| 现象 / 日志关键字 | 原因 | 处理 |
|---|---|---|
| 手机点连接立刻失败，服务端日志**完全没有包** | 端口没通 | 查路由器端口转发 / 云安全组 UDP 500+4500 |
| `no proposal chosen` | 算法或 IKE 版本不匹配 | 确认手机选的是 **IKEv2** 开头的类型，不是 L2TP / IPsec Xauth |
| `AUTHENTICATION_FAILED`、`no shared key found` | PSK 密钥不对 | 用 `client` 核对密钥，注意别多粘空格 |
| `constraint check failed: identity 'xxx' required` | 手机 identifier 与服务端要求的不一致 | PSK 模式标识符必须原样填你设定的那个（默认 `android`），见 `client` 输出 |
| 日志里 `looking for peer configs matching ...[xxx]` 中 IDr 与 local id 不符 | 服务端身份 ≠ 手机填的服务器地址 | 重跑 `install`，或用 `mode` 切到当前模式再试 |
| `no matching connection` / `no peer config found` | 当前模式的连接没加载 | `swanctl --list-conns` 看有没有 `rw-psk`/`rw-eap`，没有就重跑 `install` |
| `EAP failure`、`MSCHAPv2` 失败 | 账号密码错 | `users` 核对，重新 `useradd` 覆盖 |
| 连上后能 ping 通 IP 但网页打不开 | MTU/MSS 黑洞 | 检查 mangle 表 `TCPMSS --set-mss 1360` 规则是否生效 |
| 连上后 IPv6 网站不通 | 服务端无 v6 出网 | `ip -6 route show default`，无则属预期（脚本已自动关闭 v6 隧道） |
| 第二台设备连上后第一台掉线 | `unique` 设置问题 | 脚本已设 `unique = never`，若手改过配置请改回 |

**连不上请直接跑 `bash ikev2.sh diag`**，它会一次性做完体检、打印身份一致性核对、抓 25 秒包并过滤出错误日志。手动抓包：

```bash
tcpdump -ni any 'udp port 500 or udp port 4500 or proto 50'
```

## 七、安全说明（请务必看）

1. **PSK 模式没有服务器身份验证**。客户端先发认证载荷、后验证服务端，任何拿到密钥的人都能冒充你的服务器，弱密钥可被离线爆破。缓解：密钥由 `openssl rand -hex 32` 生成（脚本已如此），**不要改成你能记住的密码**。
2. **PSK 无法按人吊销**。要单独踢人请用 EAP 模式（`userdel`），PSK 只能 `rotate-psk` 全体换密钥。
3. 服务端自签 CA 私钥在 `/etc/swanctl/private/ca.key`，权限 600，别外传。
4. 服务端证书有效期 825 天（iOS 对更长有效期会拒绝），到期前重跑：删掉 `server.crt` 后再 `install`。

## 八、已知限制

- 只支持 Debian/Ubuntu 系；其他发行版需自行替换包名和服务名。
- **PSK 与 EAP 不能同时生效**（安卓把服务端身份写死为服务器地址，服务端无法区分认证方式）。选一种，用 `mode` 切换。
- PSK 模式下密钥是"一把多设备共用"。想按设备/按人管理，请用 EAP 模式（`useradd`/`userdel`）。
- `uninstall` 不卸载 strongSwan 软件包，也不回滚防火墙规则（避免误删你自己的规则），需手动清理。
