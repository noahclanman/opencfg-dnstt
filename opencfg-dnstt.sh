#!/usr/bin/env bash
# ==============================================================================
# OpenCFG DNSTT Manager
# by Shinusterben / OpenCFG
#
# Safe-by-default DNSTT installer/manager for SSH, Xray/V2Ray, or any local TCP
# backend. Designed to coexist with 3x-ui, Webmin, SSH VPN installers, Nginx,
# Xray, OpenVPN, and other existing services.
#
# IMPORTANT:
#   - Does NOT edit iptables/ip6tables/nftables/UFW/firewalld.
#   - Does NOT replace /etc/rc.local.
#   - Does NOT edit /etc/resolv.conf or stop systemd-resolved.
#   - Does NOT restart SSH, Webmin, Xray, Nginx, or other VPN services.
#   - DNSTT listens directly on UDP/53 on a selected local interface address.
#
# DNSTT source: https://www.bamsoftware.com/software/dnstt/
# Pinned DNSTT version: v1.20260501.0
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="OpenCFG DNSTT Manager"
APP_VERSION="1.0.1"
AUTHOR="Shinusterben / OpenCFG"

BASE_DIR="/etc/opencfg-dnstt"
CONFIG_FILE="${BASE_DIR}/config"
PRIVKEY_FILE="${BASE_DIR}/server.key"
PUBKEY_FILE="${BASE_DIR}/server.pub"
RUNNER_FILE="/usr/local/lib/opencfg-dnstt/run"
SERVICE_FILE="/etc/systemd/system/opencfg-dnstt.service"
SERVICE_NAME="opencfg-dnstt.service"
DNSTT_BIN="/usr/local/lib/opencfg-dnstt/dnstt-server"
MANAGER_PATH="/usr/local/sbin/opencfg-dnstt"
MANAGER_LINK="/usr/local/bin/opencfg-dnstt"

DNSTT_VERSION="v1.20260501.0"
GO_VERSION="1.26.5"
GO_ROOT="/opt/opencfg-dnstt-go"
GO_BIN="${GO_ROOT}/bin/go"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Run this manager as root: sudo $0"
    fi
}

pause() {
    echo
    read -r -p "Press Enter to continue..." _
}

valid_domain() {
    local d="${1,,}"
    [[ "$d" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] &&
    [[ "$d" == *.* ]] &&
    [[ "$d" != *..* ]] &&
    [[ ${#d} -le 253 ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

valid_mtu() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 512 <= 10#$1 && 10#$1 <= 4096 ))
}

valid_backend_host() {
    local host="$1"
    [[ -n "$host" && ${#host} -le 253 ]] || return 1
    [[ "$host" != *$'\n'* && "$host" != *$'\r'* ]] || return 1

    if [[ "$host" == "localhost" ]]; then
        return 0
    fi

    # Accept normal DNS hostnames, IPv4 literals, and IPv6 literals.
    if [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 0
    fi

    if [[ "$host" == *:* && "$host" =~ ^[0-9A-Fa-f:.%_-]+$ ]]; then
        return 0
    fi

    return 1
}

format_backend_address() {
    local host="$1"
    local port="$2"

    # net.Dial-style host:port syntax requires brackets around IPv6 literals.
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

detect_bind_ipv4() {
    local ip=""
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "src" && (i + 1) <= NF) {
                    print $(i + 1);
                    exit
                }
            }
        }' || true)"
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    printf '%s' "$ip"
}

detect_public_ipv4() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    fi
    printf '%s' "$ip"
}

service_state() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${GREEN}ACTIVE${NC}"
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${YELLOW}STOPPED${NC}"
    else
        echo -e "${DIM}NOT INSTALLED${NC}"
    fi
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

header() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE}                 OpenCFG DNSTT Manager v${APP_VERSION}              ${BLUE}║${NC}"
    echo -e "${BLUE}║${DIM}                  by ${AUTHOR}                    ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
}

show_dashboard() {
    local state
    state="$(service_state)"
    echo -e "  Service : ${state}"
    if load_config 2>/dev/null; then
        echo -e "  Mode    : ${WHITE}${BACKEND_MODE:-Custom}${NC}"
        echo -e "  Domain  : ${WHITE}${TUNNEL_DOMAIN:-Not configured}${NC}"
        echo -e "  Listen  : ${WHITE}${BIND_ADDR:-?}:53/udp${NC}"
        echo -e "  Backend : ${WHITE}$(format_backend_address "${BACKEND_HOST:-127.0.0.1}" "${BACKEND_PORT:-?}")${NC}"
        echo -e "  MTU     : ${WHITE}${MTU:-1232}${NC}"
    fi
    echo
    echo -e "${DIM}Firewall policy: untouched | DNS resolver config: untouched | rc.local: untouched${NC}"
    echo
}

install_dependencies() {
    info "Installing only required build/runtime packages..."
    export DEBIAN_FRONTEND=noninteractive

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y ca-certificates curl tar gzip iproute2
    else
        die "This installer currently supports Debian/Ubuntu systems with apt-get."
    fi
}

install_private_go() {
    local arch go_arch go_sha256 tmp tarball url actual_sha256

    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            go_arch="amd64"
            go_sha256="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
            ;;
        aarch64|arm64)
            go_arch="arm64"
            go_sha256="fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49"
            ;;
        *)
            die "Unsupported CPU architecture for automatic Go bootstrap: $arch"
            ;;
    esac

    if [[ -x "$GO_BIN" ]]; then
        return 0
    fi

    info "Installing private Go ${GO_VERSION} toolchain for building DNSTT..."
    tmp="$(mktemp -d)"
    tarball="${tmp}/go.tar.gz"
    url="https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"

    curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tarball" ||
        die "Could not download Go ${GO_VERSION} from go.dev."

    actual_sha256="$(sha256sum "$tarball" | awk '{print $1}')"
    [[ "$actual_sha256" == "$go_sha256" ]] || {
        rm -rf "$tmp"
        die "Go toolchain checksum verification failed."
    }

    rm -rf "$GO_ROOT"
    mkdir -p "$(dirname "$GO_ROOT")"
    tar -C "$tmp" -xzf "$tarball"
    mv "$tmp/go" "$GO_ROOT"
    rm -rf "$tmp"

    [[ -x "$GO_BIN" ]] || die "Go toolchain installation failed."
}

build_dnstt() {
    local tmp gobin

    install_private_go

    info "Building official DNSTT ${DNSTT_VERSION} from open-source Go module..."
    tmp="$(mktemp -d)"
    gobin="${tmp}/bin"
    mkdir -p "$gobin"

    if ! env \
        GOBIN="$gobin" \
        GOPROXY="https://proxy.golang.org,direct" \
        GOTOOLCHAIN="auto" \
        "$GO_BIN" install "www.bamsoftware.com/git/dnstt.git/dnstt-server@${DNSTT_VERSION}"
    then
        rm -rf "$tmp"
        die "DNSTT source build failed."
    fi

    [[ -x "${gobin}/dnstt-server" ]] || {
        rm -rf "$tmp"
        die "Built dnstt-server binary was not found."
    }

    mkdir -p "$(dirname "$DNSTT_BIN")"
    install -m 0755 "${gobin}/dnstt-server" "$DNSTT_BIN"
    rm -rf "$tmp"
    ok "Installed ${DNSTT_BIN} from DNSTT ${DNSTT_VERSION} source."
}

install_self() {
    mkdir -p "$(dirname "$MANAGER_PATH")" "$(dirname "$MANAGER_LINK")"

    local current
    current="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

    if [[ "$current" != "$MANAGER_PATH" ]]; then
        install -m 0755 "$current" "$MANAGER_PATH"
    else
        chmod 0755 "$MANAGER_PATH"
    fi

    ln -sfn "$MANAGER_PATH" "$MANAGER_LINK"
}

generate_keys_if_needed() {
    mkdir -p "$BASE_DIR"
    chmod 0700 "$BASE_DIR"

    if [[ -s "$PRIVKEY_FILE" && -s "$PUBKEY_FILE" ]]; then
        ok "Existing DNSTT keypair kept."
        return 0
    fi

    info "Generating a new DNSTT server keypair..."
    rm -f "$PRIVKEY_FILE" "$PUBKEY_FILE"
    "$DNSTT_BIN" -gen-key \
        -privkey-file "$PRIVKEY_FILE" \
        -pubkey-file "$PUBKEY_FILE"

    chmod 0400 "$PRIVKEY_FILE"
    chmod 0644 "$PUBKEY_FILE"
    ok "New keypair generated."
}

write_runner() {
    mkdir -p "$(dirname "$RUNNER_FILE")"

    cat > "$RUNNER_FILE" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/opencfg-dnstt/config"
DNSTT_BIN="/usr/local/lib/opencfg-dnstt/dnstt-server"

[[ -r "$CONFIG_FILE" ]] || {
    echo "Missing config: $CONFIG_FILE" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ "$BACKEND_HOST" == *:* && "$BACKEND_HOST" != \[*\] ]]; then
    BACKEND_ADDR="[${BACKEND_HOST}]:${BACKEND_PORT}"
else
    BACKEND_ADDR="${BACKEND_HOST}:${BACKEND_PORT}"
fi

exec "$DNSTT_BIN" \
    -udp "${BIND_ADDR}:53" \
    -mtu "${MTU}" \
    -privkey-file "${PRIVKEY_FILE}" \
    "${TUNNEL_DOMAIN}" \
    "${BACKEND_ADDR}"
RUNNER

    chmod 0755 "$RUNNER_FILE"
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=OpenCFG DNSTT Server
Documentation=https://www.bamsoftware.com/software/dnstt/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${RUNNER_FILE}
Restart=on-failure
RestartSec=3
TimeoutStopSec=10
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

udp53_conflicts() {
    local bind_ip="$1"
    local escaped_ip
    escaped_ip="${bind_ip//./\\.}"

    ss -H -lunp 2>/dev/null | awk '{print $4 " " substr($0, index($0,$5))}' |
        grep -E "^(${escaped_ip}:53|0\.0\.0\.0:53|\*:53|\[::\]:53|:::53)[[:space:]]" || true
}

check_udp53() {
    local bind_ip="$1"
    local conflicts

    conflicts="$(udp53_conflicts "$bind_ip")"
    if [[ -n "$conflicts" ]]; then
        echo
        warn "Another process may conflict with DNSTT on ${bind_ip}:53/udp:"
        echo "$conflicts"
        echo
        echo "This manager will NOT kill, stop, or reconfigure that service."
        echo "Resolve the conflict manually, or choose another local bind address."
        return 1
    fi

    return 0
}

check_backend_listener() {
    local host="$1"
    local port="$2"

    if [[ "$host" != "127.0.0.1" && "$host" != "localhost" && "$host" != "::1" ]]; then
        warn "Backend is not localhost (${host}:${port}); make sure that is intentional."
        return 0
    fi

    if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\])${port}$"; then
        ok "Detected a TCP listener on port ${port}."
    else
        warn "No TCP listener was detected on port ${port}."
        warn "DNSTT can still install, but connections will fail until your SSH/Xray/V2Ray backend is listening."
    fi
}

save_config() {
    local tunnel_domain="$1"
    local ns_host="$2"
    local bind_addr="$3"
    local backend_host="$4"
    local backend_port="$5"
    local backend_mode="$6"
    local mtu="$7"

    mkdir -p "$BASE_DIR"
    chmod 0700 "$BASE_DIR"

    cat > "$CONFIG_FILE" <<EOF
# OpenCFG DNSTT configuration
# Managed by opencfg-dnstt. You may edit this file manually, then restart:
# systemctl restart opencfg-dnstt

EOF

    {
        printf 'TUNNEL_DOMAIN=%q\n' "$tunnel_domain"
        printf 'NS_HOST=%q\n' "$ns_host"
        printf 'BIND_ADDR=%q\n' "$bind_addr"
        printf 'BACKEND_HOST=%q\n' "$backend_host"
        printf 'BACKEND_PORT=%q\n' "$backend_port"
        printf 'BACKEND_MODE=%q\n' "$backend_mode"
        printf 'MTU=%q\n' "$mtu"
        printf 'PRIVKEY_FILE=%q\n' "$PRIVKEY_FILE"
        printf 'PUBKEY_FILE=%q\n' "$PUBKEY_FILE"
    } >> "$CONFIG_FILE"

    chmod 0600 "$CONFIG_FILE"
}

configure_interactive() {
    local old_domain="" old_ns="" old_bind="" old_backend_host="127.0.0.1"
    local old_backend_port="" old_mode="" old_mtu="1232"
    local tunnel_domain ns_host bind_addr backend_host backend_port mode_choice backend_mode mtu
    local detected_bind

    if load_config 2>/dev/null; then
        old_domain="${TUNNEL_DOMAIN:-}"
        old_ns="${NS_HOST:-}"
        old_bind="${BIND_ADDR:-}"
        old_backend_host="${BACKEND_HOST:-127.0.0.1}"
        old_backend_port="${BACKEND_PORT:-}"
        old_mode="${BACKEND_MODE:-}"
        old_mtu="${MTU:-1232}"
    fi

    detected_bind="$(detect_bind_ipv4)"
    [[ -n "$old_bind" ]] && detected_bind="$old_bind"

    echo
    echo -e "${WHITE}Backend type${NC}"
    echo "  1) SSH / Dropbear"
    echo "  2) Xray / V2Ray / 3x-ui"
    echo "  3) Custom local TCP service"
    echo

    if [[ "$old_mode" == "SSH" ]]; then
        read -r -p "Choose [1]: " mode_choice
        mode_choice="${mode_choice:-1}"
    elif [[ "$old_mode" == "Xray/V2Ray" ]]; then
        read -r -p "Choose [2]: " mode_choice
        mode_choice="${mode_choice:-2}"
    else
        read -r -p "Choose [2]: " mode_choice
        mode_choice="${mode_choice:-2}"
    fi

    case "$mode_choice" in
        1)
            backend_mode="SSH"
            backend_port="${old_backend_port:-22}"
            [[ "$old_mode" != "SSH" ]] && backend_port="22"
            ;;
        2)
            backend_mode="Xray/V2Ray"
            backend_port="${old_backend_port:-443}"
            [[ "$old_mode" != "Xray/V2Ray" ]] && backend_port="443"
            ;;
        3)
            backend_mode="Custom"
            backend_port="${old_backend_port:-443}"
            ;;
        *)
            die "Invalid backend type."
            ;;
    esac

    while true; do
        read -r -p "Tunnel domain (example: t.example.com) [${old_domain}]: " tunnel_domain
        tunnel_domain="${tunnel_domain:-$old_domain}"
        tunnel_domain="${tunnel_domain,,}"
        valid_domain "$tunnel_domain" && break
        warn "Enter a valid tunnel domain such as t.example.com."
    done

    while true; do
        read -r -p "Nameserver host (example: ns.example.com) [${old_ns}]: " ns_host
        ns_host="${ns_host:-$old_ns}"
        ns_host="${ns_host,,}"
        valid_domain "$ns_host" && break
        warn "Enter a valid nameserver hostname such as ns.example.com."
    done

    if [[ "$ns_host" == *".${tunnel_domain}" || "$ns_host" == "$tunnel_domain" ]]; then
        warn "The NS hostname should normally NOT be inside the tunnel zone."
        warn "Example: tunnel=t.example.com, nameserver=ns.example.com"
        read -r -p "Continue anyway? [y/N]: " _
        [[ "${_:-}" =~ ^[Yy]$ ]] || return 1
    fi

    while true; do
        read -r -p "Local bind IPv4 for UDP/53 [${detected_bind}]: " bind_addr
        bind_addr="${bind_addr:-$detected_bind}"
        if [[ "$bind_addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && \
           ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$bind_addr"; then
            break
        fi
        warn "Choose an IPv4 address that is actually assigned to this VPS."
    done

    while true; do
        read -r -p "Backend host [${old_backend_host}]: " backend_host
        backend_host="${backend_host:-$old_backend_host}"
        valid_backend_host "$backend_host" && break
        warn "Enter a valid hostname, IPv4 address, or IPv6 address."
    done

    while true; do
        read -r -p "Backend TCP port [${backend_port}]: " answer
        backend_port="${answer:-$backend_port}"
        valid_port "$backend_port" && break
        warn "Port must be between 1 and 65535."
    done

    while true; do
        read -r -p "DNSTT response MTU [${old_mtu}]: " mtu
        mtu="${mtu:-$old_mtu}"
        valid_mtu "$mtu" && break
        warn "MTU must be between 512 and 4096. 1232 is the recommended default."
    done

    save_config \
        "$tunnel_domain" \
        "$ns_host" \
        "$bind_addr" \
        "$backend_host" \
        "$backend_port" \
        "$backend_mode" \
        "$mtu"

    check_backend_listener "$backend_host" "$backend_port"
}

install_or_reconfigure() {
    require_root
    header
    echo -e "${WHITE}Install / Reconfigure OpenCFG DNSTT${NC}"
    echo
    echo "This operation does NOT touch firewall rules, rc.local, resolv.conf,"
    echo "systemd-resolved, SSH, Webmin, Xray, Nginx, or your existing VPN scripts."
    echo

    install_dependencies
    install_self

    if [[ ! -x "$DNSTT_BIN" ]]; then
        build_dnstt
    else
        ok "Existing OpenCFG dnstt-server found: $DNSTT_BIN"
    fi

    generate_keys_if_needed
    configure_interactive || return 0
    write_runner
    write_service

    # Stop only our own service before checking the address.
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    load_config
    if ! check_udp53 "$BIND_ADDR"; then
        warn "Configuration was saved, but the DNSTT service was not started."
        warn "Run 'opencfg-dnstt' after resolving the UDP/53 conflict."
        return 0
    fi

    if ! systemctl enable --now "$SERVICE_NAME"; then
        warn "DNSTT failed to enable or start. Recent logs:"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
        return 0
    fi

    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "OpenCFG DNSTT is running."
    else
        warn "The service did not stay active. Recent logs:"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
        return 0
    fi

    echo
    show_info_no_pause
}

show_info_no_pause() {
    load_config || {
        warn "DNSTT is not configured yet."
        return
    }

    local pubkey public_ip
    pubkey="$(tr -d '[:space:]' < "$PUBKEY_FILE" 2>/dev/null || true)"
    public_ip="$(detect_public_ipv4)"

    echo -e "${BLUE}──────────────────── DNSTT CONFIGURATION ────────────────────${NC}"
    echo -e "Mode            : ${WHITE}${BACKEND_MODE}${NC}"
    echo -e "Tunnel domain   : ${WHITE}${TUNNEL_DOMAIN}${NC}"
    echo -e "Nameserver host : ${WHITE}${NS_HOST}${NC}"
    echo -e "Local UDP bind  : ${WHITE}${BIND_ADDR}:53${NC}"
    echo -e "Backend         : ${WHITE}$(format_backend_address "$BACKEND_HOST" "$BACKEND_PORT")${NC}"
    echo -e "MTU             : ${WHITE}${MTU}${NC}"
    echo -e "Public key      : ${WHITE}${pubkey:-Unavailable}${NC}"
    [[ -n "$public_ip" ]] && echo -e "Public IPv4     : ${WHITE}${public_ip}${NC}"

    echo
    echo -e "${BLUE}DNS records you need:${NC}"
    if [[ -n "$public_ip" ]]; then
        echo "  A    ${NS_HOST}      -> ${public_ip}"
    else
        echo "  A    ${NS_HOST}      -> YOUR_VPS_PUBLIC_IPV4"
    fi
    echo "  NS   ${TUNNEL_DOMAIN} -> ${NS_HOST}"
    echo
    echo "If you use Cloudflare DNS, keep the nameserver A record DNS-only (not proxied)."
    echo "Your VPS/provider firewall or security group must allow inbound UDP port 53."
    echo
    echo -e "${YELLOW}Important:${NC} this manager intentionally does not open that port for you."
}

show_info() {
    header
    show_info_no_pause
    pause
}

change_backend() {
    require_root
    load_config || {
        warn "Install/configure DNSTT first."
        pause
        return
    }

    header
    echo -e "${WHITE}Change backend only${NC}"
    echo
    echo "Current: ${BACKEND_MODE} -> $(format_backend_address "$BACKEND_HOST" "$BACKEND_PORT")"
    echo
    echo "  1) SSH / Dropbear"
    echo "  2) Xray / V2Ray / 3x-ui"
    echo "  3) Custom TCP"
    echo
    read -r -p "Choose: " choice

    local new_mode new_port new_host answer
    new_host="$BACKEND_HOST"

    case "$choice" in
        1) new_mode="SSH"; new_port="22" ;;
        2) new_mode="Xray/V2Ray"; new_port="443" ;;
        3) new_mode="Custom"; new_port="$BACKEND_PORT" ;;
        *)
            warn "Invalid option."
            pause
            return
            ;;
    esac

    while true; do
        read -r -p "Backend host [${new_host}]: " answer
        new_host="${answer:-$new_host}"
        valid_backend_host "$new_host" && break
        warn "Enter a valid hostname, IPv4 address, or IPv6 address."
    done

    while true; do
        read -r -p "Backend port [${new_port}]: " answer
        new_port="${answer:-$new_port}"
        valid_port "$new_port" && break
        warn "Port must be between 1 and 65535."
    done

    save_config \
        "$TUNNEL_DOMAIN" \
        "$NS_HOST" \
        "$BIND_ADDR" \
        "$new_host" \
        "$new_port" \
        "$new_mode" \
        "$MTU"

    check_backend_listener "$new_host" "$new_port"
    if ! systemctl restart "$SERVICE_NAME"; then
        warn "DNSTT failed to restart after changing the backend."
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
        pause
        return
    fi

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Backend changed to $(format_backend_address "$new_host" "$new_port")."
    else
        warn "DNSTT did not stay active after the backend change."
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    fi
    pause
}

change_domain() {
    require_root
    load_config || {
        warn "Install/configure DNSTT first."
        pause
        return
    }

    header
    echo -e "${WHITE}Change tunnel DNS names${NC}"
    echo

    local new_domain new_ns
    while true; do
        read -r -p "Tunnel domain [${TUNNEL_DOMAIN}]: " new_domain
        new_domain="${new_domain:-$TUNNEL_DOMAIN}"
        new_domain="${new_domain,,}"
        valid_domain "$new_domain" && break
        warn "Enter a valid domain."
    done

    while true; do
        read -r -p "Nameserver host [${NS_HOST}]: " new_ns
        new_ns="${new_ns:-$NS_HOST}"
        new_ns="${new_ns,,}"
        valid_domain "$new_ns" && break
        warn "Enter a valid domain."
    done

    save_config \
        "$new_domain" \
        "$new_ns" \
        "$BIND_ADDR" \
        "$BACKEND_HOST" \
        "$BACKEND_PORT" \
        "$BACKEND_MODE" \
        "$MTU"

    if ! systemctl restart "$SERVICE_NAME"; then
        warn "Tunnel settings were saved, but DNSTT failed to restart."
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
        pause
        return
    fi
    ok "Tunnel domain settings updated."
    echo
    show_info_no_pause
    pause
}

start_service() {
    require_root
    if [[ ! -f "$SERVICE_FILE" ]]; then
        warn "DNSTT is not installed yet."
        pause
        return
    fi
    load_config || {
        warn "DNSTT config is missing."
        pause
        return
    }

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "OpenCFG DNSTT is already running."
        pause
        return
    fi

    if ! check_udp53 "$BIND_ADDR"; then
        warn "Cannot start because UDP/53 is occupied."
        pause
        return
    fi

    if ! systemctl start "$SERVICE_NAME"; then
        warn "OpenCFG DNSTT failed to start. Recent logs:"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
        pause
        return
    fi
    ok "OpenCFG DNSTT started."
    pause
}

restart_service() {
    require_root
    if ! systemctl restart "$SERVICE_NAME"; then
        warn "OpenCFG DNSTT failed to restart. Recent logs:"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
        pause
        return
    fi
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "OpenCFG DNSTT restarted."
    else
        warn "DNSTT did not stay active after restart."
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    fi
    pause
}

stop_service() {
    require_root
    if ! systemctl stop "$SERVICE_NAME"; then
        warn "OpenCFG DNSTT could not be stopped cleanly."
        pause
        return
    fi
    ok "OpenCFG DNSTT stopped."
    pause
}

status_service() {
    header
    systemctl status "$SERVICE_NAME" --no-pager -l || true
    pause
}

show_logs() {
    header
    journalctl -u "$SERVICE_NAME" -n 100 --no-pager || true
    pause
}

regenerate_keys() {
    require_root
    [[ -x "$DNSTT_BIN" ]] || {
        warn "dnstt-server is not installed."
        pause
        return
    }

    header
    echo -e "${YELLOW}Regenerating keys will invalidate the old public key in every client config.${NC}"
    echo
    read -r -p "Generate a new DNSTT keypair? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$PRIVKEY_FILE" "$PUBKEY_FILE"
    generate_keys_if_needed

    if [[ -f "$CONFIG_FILE" ]]; then
        systemctl start "$SERVICE_NAME" || true
    fi

    ok "New keypair created."
    echo
    show_info_no_pause
    pause
}

rebuild_dnstt() {
    require_root
    header
    echo -e "${WHITE}Rebuild official DNSTT ${DNSTT_VERSION}${NC}"
    echo
    install_dependencies
    build_dnstt

    if [[ -f "$SERVICE_FILE" ]]; then
        if ! systemctl restart "$SERVICE_NAME"; then
            warn "DNSTT was rebuilt, but the service failed to restart."
            journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
            pause
            return
        fi
    fi

    ok "DNSTT binary rebuilt from source."
    pause
}

dns_help() {
    header
    echo -e "${WHITE}DNSTT DNS setup${NC}"
    echo
    echo "Example:"
    echo "  VPS public IPv4 : 203.0.113.10"
    echo "  NS hostname     : ns.example.com"
    echo "  Tunnel domain   : t.example.com"
    echo
    echo "Create:"
    echo "  A    ns.example.com    -> 203.0.113.10"
    echo "  NS   t.example.com     -> ns.example.com"
    echo
    echo "The NS hostname should not be inside the tunnel zone."
    echo "Good: tunnel=t.example.com, NS=ns.example.com"
    echo "Avoid: tunnel=t.example.com, NS=ns.t.example.com"
    echo
    echo "Also allow inbound UDP/53 in your cloud/VPS provider firewall."
    echo
    echo -e "${YELLOW}This script intentionally makes zero firewall changes.${NC}"
    pause
}

uninstall_manager() {
    require_root
    header
    echo -e "${YELLOW}This removes only OpenCFG DNSTT files and its systemd service.${NC}"
    echo "It will NOT remove or modify SSH, Xray, 3x-ui, Nginx, Webmin,"
    echo "OpenVPN, iptables, nftables, UFW, firewalld, or DNS resolver settings."
    echo
    read -r -p "Uninstall OpenCFG DNSTT? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0

    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    rm -f "$RUNNER_FILE" "$DNSTT_BIN"
    rmdir "$(dirname "$RUNNER_FILE")" 2>/dev/null || true

    rm -rf "$BASE_DIR"
    rm -f "$MANAGER_LINK"

    ok "OpenCFG DNSTT service, config, keys, and binary removed."
    echo "The private Go build toolchain at ${GO_ROOT} was kept."
    echo "Remove it manually if you want: rm -rf ${GO_ROOT}"
    echo
    echo "The current manager process will exit now."

    # Do this last because the currently running copy may be MANAGER_PATH.
    rm -f "$MANAGER_PATH"
    exit 0
}

menu() {
    require_root

    while true; do
        header
        show_dashboard
        echo -e "${BLUE}[01]${NC} Install / Reconfigure DNSTT"
        echo -e "${BLUE}[02]${NC} Show configuration + public key"
        echo -e "${BLUE}[03]${NC} Change backend (SSH / V2Ray / custom)"
        echo -e "${BLUE}[04]${NC} Change tunnel domain / NS"
        echo -e "${BLUE}[05]${NC} Start DNSTT"
        echo -e "${BLUE}[06]${NC} Restart DNSTT"
        echo -e "${BLUE}[07]${NC} Stop DNSTT"
        echo -e "${BLUE}[08]${NC} Service status"
        echo -e "${BLUE}[09]${NC} View recent logs"
        echo -e "${BLUE}[10]${NC} Regenerate DNSTT keys"
        echo -e "${BLUE}[11]${NC} Rebuild official DNSTT from source"
        echo -e "${BLUE}[12]${NC} DNS setup help"
        echo -e "${BLUE}[13]${NC} Uninstall OpenCFG DNSTT"
        echo -e "${BLUE}[00]${NC} Exit"
        echo
        read -r -p "Select an option: " option

        case "$option" in
            1|01) install_or_reconfigure; pause ;;
            2|02) show_info ;;
            3|03) change_backend ;;
            4|04) change_domain ;;
            5|05) start_service ;;
            6|06) restart_service ;;
            7|07) stop_service ;;
            8|08) status_service ;;
            9|09) show_logs ;;
            10) regenerate_keys ;;
            11) rebuild_dnstt ;;
            12) dns_help ;;
            13) uninstall_manager ;;
            0|00) clear; exit 0 ;;
            *) warn "Invalid option."; sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --install|install)
        install_or_reconfigure
        ;;
    --info|info)
        require_root
        show_info_no_pause
        ;;
    --start|start)
        require_root
        systemctl start "$SERVICE_NAME"
        ;;
    --stop|stop)
        require_root
        systemctl stop "$SERVICE_NAME"
        ;;
    --restart|restart)
        require_root
        systemctl restart "$SERVICE_NAME"
        ;;
    --status|status)
        require_root
        systemctl status "$SERVICE_NAME" --no-pager -l
        ;;
    --logs|logs)
        require_root
        journalctl -u "$SERVICE_NAME" -n 100 --no-pager
        ;;
    --help|-h|help)
        cat <<EOF
${APP_NAME} ${APP_VERSION}
by ${AUTHOR}

Usage:
  opencfg-dnstt              Open interactive menu
  opencfg-dnstt --install    Install/reconfigure
  opencfg-dnstt --info       Show config and public key
  opencfg-dnstt --start      Start service
  opencfg-dnstt --stop       Stop service
  opencfg-dnstt --restart    Restart service
  opencfg-dnstt --status     Show service status
  opencfg-dnstt --logs       Show recent logs
EOF
        ;;
    "")
        menu
        ;;
    *)
        die "Unknown argument: ${1}. Use --help."
        ;;
esac
