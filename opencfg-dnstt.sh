#!/usr/bin/env bash
# BUILD-ID: OPENCFG-DNSTT-V1.3.1-20260810-UNIQUE
# ==============================================================================
# OpenCFG DNSTT Manager
# by Shinusterben / OpenCFG
#
# Compatibility-focused DNSTT manager for SSH / Xray / V2Ray / custom TCP.
# Uses the exact dns-server binary revision used by Leitura SlowDNS, but wraps
# it in a clean systemd service and does NOT install Leitura's firewall/DNS
# modifications.
#
# IMPORTANT SAFETY GUARANTEES:
#   - Does NOT edit iptables/ip6tables/nftables/UFW/firewalld.
#   - Does NOT replace /etc/rc.local.
#   - Does NOT edit /etc/resolv.conf or stop systemd-resolved.
#   - Does NOT restart SSH, Webmin, Xray, Nginx, OpenVPN, or other VPN services.
#   - Binds DNSTT directly to UDP/53 on one selected local IPv4 address.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="OpenCFG DNSTT Manager"
APP_VERSION="1.3.1"
AUTHOR="Shinusterben / OpenCFG"

BASE_DIR="/etc/opencfg-dnstt"
CONFIG_FILE="${BASE_DIR}/config"
PRIVKEY_FILE="${BASE_DIR}/server.key"
PUBKEY_FILE="${BASE_DIR}/server.pub"
ENGINE_DIR="/usr/local/lib/opencfg-dnstt"
DNSTT_BIN="${ENGINE_DIR}/dns-server"
ENGINE_MARKER="${BASE_DIR}/engine-id"
RUNNER_FILE="${ENGINE_DIR}/run"
SERVICE_FILE="/etc/systemd/system/opencfg-dnstt.service"
SERVICE_NAME="opencfg-dnstt.service"
MANAGER_PATH="/usr/local/sbin/opencfg-dnstt"
MANAGER_LINK="/usr/local/bin/opencfg-dnstt"

# Exact Leitura dns-server revision known to work with legacy SlowDNS clients.
# Pinned to an immutable commit and verified by its Git blob SHA-1.
ENGINE_COMMIT="9b25d1d56e4723be3c445ba6186d33b0ff7c74d9"
ENGINE_GIT_BLOB_SHA1="af32b882a18040af0a6e16ea759ca6fcc511b965"
ENGINE_URL="https://raw.githubusercontent.com/leitura/slowdns/${ENGINE_COMMIT}/dns-server"
ENGINE_ID="leitura-compat:${ENGINE_COMMIT}:${ENGINE_GIT_BLOB_SHA1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

die() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Run as root: sudo $0"
}

pause() {
    echo
    read -r -p "Press Enter to continue..." _ || true
}

header() {
    clear 2>/dev/null || true
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    printf "${BLUE}║${WHITE} %-58s ${BLUE}║${NC}\n" "${APP_NAME} v${APP_VERSION}"
    printf "${BLUE}║${DIM} %-58s ${BLUE}║${NC}\n" "by ${AUTHOR}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
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

valid_ipv4() {
    local ip="$1" o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<<"$ip" || return 1
    [[ -n "$o1" && -n "$o2" && -n "$o3" && -n "$o4" ]] || return 1
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
    done
}

detect_bind_ipv4() {
    local ip=""
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    printf '%s' "$ip"
}

detect_public_ipv4() {
    curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
}

load_config() {
    [[ -r "$CONFIG_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

install_dependencies() {
    info "Installing required runtime packages only..."
    export DEBIAN_FRONTEND=noninteractive
    command -v apt-get >/dev/null 2>&1 || die "Debian/Ubuntu with apt-get is required."
    apt-get update -y
    apt-get install -y ca-certificates curl iproute2 coreutils
}

install_self() {
    local current
    current="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    mkdir -p "$(dirname "$MANAGER_PATH")" "$(dirname "$MANAGER_LINK")"
    if [[ "$current" != "$MANAGER_PATH" ]]; then
        install -m 0755 "$current" "$MANAGER_PATH"
    else
        chmod 0755 "$MANAGER_PATH"
    fi
    ln -sfn "$MANAGER_PATH" "$MANAGER_LINK"
}

verify_git_blob() {
    local file="$1" size actual
    size="$(stat -c '%s' "$file")"
    actual="$({ printf 'blob %s\0' "$size"; cat "$file"; } | sha1sum | awk '{print $1}')"
    [[ "$actual" == "$ENGINE_GIT_BLOB_SHA1" ]]
}

engine_is_current() {
    [[ -x "$DNSTT_BIN" ]] || return 1
    [[ -r "$ENGINE_MARKER" ]] || return 1
    [[ "$(cat "$ENGINE_MARKER" 2>/dev/null)" == "$ENGINE_ID" ]] || return 1
    verify_git_blob "$DNSTT_BIN"
}

install_engine() {
    local arch tmp helpout
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) ;;
        *) die "This compatibility engine is x86_64/amd64 only. Current architecture: ${arch}" ;;
    esac

    mkdir -p "$ENGINE_DIR" "$BASE_DIR"
    chmod 0755 "$ENGINE_DIR"
    chmod 0700 "$BASE_DIR"

    if engine_is_current; then
        ok "Compatibility DNSTT engine already verified."
        return 0
    fi

    info "Installing pinned SlowDNS-compatible DNSTT engine..."
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN

    curl -fL --retry 4 --retry-delay 2 --connect-timeout 15 \
        "$ENGINE_URL" -o "$tmp" || die "Failed to download compatibility DNSTT engine."

    verify_git_blob "$tmp" || die "Engine integrity check failed; downloaded binary does not match pinned Git blob."
    chmod 0755 "$tmp"

    helpout="$("$tmp" -h 2>&1 || true)"
    [[ "$helpout" == *"-udp"* && "$helpout" == *"privkey"* ]] ||
        die "Downloaded file does not behave like the expected DNSTT server."

    install -m 0755 "$tmp" "$DNSTT_BIN"
    printf '%s\n' "$ENGINE_ID" > "$ENGINE_MARKER"
    chmod 0644 "$ENGINE_MARKER"
    rm -f "$tmp"
    trap - RETURN

    ok "Installed verified compatibility engine at ${DNSTT_BIN}."
}

generate_keys_if_needed() {
    mkdir -p "$BASE_DIR"
    chmod 0700 "$BASE_DIR"

    if [[ -s "$PRIVKEY_FILE" && -s "$PUBKEY_FILE" ]]; then
        ok "Existing DNSTT keypair kept."
        return 0
    fi

    info "Generating DNSTT keypair..."
    rm -f "$PRIVKEY_FILE" "$PUBKEY_FILE"
    "$DNSTT_BIN" -gen-key \
        -privkey-file "$PRIVKEY_FILE" \
        -pubkey-file "$PUBKEY_FILE"
    chmod 0400 "$PRIVKEY_FILE"
    chmod 0644 "$PUBKEY_FILE"
    ok "New DNSTT keypair generated."
}

save_config() {
    local tunnel_domain="$1" ns_host="$2" bind_addr="$3"
    local backend_host="$4" backend_port="$5" backend_mode="$6"

    mkdir -p "$BASE_DIR"
    chmod 0700 "$BASE_DIR"
    cat > "$CONFIG_FILE" <<EOF_CONFIG
# OpenCFG DNSTT configuration
# Edit manually if needed, then: systemctl restart opencfg-dnstt
TUNNEL_DOMAIN="${tunnel_domain}"
NS_HOST="${ns_host}"
BIND_ADDR="${bind_addr}"
BACKEND_HOST="${backend_host}"
BACKEND_PORT="${backend_port}"
BACKEND_MODE="${backend_mode}"
PRIVKEY_FILE="${PRIVKEY_FILE}"
PUBKEY_FILE="${PUBKEY_FILE}"
EOF_CONFIG
    chmod 0600 "$CONFIG_FILE"
}

format_backend_addr() {
    local host="$1" port="$2"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

write_runner() {
    mkdir -p "$ENGINE_DIR"
    cat > "$RUNNER_FILE" <<'EOF_RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/opencfg-dnstt/config"
DNSTT_BIN="/usr/local/lib/opencfg-dnstt/dns-server"

[[ -r "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ "$BACKEND_HOST" == *:* && "$BACKEND_HOST" != \[*\] ]]; then
    BACKEND_ADDR="[${BACKEND_HOST}]:${BACKEND_PORT}"
else
    BACKEND_ADDR="${BACKEND_HOST}:${BACKEND_PORT}"
fi

exec "$DNSTT_BIN" \
    -udp "${BIND_ADDR}:53" \
    -privkey-file "${PRIVKEY_FILE}" \
    "${TUNNEL_DOMAIN}" \
    "${BACKEND_ADDR}"
EOF_RUNNER
    chmod 0755 "$RUNNER_FILE"
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=OpenCFG DNSTT Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${RUNNER_FILE}
Restart=always
RestartSec=2
TimeoutStopSec=10
KillSignal=SIGTERM
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload
}

udp53_conflicts() {
    local bind_ip="$1" escaped
    escaped="${bind_ip//./\\.}"
    ss -H -lunp 2>/dev/null | awk '{print $4 " " substr($0,index($0,$5))}' |
        grep -E "^(${escaped}:53|0\\.0\\.0\\.0:53|\\*:53|\\[::\\]:53|:::53)[[:space:]]" || true
}

check_udp53() {
    local conflicts
    conflicts="$(udp53_conflicts "$1")"
    if [[ -n "$conflicts" ]]; then
        warn "UDP/53 is already occupied on ${1}:"
        echo "$conflicts"
        echo "OpenCFG will NOT kill or reconfigure that process."
        return 1
    fi
    return 0
}

check_backend_listener() {
    local host="$1" port="$2"
    if [[ "$host" == "127.0.0.1" || "$host" == "localhost" || "$host" == "::1" ]]; then
        if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])${port}$"; then
            ok "Detected TCP listener on backend port ${port}."
        else
            warn "No local TCP listener detected on port ${port}."
        fi
    fi
}

config_complete() {
    load_config || return 1
    [[ -n "${TUNNEL_DOMAIN:-}" && -n "${NS_HOST:-}" && -n "${BIND_ADDR:-}" &&
       -n "${BACKEND_HOST:-}" && -n "${BACKEND_PORT:-}" && -n "${BACKEND_MODE:-}" ]]
}

configure_interactive() {
    local old_domain="" old_ns="" old_bind="" old_backend_host="127.0.0.1"
    local old_backend_port="" old_mode="" detected_bind
    local tunnel_domain ns_host bind_addr backend_host backend_port backend_mode choice answer

    if load_config 2>/dev/null; then
        old_domain="${TUNNEL_DOMAIN:-}"
        old_ns="${NS_HOST:-}"
        old_bind="${BIND_ADDR:-}"
        old_backend_host="${BACKEND_HOST:-127.0.0.1}"
        old_backend_port="${BACKEND_PORT:-}"
        old_mode="${BACKEND_MODE:-}"
    fi

    detected_bind="$(detect_bind_ipv4)"
    [[ -n "$old_bind" ]] && detected_bind="$old_bind"

    echo
    echo -e "${WHITE}Backend type${NC}"
    echo "  1) SSH / Dropbear"
    echo "  2) Xray / V2Ray / 3x-ui"
    echo "  3) Custom local TCP service"
    echo

    case "$old_mode" in
        SSH) read -r -p "Choose [1]: " choice; choice="${choice:-1}" ;;
        "Xray/V2Ray") read -r -p "Choose [2]: " choice; choice="${choice:-2}" ;;
        *) read -r -p "Choose [2]: " choice; choice="${choice:-2}" ;;
    esac

    case "$choice" in
        1) backend_mode="SSH"; backend_port="${old_backend_port:-22}" ;;
        2) backend_mode="Xray/V2Ray"; backend_port="${old_backend_port:-443}" ;;
        3) backend_mode="Custom"; backend_port="${old_backend_port:-443}" ;;
        *) die "Invalid backend type." ;;
    esac

    while true; do
        read -r -p "Tunnel domain [${old_domain}]: " tunnel_domain
        tunnel_domain="${tunnel_domain:-$old_domain}"; tunnel_domain="${tunnel_domain,,}"
        valid_domain "$tunnel_domain" && break
        warn "Enter a valid tunnel domain, e.g. t.example.com"
    done

    while true; do
        read -r -p "Nameserver host [${old_ns}]: " ns_host
        ns_host="${ns_host:-$old_ns}"; ns_host="${ns_host,,}"
        valid_domain "$ns_host" && break
        warn "Enter a valid nameserver hostname, e.g. ns.example.com"
    done

    while true; do
        read -r -p "Local bind IPv4 for UDP/53 [${detected_bind}]: " bind_addr
        bind_addr="${bind_addr:-$detected_bind}"
        if valid_ipv4 "$bind_addr" && ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$bind_addr"; then
            break
        fi
        warn "Choose an IPv4 address actually assigned to this VPS."
    done

    read -r -p "Backend host [${old_backend_host}]: " backend_host
    backend_host="${backend_host:-$old_backend_host}"

    while true; do
        read -r -p "Backend TCP port [${backend_port}]: " answer
        backend_port="${answer:-$backend_port}"
        valid_port "$backend_port" && break
        warn "Port must be between 1 and 65535."
    done

    save_config "$tunnel_domain" "$ns_host" "$bind_addr" "$backend_host" "$backend_port" "$backend_mode"
    check_backend_listener "$backend_host" "$backend_port"
}

show_info_no_pause() {
    load_config || { warn "DNSTT is not configured yet."; return; }
    local pubkey public_ip engine
    pubkey="$(tr -d '[:space:]' < "$PUBKEY_FILE" 2>/dev/null || true)"
    public_ip="$(detect_public_ipv4)"
    engine="$(cat "$ENGINE_MARKER" 2>/dev/null || echo unknown)"

    echo -e "${BLUE}──────────────────── DNSTT CONFIGURATION ────────────────────${NC}"
    echo -e "Mode            : ${WHITE}${BACKEND_MODE}${NC}"
    echo -e "Tunnel domain   : ${WHITE}${TUNNEL_DOMAIN}${NC}"
    echo -e "Nameserver host : ${WHITE}${NS_HOST}${NC}"
    echo -e "Local UDP bind  : ${WHITE}${BIND_ADDR}:53${NC}"
    echo -e "Backend         : ${WHITE}${BACKEND_HOST}:${BACKEND_PORT}${NC}"
    echo -e "Engine          : ${WHITE}${engine}${NC}"
    echo -e "Public key      : ${WHITE}${pubkey:-Unavailable}${NC}"
    [[ -n "$public_ip" ]] && echo -e "Public IPv4     : ${WHITE}${public_ip}${NC}"
    echo
    echo "DNS delegation:"
    [[ -n "$public_ip" ]] && echo "  A    ${NS_HOST} -> ${public_ip}"
    echo "  NS   ${TUNNEL_DOMAIN} -> ${NS_HOST}"
}

install_or_reconfigure() {
    require_root
    header
    echo -e "${WHITE}Install / Repair OpenCFG DNSTT${NC}"
    echo
    echo "No firewall, rc.local, resolver, SSH, Webmin, Nginx, Xray or OpenVPN changes are made."
    echo

    install_dependencies
    install_self

    # Stop only our own service before replacing/repairing its engine.
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    install_engine
    generate_keys_if_needed

    if config_complete; then
        echo
        echo "Existing OpenCFG DNSTT configuration found:"
        echo "  Tunnel  : ${TUNNEL_DOMAIN}"
        echo "  Bind    : ${BIND_ADDR}:53/udp"
        echo "  Backend : ${BACKEND_HOST}:${BACKEND_PORT}"
        echo
        read -r -p "Keep this configuration and only repair/upgrade the engine? [Y/n]: " answer
        if [[ "${answer:-Y}" =~ ^[Nn]$ ]]; then
            configure_interactive
        else
            ok "Existing configuration kept."
        fi
    else
        configure_interactive
    fi

    write_runner
    write_service
    load_config

    check_backend_listener "$BACKEND_HOST" "$BACKEND_PORT"
    check_udp53 "$BIND_ADDR" || {
        warn "Configuration is saved, but service was not started because UDP/53 is occupied."
        return 0
    }

    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"
    sleep 1

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "OpenCFG DNSTT is running."
    else
        warn "DNSTT failed to stay active. Recent logs:"
        journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
        return 0
    fi

    echo
    show_info_no_pause
}

service_state() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${GREEN}ACTIVE${NC}"
    elif [[ -f "$SERVICE_FILE" ]]; then
        echo -e "${YELLOW}STOPPED${NC}"
    else
        echo -e "${DIM}NOT INSTALLED${NC}"
    fi
}

show_dashboard() {
    echo -e "  Service : $(service_state)"
    if load_config 2>/dev/null; then
        echo -e "  Mode    : ${WHITE}${BACKEND_MODE:-?}${NC}"
        echo -e "  Domain  : ${WHITE}${TUNNEL_DOMAIN:-?}${NC}"
        echo -e "  Listen  : ${WHITE}${BIND_ADDR:-?}:53/udp${NC}"
        echo -e "  Backend : ${WHITE}${BACKEND_HOST:-?}:${BACKEND_PORT:-?}${NC}"
    fi
    echo -e "  Engine  : ${WHITE}Leitura-compatible pinned DNSTT${NC}"
    echo
    echo -e "${DIM}Firewall untouched | resolver untouched | rc.local untouched${NC}"
    echo
}

show_info() { header; show_info_no_pause; pause; }
status_service() { header; systemctl status "$SERVICE_NAME" --no-pager -l || true; pause; }
show_logs() { header; journalctl -u "$SERVICE_NAME" -n 100 --no-pager || true; pause; }

start_service() {
    require_root
    [[ -f "$SERVICE_FILE" ]] || { warn "DNSTT is not installed."; pause; return; }
    if systemctl is-active --quiet "$SERVICE_NAME"; then ok "Already running."; pause; return; fi
    load_config || { warn "Config missing."; pause; return; }
    check_udp53 "$BIND_ADDR" || { pause; return; }
    systemctl start "$SERVICE_NAME"
    ok "OpenCFG DNSTT started."
    pause
}

restart_service() {
    require_root
    systemctl restart "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" && ok "OpenCFG DNSTT restarted." || warn "Restart failed."
    pause
}

stop_service() {
    require_root
    systemctl stop "$SERVICE_NAME"
    ok "OpenCFG DNSTT stopped."
    pause
}

change_backend() {
    require_root
    load_config || { warn "Install/configure DNSTT first."; pause; return; }
    header
    echo "Current backend: ${BACKEND_HOST}:${BACKEND_PORT}"
    local host port answer
    read -r -p "Backend host [${BACKEND_HOST}]: " host
    host="${host:-$BACKEND_HOST}"
    while true; do
        read -r -p "Backend TCP port [${BACKEND_PORT}]: " answer
        port="${answer:-$BACKEND_PORT}"
        valid_port "$port" && break
        warn "Port must be 1-65535."
    done
    save_config "$TUNNEL_DOMAIN" "$NS_HOST" "$BIND_ADDR" "$host" "$port" "$BACKEND_MODE"
    check_backend_listener "$host" "$port"
    systemctl restart "$SERVICE_NAME"
    ok "Backend changed to ${host}:${port}."
    pause
}

change_domain() {
    require_root
    load_config || { warn "Install/configure DNSTT first."; pause; return; }
    header
    local domain ns
    while true; do
        read -r -p "Tunnel domain [${TUNNEL_DOMAIN}]: " domain
        domain="${domain:-$TUNNEL_DOMAIN}"; domain="${domain,,}"
        valid_domain "$domain" && break
        warn "Invalid domain."
    done
    while true; do
        read -r -p "Nameserver host [${NS_HOST}]: " ns
        ns="${ns:-$NS_HOST}"; ns="${ns,,}"
        valid_domain "$ns" && break
        warn "Invalid domain."
    done
    save_config "$domain" "$ns" "$BIND_ADDR" "$BACKEND_HOST" "$BACKEND_PORT" "$BACKEND_MODE"
    systemctl restart "$SERVICE_NAME"
    ok "DNS names updated."
    pause
}

regenerate_keys() {
    require_root
    header
    echo -e "${YELLOW}This changes the public key used by every client.${NC}"
    read -r -p "Generate new DNSTT keys? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$PRIVKEY_FILE" "$PUBKEY_FILE"
    generate_keys_if_needed
    [[ -f "$CONFIG_FILE" ]] && systemctl restart "$SERVICE_NAME" || true
    show_info_no_pause
    pause
}

repair_engine() {
    require_root
    header
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$ENGINE_MARKER"
    install_dependencies
    install_engine
    write_runner
    write_service
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config
        if check_udp53 "$BIND_ADDR"; then
            systemctl enable "$SERVICE_NAME" >/dev/null
            systemctl restart "$SERVICE_NAME"
        fi
    fi
    ok "Compatibility engine repaired and verified."
    pause
}

diagnostics() {
    require_root
    header
    echo -e "${WHITE}OpenCFG DNSTT diagnostics${NC}"
    echo
    echo "App version : ${APP_VERSION}"
    echo "Engine path : ${DNSTT_BIN}"
    echo "Engine ID   : $(cat "$ENGINE_MARKER" 2>/dev/null || echo missing)"
    if [[ -x "$DNSTT_BIN" ]] && verify_git_blob "$DNSTT_BIN"; then
        ok "Engine Git blob matches pinned working binary."
    else
        warn "Engine binary is missing or does not match the pinned working binary."
    fi
    echo
    systemctl status "$SERVICE_NAME" --no-pager -l || true
    echo
    echo "UDP/53 listeners:"
    ss -lunp | grep -E '(:53[[:space:]]|:53$)' || true
    echo
    if load_config 2>/dev/null; then
        echo "Backend expected: $(format_backend_addr "$BACKEND_HOST" "$BACKEND_PORT")"
        check_backend_listener "$BACKEND_HOST" "$BACKEND_PORT"
    fi
    pause
}

uninstall_manager() {
    require_root
    header
    echo "This removes only OpenCFG DNSTT files/service."
    read -r -p "Uninstall OpenCFG DNSTT? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$ENGINE_DIR" "$BASE_DIR"
    rm -f "$MANAGER_LINK"
    rm -f "$MANAGER_PATH"
    echo "OpenCFG DNSTT removed."
    exit 0
}

menu() {
    require_root
    while true; do
        header
        show_dashboard
        echo -e "${BLUE}[01]${NC} Install / Repair / Reconfigure"
        echo -e "${BLUE}[02]${NC} Show configuration + public key"
        echo -e "${BLUE}[03]${NC} Change backend"
        echo -e "${BLUE}[04]${NC} Change tunnel domain / NS"
        echo -e "${BLUE}[05]${NC} Start DNSTT"
        echo -e "${BLUE}[06]${NC} Restart DNSTT"
        echo -e "${BLUE}[07]${NC} Stop DNSTT"
        echo -e "${BLUE}[08]${NC} Service status"
        echo -e "${BLUE}[09]${NC} Recent logs"
        echo -e "${BLUE}[10]${NC} Regenerate keys"
        echo -e "${BLUE}[11]${NC} Repair compatibility engine"
        echo -e "${BLUE}[12]${NC} Diagnostics"
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
            11) repair_engine ;;
            12) diagnostics ;;
            13) uninstall_manager ;;
            0|00) clear 2>/dev/null || true; exit 0 ;;
            *) warn "Invalid option."; sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --install|install) install_or_reconfigure ;;
    --info|info) require_root; show_info_no_pause ;;
    --start|start) require_root; systemctl start "$SERVICE_NAME" ;;
    --stop|stop) require_root; systemctl stop "$SERVICE_NAME" ;;
    --restart|restart) require_root; systemctl restart "$SERVICE_NAME" ;;
    --status|status) require_root; systemctl status "$SERVICE_NAME" --no-pager -l ;;
    --logs|logs) require_root; journalctl -u "$SERVICE_NAME" -n 100 --no-pager ;;
    --diagnostics|diagnostics) diagnostics ;;
    --help|-h|help)
        cat <<EOF_HELP
${APP_NAME} ${APP_VERSION}
by ${AUTHOR}

Compatibility engine:
  pinned Leitura SlowDNS dns-server Git blob ${ENGINE_GIT_BLOB_SHA1}

Usage:
  opencfg-dnstt                 Open menu
  opencfg-dnstt --install       Install/repair/reconfigure
  opencfg-dnstt --info          Show config/public key
  opencfg-dnstt --status        Service status
  opencfg-dnstt --logs          Recent logs
  opencfg-dnstt --diagnostics   Verify engine/service/listeners
EOF_HELP
        ;;
    "") menu ;;
    *) die "Unknown argument: ${1}. Use --help." ;;
esac
