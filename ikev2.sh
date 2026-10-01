#!/usr/bin/env bash
# IKEv2/IPsec VPN 服务端一键部署脚本 (Debian)
# 双模: IKEv2/IPsec PSK + IKEv2 EAP-MSCHAPv2，支持 IPv4/IPv6 双栈全流量隧道
# 用法: bash ikev2.sh install | client | status | useradd | userdel | users | rotate-psk | uninstall
set -euo pipefail

# ==================== 变量区（按需修改，留空则自动探测） ====================
VPN_HOST=""                 # 手机连接用的公网 IP 或域名
VPN_IF=""                   # 出口网卡
POOL4="10.29.7.0/24"        # 客户端 IPv4 虚拟地址池
POOL6="fd00:29:7::/64"      # 客户端 IPv6 虚拟地址池（服务端无 v6 出网时自动关闭）
DNS4="223.5.5.5,119.29.29.29"
DNS6="2400:3200::1,2402:4e00::"
PSK_IDENT="android"         # 手机 PSK 模式要填的"IPsec 标识符"（客户端身份，可自定义）
PSK_VALUE=""                # 留空=自动生成 32 字节随机密钥；也可在这里直接写死
MODE="psk"                  # psk | eap（同一地址无法两种同时生效，见 README 说明）
# ===========================================================================

# 公网 IP 探测服务：国内优先，逐个尝试，取第一个能用的
IP_PROBES=(
  "http://ip.3322.net"                 # 3322.org，纯文本返回 IP
  "https://myip.ipip.net"              # ipip.net，返回"当前 IP：x.x.x.x 来自于：..."
  "https://myip.aliyun.com"            # 阿里云，纯文本返回 IP
  "http://ip-api.com/line?fields=query" # 境外兜底
)

INSTALL_AUTO="${INSTALL_AUTO:-no}"   # yes 时全程用默认值，不提问（环境变量或 --auto 指定）
FIRST_USER=""                        # 交互模式下填写的首个 EAP 用户
FIRST_PASS=""

CONF_DIR="/etc/swanctl"
CONF_FILE="${CONF_DIR}/conf.d/ikev2-vpn.conf"
PSK_FILE="${CONF_DIR}/conf.d/ikev2-psk.conf"
EAP_FILE="${CONF_DIR}/conf.d/ikev2-eap.conf"
USER_LIST="/etc/ikev2-vpn/users.list"
STATE_FILE="/etc/ikev2-vpn/env"
LOG="[ikev2]"

die()  { echo "${LOG} 错误: $*" >&2; exit 1; }
info() { echo "${LOG} $*"; }
warn() { echo "${LOG} 警告: $*"; }
need_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行: sudo bash $0 $*"; }

# 探测公网 IP 依赖 curl，最小化安装的 Debian 可能没有，需在探测前补上
ensure_tools() {
  if ! command -v curl >/dev/null 2>&1; then
    info "安装 curl（用于探测公网 IP）..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    if ! apt-get install -y -qq curl >/dev/null 2>&1; then
      warn "curl 安装失败，公网 IP 探测会回退到本机网卡地址（NAT 场景不准，请手动填）"
    fi
  fi
}

# ---------------------------- 环境探测 ----------------------------
# 只取第一个 IPv4 字面量，兼容"纯 IP"和"当前 IP：x.x.x.x 来自于：..."两种返回
probe_public_ip() {
  local url body ip
  for url in "${IP_PROBES[@]}"; do
    body="$(curl -4 -fsS --max-time 4 "${url}" 2>/dev/null || true)"
    ip="$(printf '%s' "${body}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -n "${ip}" ]]; then printf '%s' "${ip}"; return 0; fi
  done
  return 1
}

is_private_ip() {
  awk -v ip="$1" 'BEGIN{
    split(ip,a,"."); n1=a[1]+0; n2=a[2]+0
    if (n1==10) exit 0
    if (n1==192 && n2==168) exit 0
    if (n1==172 && n2>=16 && n2<=31) exit 0
    if (n1==100 && n2>=64 && n2<=127) exit 0
    if (n1==127) exit 0
    exit 1
  }'
}

probe_env() {
  if [[ "${PROBE_DONE:-}" == "1" ]]; then return 0; fi
  PROBE_IF="$(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}')"
  PROBE_PRIVATE="no"
  PROBE_IP="$(probe_public_ip || true)"
  if [[ -z "${PROBE_IP}" && -n "${PROBE_IF}" ]]; then
    # 探测服务全挂，退回本机网卡地址（一般是内网地址）
    PROBE_IP="$(ip -4 addr show dev "${PROBE_IF}" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
    PROBE_PRIVATE="yes"
  fi
  if [[ -n "${PROBE_IP}" ]] && is_private_ip "${PROBE_IP}"; then
    PROBE_PRIVATE="yes"
  fi
  if [[ "${PROBE_PRIVATE}" == "yes" ]]; then
    PROBE_IP_NOTE="探测结果是内网地址 ${PROBE_IP}，本机在 NAT 后，这里要填路由器 WAN 口公网 IP 或 DDNS 域名"
  else
    PROBE_IP_NOTE="NAT 后填路由器 WAN 口公网 IP；动态 IP 强烈建议填 DDNS 域名，IP 变了证书会校验失败"
  fi
  PROBE_V6="no"
  if ip -6 route show default 2>/dev/null | grep -q default; then PROBE_V6="yes"; fi
  PROBE_DONE=1
}

detect_env() {
  grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null || die "只支持 Debian/Ubuntu 系"
  probe_env
  if [[ -z "${VPN_IF}" ]]; then VPN_IF="${PROBE_IF}"; fi
  [[ -n "${VPN_IF}" ]] || die "探测不到默认出口网卡，请手动设置 VPN_IF"
  if [[ -z "${VPN_HOST}" ]]; then
    VPN_HOST="${PROBE_IP}"
    [[ -n "${VPN_HOST}" ]] || die "取不到公网 IP，请在变量区手动设置 VPN_HOST"
    if [[ "${PROBE_PRIVATE}" == "yes" ]]; then
      warn "探测到的是内网地址 ${VPN_HOST}（本机在 NAT 后），手机要连的应是路由器 WAN 口地址或 DDNS 域名"
    fi
  fi
  if [[ -n "${POOL6}" && "${PROBE_V6}" != "yes" ]]; then
    warn "本机无 IPv6 默认路由，关闭 IPv6 隧道（否则客户端 v6 流量会被黑洞）"
    POOL6=""
  fi
  info "出口网卡=${VPN_IF}  连接地址=${VPN_HOST}  IPv6=$([[ -n ${POOL6} ]] && echo 开 || echo 关)"
}

# ---------------------------- 交互输入 ----------------------------
auto_mode() { [[ "${INSTALL_AUTO}" == "yes" || ! -t 0 ]]; }

STEP=0
step() { STEP=$((STEP + 1)); printf '  [%s] %s\n' "${STEP}" "$1"; }

ask() {
  local __var="$1" __prompt="$2" __def="$3" __hint="${4:-}" __val=""
  step "${__prompt}"
  if [[ -n "${__hint}" ]]; then printf '      建议: %s\n' "${__hint}"; fi
  if ! auto_mode; then
    printf '      回车采用 [%s]: ' "${__def}"
    read -r __val || true
  fi
  if [[ -z "${__val}" ]]; then __val="${__def}"; fi
  printf -v "${__var}" '%s' "${__val}"
}

ask_yn() {
  local __var="$1" __prompt="$2" __def="$3" __hint="${4:-}" __val=""
  step "${__prompt}"
  if [[ -n "${__hint}" ]]; then printf '      建议: %s\n' "${__hint}"; fi
  if ! auto_mode; then
    printf '      回车采用 [%s] (y/n): ' "${__def}"
    read -r __val || true
  fi
  if [[ -z "${__val}" ]]; then __val="${__def}"; fi
  case "${__val}" in
    y|Y|yes|YES) printf -v "${__var}" 'yes' ;;
    *)           printf -v "${__var}" 'no'  ;;
  esac
}

# 菜单选择: ask_choice <变量名> <标题> <默认值> "值|说明" ...
ask_choice() {
  local __var="$1" __prompt="$2" __def="$3"; shift 3
  local __opts=("$@") __o __v __d __i=1 __val=""
  step "${__prompt}"
  for __o in "${__opts[@]}"; do
    __v="${__o%%|*}"; __d="${__o#*|}"
    printf '      %s) %-42s %s\n' "${__i}" "${__v}" "${__d}"
    __i=$((__i + 1))
  done
  if ! auto_mode; then
    printf '      输入序号或直接填值，回车采用 [%s]: ' "${__def}"
    read -r __val || true
  fi
  if [[ -z "${__val}" ]]; then __val="${__def}"; fi
  if [[ "${__val}" =~ ^[0-9]+$ ]] && (( __val >= 1 && __val <= ${#__opts[@]} )); then
    __val="${__opts[$((__val - 1))]%%|*}"
  fi
  printf -v "${__var}" '%s' "${__val}"
}

ask_secret() {
  local __var="$1" __prompt="$2" __hint="${3:-}" __a="" __b=""
  step "${__prompt}"
  if [[ -n "${__hint}" ]]; then printf '      建议: %s\n' "${__hint}"; fi
  if ! auto_mode; then
    while true; do
      printf '      输入（屏幕不显示）: '; read -rs __a || true; echo
      if [[ -z "${__a}" ]]; then warn "密码不能为空"; continue; fi
      printf '      再输入一次        : '; read -rs __b || true; echo
      if [[ "${__a}" != "${__b}" ]]; then warn "两次不一致，重来"; continue; fi
      case "${__a}" in
        *:*|*'"'*|*"'"*|*'\'*|*" "*) warn "密码不能含空格、冒号、引号或反斜杠"; continue ;;
      esac
      break
    done
  fi
  printf -v "${__var}" '%s' "${__a}"
}

check_pool4() {
  local tries=0
  while (( tries < 2 )); do
    if ! ip route show 2>/dev/null | grep -qF "${POOL4}"; then return 0; fi
    warn "地址池 ${POOL4} 在 ip route 中已存在，与现网重叠会导致客户端上不了网"
    if auto_mode; then return 0; fi
    ask POOL4 "换一个 IPv4 地址池" "10.29.7.0/24"
    tries=$((tries + 1))
  done
}

interactive_setup() {
  echo
  echo " 交互式配置：每项都给出建议值，直接回车即采用建议值"
  echo " ─────────────────────────────────────────────────"
  local def_host="${VPN_HOST:-${PROBE_IP}}"
  local def_if="${VPN_IF:-${PROBE_IF}}"
  local v6_def="yes"
  if [[ "${PROBE_V6}" != "yes" ]]; then v6_def="no"; fi
  ask VPN_HOST "手机连接用的公网地址" "${def_host}" "${PROBE_IP_NOTE}"
  local tries=0
  while [[ -z "${VPN_HOST}" ]] && (( tries < 2 )); do
    warn "公网地址不能为空，否则手机不知道连哪里"
    ask VPN_HOST "手机连接用的公网地址" "${PROBE_IP}" "${PROBE_IP_NOTE}"
    tries=$((tries + 1))
  done
  ask VPN_IF "出口网卡" "${def_if}" \
    "发出互联网流量的网卡，探测值通常就是对的"
  ask POOL4 "客户端 IPv4 地址池" "${POOL4}" \
    "避开家里/机房已在用的网段（192.168.x、10.0.x 之类），冲突会导致客户端上不了网"
  check_pool4
  ask_choice DNS4 "推送给客户端的 IPv4 DNS" "${DNS4}" \
    "223.5.5.5,119.29.29.29|阿里+腾讯，国内站点解析快" \
    "1.1.1.1,8.8.8.8|Cloudflare+Google，境外站点友好" \
    "114.114.114.114,223.5.5.5|114DNS+阿里，北方联通/电信稳"
  ask_yn WANT_V6 "启用 IPv6 隧道" "${v6_def}" \
    "只有本机确实有 IPv6 出网能力才开，否则客户端 v6 流量会被黑洞"
  if [[ "${WANT_V6}" == "yes" ]]; then
    ask POOL6 "客户端 IPv6 地址池" "${POOL6}" \
      "用 fd00::/8 开头的私有段即可，不要和本机现网 v6 段重叠"
    ask_choice DNS6 "推送给客户端的 IPv6 DNS" "${DNS6}" \
      "2400:3200::1,2402:4e00::|阿里+腾讯 IPv6" \
      "2606:4700:4700::1111,2001:4860:4860::8888|Cloudflare+Google IPv6"
  else
    POOL6=""
  fi
  ask_choice MODE "接入模式" "${MODE}" \
    "psk|共享密钥：手机不用装证书，最省事（推荐先跑通）；多设备共用一把，无法按人吊销" \
    "eap|账号密码：可按人增删，手机可选装 CA 来校验服务器身份"
  case "${MODE}" in
    psk|eap) ;;
    *) warn "模式取值非法，回退 psk"; MODE="psk" ;;
  esac
  if [[ "${MODE}" == "psk" ]]; then
    ask PSK_IDENT "PSK 标识符（手机上的 IPsec 标识符）" "${PSK_IDENT}" \
      "手机 PSK 模式必须填得和这里完全一致，填错会认证失败；填设备名方便识别，如 android、mi13"
    ask_yn USE_OWN_PSK "自己指定 PSK 密钥" "no" \
      "选 y 可自己定；留 n 由脚本随机生成 32 字节十六进制，抗爆破更安全"
    if [[ "${USE_OWN_PSK}" == "yes" ]]; then
      ask PSK_VALUE "PSK 预共享密钥" "${PSK_VALUE}" "不要用单词/手机号这类好猜的，建议 24 位以上混合大小写数字"
      if [[ -z "${PSK_VALUE}" ]]; then warn "输入为空，仍由脚本自动生成"; fi
    fi
  fi
  if [[ "${MODE}" == "eap" ]]; then
    local adduser_def="yes"
    if auto_mode; then adduser_def="no"; fi   # --auto 下没法交互输密码，默认不建用户
    ask_yn ADD_USER "现在添加第一个 EAP 用户" "${adduser_def}" \
      "EAP 用户就是手机上的账号密码，之后可用 useradd/userdel 增删"
    if [[ "${ADD_USER}" == "yes" ]]; then
      ask FIRST_USER "EAP 用户名" "alice" \
        "字母数字即可，会和服务器地址一起显示在手机配置里"
      ask_secret FIRST_PASS "EAP 密码" "手机登录用的密码；改密就是 useradd 同名覆盖"
    fi
  fi
  echo " ─────────────────────────────────────────"
  echo "  连接地址    : ${VPN_HOST}"
  echo "  出口网卡    : ${VPN_IF}"
  echo "  IPv4 地址池 : ${POOL4}   DNS: ${DNS4}"
  echo "  IPv6 隧道   : $([[ -n ${POOL6} ]] && echo "开 ${POOL6}" || echo 关)"
  echo "  接入模式    : ${MODE}"
  echo " ─────────────────────────────────────────"
  local ans=""
  if ! auto_mode; then
    printf '  确认开始安装? [Y/n]: '
    read -r ans || true
    if [[ "${ans}" == "n" || "${ans}" == "N" ]]; then
      info "已取消，未做任何改动"
      exit 0
    fi
  fi
}

save_state() {
  mkdir -p /etc/ikev2-vpn
  cat >"${STATE_FILE}" <<EOF
VPN_HOST=${VPN_HOST}
VPN_IF=${VPN_IF}
POOL4=${POOL4}
POOL6=${POOL6}
DNS4=${DNS4}
DNS6=${DNS6}
PSK_IDENT=${PSK_IDENT}
MODE=${MODE}
EOF
  chmod 600 "${STATE_FILE}"
}

load_state() {
  [[ -r "${STATE_FILE}" ]] || die "尚未安装（缺 ${STATE_FILE}），先运行: bash $0 install"
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  # 兼容旧版本保存的状态文件（没有这些字段）
  if [[ -z "${PSK_IDENT:-}" ]]; then PSK_IDENT="android"; fi
  if [[ -z "${MODE:-}" ]]; then MODE="psk"; fi
}

install_packages() {
  info "安装 strongSwan ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq strongswan strongswan-swanctl strongswan-pki \
    libcharon-extra-plugins curl iproute2 >/dev/null
  apt-get install -y -qq iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
  systemctl disable --now strongswan-starter >/dev/null 2>&1 || true
  systemctl enable --now strongswan >/dev/null 2>&1 || true
  command -v swanctl >/dev/null || die "swanctl 未安装成功"
}

ensure_include() {
  local main="${CONF_DIR}/swanctl.conf"
  mkdir -p "${CONF_DIR}/conf.d"
  [[ -f "${main}" ]] || echo "# managed by ikev2.sh" >"${main}"
  grep -q 'include conf.d/\*.conf' "${main}" || {
    cp -n "${main}" "${main}.bak.$(date +%s)" 2>/dev/null || true
    printf '\ninclude conf.d/*.conf\n' >>"${main}"
  }
}

gen_pki() {
  mkdir -p "${CONF_DIR}"/{private,x509,x509ca}
  chmod 700 "${CONF_DIR}/private"
  if [[ -s "${CONF_DIR}/x509/server.crt" ]]; then
    info "服务端证书已存在，跳过（要重签请先删除 ${CONF_DIR}/x509/server.crt）"
    return
  fi
  info "生成自签 CA 与服务端证书 CN=${VPN_HOST} ..."
  pki --gen --type rsa --size 3072 --outform pem >"${CONF_DIR}/private/ca.key"
  pki --self --in "${CONF_DIR}/private/ca.key" --type rsa --ca \
      --dn "CN=IKEv2 VPN CA" --lifetime 3650 --outform pem >"${CONF_DIR}/x509ca/ca.crt"
  pki --gen --type rsa --size 3072 --outform pem >"${CONF_DIR}/private/server.key"
  pki --pub --in "${CONF_DIR}/private/server.key" --type rsa \
    | pki --issue --cacert "${CONF_DIR}/x509ca/ca.crt" --cakey "${CONF_DIR}/private/ca.key" \
        --dn "CN=${VPN_HOST}" --san "${VPN_HOST}" --flag serverAuth --flag ikeIntermediate \
        --lifetime 825 --outform pem >"${CONF_DIR}/x509/server.crt"
  chmod 600 "${CONF_DIR}/private/ca.key" "${CONF_DIR}/private/server.key"
  install -m 644 "${CONF_DIR}/x509ca/ca.crt" /root/ikev2-ca.crt
  info "CA 证书已导出到 /root/ikev2-ca.crt"
}

gen_psk() {
  local psk="${PSK_VALUE}"
  if [[ -z "${psk}" ]]; then
    psk="$(openssl rand -hex 32)"
  fi
  cat >"${PSK_FILE}" <<EOF
# 由 ikev2.sh 生成。改密钥: bash $0 rotate-psk
# 手机填的 IPsec 标识符必须与下面的 id 一致
secrets {
    ike-vpn {
        id = ${PSK_IDENT}
        secret = ${psk}
    }
}
EOF
  chmod 600 "${PSK_FILE}"
  echo "${psk}"
}

regen_eap() {
  # 从纯文本用户表生成 swanctl secrets，避免直接编辑配置块
  mkdir -p /etc/ikev2-vpn
  touch "${USER_LIST}"
  chmod 600 "${USER_LIST}"
  {
    echo "secrets {"
    while IFS=: read -r u p; do
      if [[ -z "${u:-}" || -z "${p:-}" ]]; then continue; fi
      echo "    eap-${u} {"
      echo "        id = ${u}"
      echo "        secret = \"${p}\""
      echo "    }"
    done <"${USER_LIST}"
    echo "}"
  } >"${EAP_FILE}"
  chmod 600 "${EAP_FILE}"
}

write_conf() {
  local local_ts="0.0.0.0/0" pools="rw-pool4" dns="${DNS4}"
  if [[ -n "${POOL6}" ]]; then
    local_ts="0.0.0.0/0, ::/0"; pools="rw-pool4, rw-pool6"; dns="${DNS4}, ${DNS6}"
  fi

  local psk_block="" eap_block="" pool6_block=""
  if [[ "${MODE}" == "both" ]]; then
    warn "MODE=both 已废弃（安卓把服务端身份写死为服务器地址，PSK 与 EAP 无法共存），自动改为 psk"
    MODE="psk"
  fi
  # 第一条: 标识符精确匹配（手机按提示填即可，日志可读性好）
  # 第二条: 兜底接受任意标识符（部分安卓 ROM/运营商定制会发空 IDi，
  #         严格匹配会直接 no matching connection，连握手都进不去）
  if [[ "${MODE}" == "psk" ]]; then
    psk_block="
    # IKEv2/IPsec PSK — 标识符精确匹配
    # 关键: 安卓强制以"服务器地址"作为服务端身份(IDr)并校验，local id 必须等于 VPN_HOST
    rw-psk {
        version = 2
        proposals = aes256-sha256-modp2048, aes128-sha256-modp2048, aes256gcm16-prfsha256-modp2048
        encap = yes
        pools = ${pools}
        local {
            auth = psk
            id = ${VPN_HOST}
        }
        remote {
            auth = psk
            id = ${PSK_IDENT}
        }
        send_certreq = no
        children {
            rw-psk-child {
                local_ts = ${local_ts}
                esp_proposals = aes256-sha256-modp2048, aes128-sha256-modp2048, aes256gcm16-modp2048
                dpd_action = clear
                rekey_time = 3600
            }
        }
        dpd_delay = 30
        unique = never
    }

    # 兜底: 接受任意标识符，日志里会看到 switching 到这一条属正常
    rw-psk-any {
        version = 2
        proposals = aes256-sha256-modp2048, aes128-sha256-modp2048, aes256gcm16-prfsha256-modp2048
        encap = yes
        pools = ${pools}
        local {
            auth = psk
            id = ${VPN_HOST}
        }
        remote {
            auth = psk
            id = %any
        }
        send_certreq = no
        children {
            rw-psk-any-child {
                local_ts = ${local_ts}
                esp_proposals = aes256-sha256-modp2048, aes128-sha256-modp2048, aes256gcm16-modp2048
                dpd_action = clear
                rekey_time = 3600
            }
        }
        dpd_delay = 30
        unique = never
    }"
  fi
  if [[ "${MODE}" == "eap" ]]; then
    eap_block="
    # IKEv2 EAP-MSCHAPv2（服务端用证书自证，客户端用账号密码）
    rw-eap {
        version = 2
        proposals = aes256-sha256-modp2048, aes128-sha256-modp2048, aes256gcm16-prfsha256-modp2048
        encap = yes
        pools = ${pools}
        local {
            auth = pubkey
            certs = server.crt
            id = ${VPN_HOST}
        }
        remote {
            auth = eap-mschapv2
            eap_id = %any
        }
        send_cert = always
        send_certreq = no
        children {
            rw-eap-child {
                local_ts = ${local_ts}
                esp_proposals = aes256-sha256-modp2048, aes128-sha256-modp2048, aes256gcm16-modp2048
                dpd_action = clear
                rekey_time = 3600
            }
        }
        dpd_delay = 30
        unique = never
    }"
  fi
  if [[ -n "${POOL6}" ]]; then
    pool6_block="
    rw-pool6 {
        addrs = ${POOL6}
        dns = ${DNS6}
    }"
  fi

  cat >"${CONF_FILE}" <<EOF
# 由 ikev2.sh 生成于 $(date '+%F %T')，手改会被下次 install 覆盖
connections {${psk_block}${eap_block}
}

pools {
    rw-pool4 {
        addrs = ${POOL4}
        dns = ${dns}
    }${pool6_block}
}
EOF
  chmod 600 "${CONF_FILE}"
}

apply_sysctl() {
  info "开启内核转发 ..."
  # 网卡名写错时 sysctl 会因路径不存在而整份文件加载失败，必须先确认网卡存在
  ip link show "${VPN_IF}" >/dev/null 2>&1 || die "网卡 ${VPN_IF} 不存在，请检查变量区 VPN_IF"
  cat >/etc/sysctl.d/99-ikev2-vpn.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.${VPN_IF}.rp_filter = 0
EOF
  sysctl --system >/dev/null 2>&1 || true
  if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]]; then
    warn "ip_forward 仍不是 1（可能被 /etc/sysctl.conf 里的其他条目覆盖），请手动检查"
  fi
}

# 先查后加，重复执行不会堆积规则
ipt() {
  local t="$1" c="$2"; shift 2
  iptables -t "$t" -C "$c" "$@" 2>/dev/null && return 0
  iptables -t "$t" -A "$c" "$@" 2>/dev/null || warn "规则添加失败(iptables -t $t -A $c $*)"
}
ip6t() {
  local t="$1" c="$2"; shift 2
  ip6tables -t "$t" -C "$c" "$@" 2>/dev/null && return 0
  ip6tables -t "$t" -A "$c" "$@" 2>/dev/null || warn "规则添加失败(ip6tables -t $t -A $c $*)"
}

apply_firewall() {
  info "配置防火墙 / NAT / MSS ..."
  ipt filter INPUT  -p udp --dport 500  -j ACCEPT
  ipt filter INPUT  -p udp --dport 4500 -j ACCEPT
  ipt filter INPUT  -p esp -j ACCEPT
  ipt filter FORWARD -s "${POOL4}" -m policy --pol ipsec --dir in  -j ACCEPT
  ipt filter FORWARD -d "${POOL4}" -m policy --pol ipsec --dir out -j ACCEPT
  ipt nat    POSTROUTING -s "${POOL4}" -o "${VPN_IF}" -j MASQUERADE
  # 不做 MSS clamp 的典型症状：能 ping 通但网页打不开
  ipt mangle FORWARD -s "${POOL4}" -o "${VPN_IF}" -p tcp --tcp-flags SYN,RST SYN \
      -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1360
  if [[ -n "${POOL6}" ]]; then
    ip6t filter INPUT  -p udp --dport 500  -j ACCEPT
    ip6t filter INPUT  -p udp --dport 4500 -j ACCEPT
    ip6t filter INPUT  -p esp -j ACCEPT
    ip6t filter FORWARD -s "${POOL6}" -m policy --pol ipsec --dir in  -j ACCEPT
    ip6t filter FORWARD -d "${POOL6}" -m policy --pol ipsec --dir out -j ACCEPT
    ip6t nat    POSTROUTING -s "${POOL6}" -o "${VPN_IF}" -j MASQUERADE
    ip6t mangle FORWARD -s "${POOL6}" -o "${VPN_IF}" -p tcp --tcp-flags SYN,RST SYN \
        -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1340
  fi
  netfilter-persistent save >/dev/null 2>&1 || true
}

reload() { swanctl --load-all --noprompt >/dev/null 2>&1 || swanctl --load-all; }

cmd_install() {
  need_root install
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --auto|-y) INSTALL_AUTO="yes" ;;
      *) die "未知参数 ${arg}（install 仅支持 --auto）" ;;
    esac
  done
  grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null || die "只支持 Debian/Ubuntu 系"
  ensure_tools
  probe_env
  if [[ "${INSTALL_AUTO}" != "yes" ]]; then interactive_setup; fi
  detect_env
  check_pool4
  install_packages
  ensure_include
  [[ "${MODE}" == "psk" ]] || gen_pki
  local psk="(当前模式未启用 PSK)"
  if [[ "${MODE}" == "eap" ]]; then
    rm -f "${PSK_FILE}"     # 切到 EAP 后别留着旧 PSK 密钥文件误导排查
  else
    # 已存在 PSK 时不重新生成：重跑 install 不该让手机上填的密钥失效
    if [[ -f "${PSK_FILE}" && -n "${PSK_VALUE}" ]]; then
      psk="$(awk -F'secret = ' '/secret = /{print $2; exit}' "${PSK_FILE}")"
      info "沿用已有的 PSK 密钥（重跑 install 不会让手机上的旧密钥失效）"
    else
      psk="$(gen_psk)"
    fi
  fi
  regen_eap
  write_conf
  apply_sysctl
  apply_firewall
  save_state
  reload
  echo
  info "已加载连接:"
  local conns
  conns="$(swanctl --list-conns 2>/dev/null | grep -E 'rw-(psk|eap)' || true)"
  if [[ -z "${conns}" ]]; then
    warn "没有加载到连接，检查配置语法"
  else
    printf '%s\n' "${conns}" | sed 's/^/    /'
  fi
  if [[ -n "${FIRST_USER}" && -n "${FIRST_PASS}" ]]; then
    cmd_useradd "${FIRST_USER}" "${FIRST_PASS}"
  fi
  cmd_client
  cat <<EOF

${LOG} 安装完成   地址池 ${POOL4}$([[ -n ${POOL6} ]] && echo "  ${POOL6}")

必做: 路由器/云安全组放通 UDP 500 与 UDP 4500 到本机。
      连不上先跑 bash $0 status 体检；想重看上面的参数跑 bash $0 client。
EOF
}

cmd_client() {
  load_state
  if [[ "${MODE}" == "both" ]]; then MODE="psk"; fi
  echo
  echo "============ 安卓手机填表参数 ============"
  if [[ "${MODE}" == "psk" ]]; then
    local psk="(未生成，重跑 install 或 rotate-psk)"
    if [[ -f "${PSK_FILE}" ]]; then
      psk="$(awk -F'secret = ' '/secret = /{print $2; exit}' "${PSK_FILE}")"
    fi
    echo
    echo "【方式一】VPN 类型选 IKEv2/IPsec PSK"
    echo "  服务器地址       : ${VPN_HOST}"
    echo "  IPsec 标识符     : ${PSK_IDENT}    <== 手机必须填这个，填错直接认证失败"
    echo "  IPsec 预共享密钥 : ${psk}"
  fi
  if [[ "${MODE}" == "eap" ]]; then
    echo
    echo "【当前模式：账号密码】VPN 类型选 IKEv2/IPsec MSCHAPv2"
    echo "  服务器地址       : ${VPN_HOST}"
    echo "  IPsec 标识符     : 随便填（习惯上填用户名），服务端按下面的用户名密码认证"
    local u
    if [[ -s "${USER_LIST}" ]]; then
      while IFS=: read -r u _; do
        if [[ -n "${u}" ]]; then echo "  已有账号         : ${u}"; fi
      done <"${USER_LIST}"
      echo "  忘记密码         : bash $0 useradd 用户名 新密码 (同名覆盖即改密)"
    else
      echo "  可用账号         : 还没有，先跑 bash $0 useradd 名字 密码"
    fi
    echo "  IPsec CA 证书    : 可选。把 /root/ikev2-ca.crt 拷到手机导入后再选它"
    echo "                     可防服务器被冒充；不选也能连，只是不校验服务器身份"
  elif [[ "${MODE}" == "psk" ]]; then
    echo
    echo "  想换成账号密码模式: bash $0 mode eap"
  fi
  echo "=========================================="
}

valid_user() { [[ "$1" =~ ^[A-Za-z0-9._@-]+$ ]]; }

cmd_useradd() {
  need_root useradd
  load_state
  local u="${1:-}" p="${2:-}"
  [[ -n "${u}" && -n "${p}" ]] || die "用法: bash $0 useradd <用户名> <密码>"
  valid_user "${u}" || die "用户名只允许字母数字和 . _ @ -"
  case "${p}" in
    *:*|*'"'*|*'\'*|*" "*) die "密码不能含空格、冒号、单双引号或反斜杠" ;;
  esac
  mkdir -p /etc/ikev2-vpn; touch "${USER_LIST}"
  awk -F: -v u="${u}" '$1 != u' "${USER_LIST}" >"${USER_LIST}.tmp"
  mv "${USER_LIST}.tmp" "${USER_LIST}"
  printf '%s:%s\n' "${u}" "${p}" >>"${USER_LIST}"
  chmod 600 "${USER_LIST}"
  regen_eap; reload
  info "EAP 用户 ${u} 已就绪"
}

cmd_userdel() {
  need_root userdel
  load_state
  local u="${1:-}"
  [[ -n "${u}" ]] || die "用法: bash $0 userdel <用户名>"
  [[ -f "${USER_LIST}" ]] || die "用户表不存在"
  awk -F: -v u="${u}" '$1 != u' "${USER_LIST}" >"${USER_LIST}.tmp"
  mv "${USER_LIST}.tmp" "${USER_LIST}"
  regen_eap; reload
  info "EAP 用户 ${u} 已删除（在线会话将在 rekey 超时后断开，或重启 strongswan 立即断开）"
}

cmd_users() {
  load_state
  [[ -s "${USER_LIST}" ]] || { info "暂无 EAP 用户"; return; }
  cut -d: -f1 "${USER_LIST}" | sed 's/^/  /'
}

cmd_rotate_psk() {
  need_root rotate-psk
  load_state
  local psk saved
  saved="${PSK_VALUE}"
  PSK_VALUE=""          # 换密钥必须重新随机，忽略变量区里写死的值
  psk="$(gen_psk)"
  PSK_VALUE="${saved}"
  reload
  echo "  新 PSK: ${psk}"
  info "旧密钥已失效，所有 PSK 客户端需重新填写"
}

cmd_status() {
  load_state
  echo "── 服务 ─────────────────────────"
  echo "  strongswan: $(systemctl is-active strongswan 2>/dev/null || echo down)"
  echo "── 已加载连接 ───────────────────"
  local conns
  conns="$(swanctl --list-conns 2>/dev/null | grep -E 'rw-(psk|eap)' || true)"
  if [[ -z "${conns}" ]]; then
    echo "  无"
  else
    printf '%s\n' "${conns}" | sed 's/^/  /'
  fi
  echo "── 在线客户端 ───────────────────"
  swanctl --list-sas 2>/dev/null | grep -Ev '^\s*$' | head -24 | sed 's/^/  /' || echo "  无"
  echo "── 监听 ─────────────────────────"
  (ss -lunp 2>/dev/null | grep -E ':(500|4500)\b' || echo "  未见 500/4500 监听") | sed 's/^/  /'
  echo "── 转发 / NAT ───────────────────"
  echo "  ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)  ipv6_forward=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)"
  (iptables -t nat -S POSTROUTING 2>/dev/null | grep -i masquerade || echo "  无 MASQUERADE") | sed 's/^/  /'
  echo "── 最近日志 ─────────────────────"
  journalctl -u strongswan --since '10 min ago' --no-pager -n 12 2>/dev/null | sed 's/^/  /' || true
}

cmd_mode() {
  need_root mode
  load_state
  local m="${1:-}"
  case "${m}" in
    psk|eap) ;;
    *) die "用法: bash $0 mode psk|eap" ;;
  esac
  if [[ -z "${MODE:-}" ]]; then MODE="psk"; fi
  if [[ "${m}" == "${MODE}" ]]; then info "已经是 ${m} 模式，无需切换"; return; fi
  MODE="${m}"
  save_state
  if [[ "${MODE}" == "psk" ]]; then
    rm -f "${PSK_FILE}"
    local psk
    psk="$(gen_psk)"
    info "已切到 PSK 模式，密钥: ${psk}"
  else
    rm -f "${PSK_FILE}"
    gen_pki
    info "已切到 EAP 模式；用 bash $0 useradd 名字 密码 添加账号"
  fi
  regen_eap
  write_conf
  reload
  cmd_client
}

cmd_diag() {
  need_root diag
  load_state
  if [[ -z "${MODE:-}" ]]; then MODE="psk"; fi
  echo "── 服务 ─────────────────────────────"
  echo "  strongswan: $(systemctl is-active strongswan 2>/dev/null || echo down)"
  echo "── 已加载连接 ───────────────────────"
  local conns
  conns="$(swanctl --list-conns 2>/dev/null | grep -E 'rw-(psk|eap)' || true)"
  if [[ -z "${conns}" ]]; then
    echo "  无（配置没加载或语法错误）"
  else
    printf '%s\n' "${conns}" | sed 's/^/  /'
  fi
  echo "── 端口监听 / 防火墙 / 转发 ─────────"
  (ss -lunp 2>/dev/null | grep -E ':(500|4500)\b' || echo "  本机没有监听 500/4500") | sed 's/^/  /'
  local n
  n="$(iptables -S INPUT 2>/dev/null | grep -E 'dport (500|4500)' | wc -l)"
  echo "  本机 INPUT 放行规则: ${n} 条"
  echo "  ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)  (必须为 1)"
  echo "── 身份一致性（PSK 连不上的头号原因）─"
  echo "  手机要连的服务器地址 : ${VPN_HOST}"
  if [[ "${MODE}" == "psk" ]]; then
    echo "  服务端身份 local id   : ${VPN_HOST}   <-- 必须等于上面那行"
    echo "  手机 IPsec 标识符     : ${PSK_IDENT}  <-- 手机必须原样填这个"
  fi
  if [[ -f "${CONF_DIR}/x509/server.crt" ]]; then
    echo "── 服务端证书身份 ───────────────────"
    pki --print --in "${CONF_DIR}/x509/server.crt" 2>/dev/null | grep -iE 'subject:|altName:|san:' | sed 's/^/  /' || true
    echo "  证书 CN/SAN 也必须等于服务器地址 ${VPN_HOST}"
  fi
  echo "── 抓包 25 秒：现在请用手机发起一次连接 ──"
  if command -v tcpdump >/dev/null 2>&1; then
    timeout 25 tcpdump -nn -i any -c 12 'udp port 500 or udp port 4500' 2>/dev/null || true
    echo "  一行都没有  = 路由器端口转发/云安全组没放行 UDP 500 和 4500"
    echo "  有包但失败  = 看下面的日志关键字定位"
  else
    echo "  没装 tcpdump，手动跑:"
    echo "    apt install -y tcpdump && tcpdump -ni any 'udp port 500 or udp port 4500'"
  fi
  echo "── 最近 5 分钟错误 ──────────────────"
  journalctl -u strongswan --since '5 min ago' --no-pager 2>/dev/null \
    | grep -iE 'error|fail|no matching|constraint|authentication|proposal|IDr|IDi' \
    | tail -15 | sed 's/^/  /' || true
  echo "  完整日志: journalctl -u strongswan -f"
}

cmd_uninstall() {
  need_root uninstall
  # 未安装时也要能继续清理，不能用 load_state（内部 die 会直接 exit，|| true 拦不住）
  if [[ -r "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
  systemctl stop strongswan >/dev/null 2>&1 || true
  rm -f "${CONF_FILE}" "${PSK_FILE}" "${EAP_FILE}" /etc/sysctl.d/99-ikev2-vpn.conf
  rm -rf /etc/ikev2-vpn
  sysctl --system >/dev/null 2>&1 || true
  info "配置已清除（strongSwan 包保留，证书在 ${CONF_DIR}，防火墙规则需手动清理）"
}

usage() {
  cat <<EOF
用法: bash $0 <命令> [参数]
  install [--auto]        安装 / 重装备（默认交互式问配置，--auto 全程用默认值）
  client                  打印安卓手机填表参数
  status                  体检：服务 / 连接 / 在线客户端 / 端口 / 转发 / NAT / 日志
  useradd <用户名> <密码>  添加 EAP 用户
  userdel <用户名>         删除 EAP 用户
  users                   列出 EAP 用户
  rotate-psk              重生成 PSK（旧密钥立即失效）
  mode psk|eap            切换接入模式（同一地址只能生效一种）
  diag                    连不上时的诊断：体检 + 抓包 25 秒 + 错误日志
  uninstall               清除配置
EOF
}

case "${1:-}" in
  install)    shift; cmd_install "$@" ;;
  client)     cmd_client ;;
  status)     cmd_status ;;
  useradd)    shift; cmd_useradd "$@" ;;
  userdel)    shift; cmd_userdel "$@" ;;
  users)      cmd_users ;;
  rotate-psk) cmd_rotate_psk ;;
  mode)       shift; cmd_mode "$@" ;;
  diag)       cmd_diag ;;
  uninstall)  cmd_uninstall ;;
  *)          usage; exit 1 ;;
esac
