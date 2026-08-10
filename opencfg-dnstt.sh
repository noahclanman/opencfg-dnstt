#!/usr/bin/env bash
# BUILD-ID: OPENCFG-DNSTT-V1.4.0-COMPAT-20260810
# ==============================================================================
# OpenCFG DNSTT Manager v1.4.0
# by Shinusterben / OpenCFG
#
# Compatibility goal:
#   Use the exact known-working dns-server binary revision used by the
#   leitura/slowdns setup, but manage it safely with systemd and bind directly
#   to the selected local IPv4 address on UDP/53.
#
# Safety guarantees:
#   - No iptables/ip6tables/nftables/UFW/firewalld changes.
#   - No /etc/rc.local changes.
#   - No /etc/resolv.conf or systemd-resolved changes.
#   - No SSH/Webmin/Nginx/Xray/OpenVPN changes or restarts.
#   - Existing OpenCFG DNSTT keys are preserved; incomplete keypairs are never
#     silently replaced.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="OpenCFG DNSTT Manager"
APP_VERSION="1.4.0"
BUILD_ID="OPENCFG-DNSTT-V1.4.0-COMPAT-20260810"
AUTHOR="Shinusterben / OpenCFG"

BASE_DIR="/etc/opencfg-dnstt"
CONFIG_FILE="${BASE_DIR}/config"
PRIVKEY_FILE="${BASE_DIR}/server.key"
PUBKEY_FILE="${BASE_DIR}/server.pub"
LIB_DIR="/usr/local/lib/opencfg-dnstt"
ENGINE_BIN="${LIB_DIR}/dns-server"
RUNNER_FILE="${LIB_DIR}/run"
STARTDNS_FILE="${LIB_DIR}/startdns"
RESTARTDNS_FILE="${LIB_DIR}/restartdns"
SERVICE_FILE="/etc/systemd/system/opencfg-dnstt.service"
SERVICE_NAME="opencfg-dnstt.service"
MANAGER_PATH="/usr/local/sbin/opencfg-dnstt"
MANAGER_LINK="/usr/local/bin/opencfg-dnstt"
ENGINE_MARKER_FILE="${BASE_DIR}/engine"

# Exact leitura/slowdns binary revision that was already present in May 2021.
# We verify the Git blob SHA-1 over the downloaded bytes before installation.
ENGINE_REPO="leitura/slowdns"
ENGINE_COMMIT="9b25d1d56e4723be3c445ba6186d33b0ff7c74d9"
ENGINE_GIT_BLOB_SHA1="af32b882a18040af0a6e16ea759ca6fcc511b965"
ENGINE_URL_1="https://raw.githubusercontent.com/${ENGINE_REPO}/${ENGINE_COMMIT}/dns-server"
ENGINE_URL_2="https://github.com/${ENGINE_REPO}/raw/${ENGINE_COMMIT}/dns-server"
ENGINE_LABEL="leitura-compatible exact binary"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."
}

pause() {
    echo
    read -r -p "Press Enter to continue..." _ || true
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_runtime_tools() {
    local missing=()
    local c
    for c in systemctl ss ip sha1sum awk sed grep wc tr; do
        command_exists "$c" || missing+=("$c")
    done

    if ! command_exists curl && ! command_exists wget; then
        missing+=("curl-or-wget")
    fi

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    command_exists apt-get || die "Missing required tools: ${missing[*]}. Install them first."
    info "Installing only required runtime packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl iproute2 coreutils grep sed gawk
}

git_blob_sha1() {
    local file="$1" size
    size="$(wc -c < "$file" | tr -d '[:space:]')"
    { printf 'blob %s\0' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

download_file() {
    local url="$1" out="$2"
    if command_exists curl; then
        curl -fL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 180 "$url" -o "$out"
    else
        wget -O "$out" --timeout=20 --tries=3 "$url"
    fi
}

engine_is_exact() {
    [[ -f "$ENGINE_BIN" ]] || return 1
    local got
    got="$(git_blob_sha1 "$ENGINE_BIN" 2>/dev/null || true)"
    [[ "$got" == "$ENGINE_GIT_BLOB_SHA1" ]]
}

install_compat_engine() {
    local arch tmp got
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) ;;
        *) die "The exact compatibility engine is Linux x86_64 only; detected: $arch. Refusing to install a guessed replacement." ;;
    esac

    mkdir -p "$LIB_DIR" "$BASE_DIR"
    chmod 0755 "$LIB_DIR"
    chmod 0700 "$BASE_DIR"

    if engine_is_exact; then
        ok "Exact compatibility engine already installed."
        printf '%s\n' "${ENGINE_REPO}@${ENGINE_COMMIT} blob=${ENGINE_GIT_BLOB_SHA1}" > "$ENGINE_MARKER_FILE"
        chmod 0644 "$ENGINE_MARKER_FILE"
        return 0
    fi

    info "Downloading pinned compatibility engine..."
    tmp="$(mktemp "${LIB_DIR}/.dns-server.XXXXXX")"
    trap 'rm -f "${tmp:-}"' RETURN

    if ! download_file "$ENGINE_URL_1" "$tmp"; then
        warn "Primary GitHub raw download failed; trying fallback URL."
        download_file "$ENGINE_URL_2" "$tmp" || die "Could not download compatibility engine."
    fi

    [[ -s "$tmp" ]] || die "Downloaded engine is empty."
    got="$(git_blob_sha1 "$tmp")"
    [[ "$got" == "$ENGINE_GIT_BLOB_SHA1" ]] || {
        rm -f "$tmp"
        die "Engine verification failed. Expected Git blob ${ENGINE_GIT_BLOB_SHA1}, got ${got}. Nothing was installed."
    }

    chmod 0755 "$tmp"
    mv -f "$tmp" "$ENGINE_BIN"
    trap - RETURN

    printf '%s\n' "${ENGINE_REPO}@${ENGINE_COMMIT} blob=${ENGINE_GIT_BLOB_SHA1}" > "$ENGINE_MARKER_FILE"
    chmod 0644 "$ENGINE_MARKER_FILE"
    ok "Installed verified compatibility engine: $ENGINE_BIN"
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

load_existing_config() {
    [[ -r "$CONFIG_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    : "${TUNNEL_DOMAIN:=}"
    : "${NAMESERVER_HOST:=}"
    : "${BIND_ADDR:=}"
    : "${BACKEND_HOST:=}"
    : "${BACKEND_PORT:=}"
    [[ -n "$TUNNEL_DOMAIN" && -n "$BIND_ADDR" && -n "$BACKEND_HOST" && -n "$BACKEND_PORT" ]]
}

default_bind_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

valid_domain() {
    local s="$1"
    [[ "$s" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$s" == *.* ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_bind_ip() {
    local ip4="$1"
    ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$ip4"
}

prompt_value() {
    local __var="$1" label="$2" def="$3" value
    read -r -p "$label [$def]: " value || true
    value="${value:-$def}"
    printf -v "$__var" '%s' "$value"
}

collect_config() {
    local keep="" def_bind

    if load_existing_config; then
        echo
        echo -e "${WHITE}Existing OpenCFG DNSTT configuration:${NC}"
        echo "  Tunnel domain : $TUNNEL_DOMAIN"
        echo "  NS host       : ${NAMESERVER_HOST:-<not set>}"
        echo "  UDP bind      : $BIND_ADDR:53"
        echo "  Backend       : $BACKEND_HOST:$BACKEND_PORT"
        echo
        read -r -p "Keep these settings and repair/upgrade only? [Y/n]: " keep || true
        if [[ ! "$keep" =~ ^[Nn]$ ]]; then
            return 0
        fi
    fi

    def_bind="$(default_bind_ip)"
    [[ -n "$def_bind" ]] || def_bind="127.0.0.1"

    echo
    echo "Backend type"
    echo "  1) SSH / Dropbear"
    echo "  2) Xray / V2Ray / 3x-ui"
    echo "  3) Custom local TCP service"
    read -r -p "Choose [2]: " BACKEND_MODE || true
    BACKEND_MODE="${BACKEND_MODE:-2}"

    prompt_value TUNNEL_DOMAIN "Tunnel domain (example: t.example.com)" "${TUNNEL_DOMAIN:-t.example.com}"
    valid_domain "$TUNNEL_DOMAIN" || die "Invalid tunnel domain: $TUNNEL_DOMAIN"

    prompt_value NAMESERVER_HOST "Nameserver host (example: ns.example.com)" "${NAMESERVER_HOST:-ns.example.com}"
    valid_domain "$NAMESERVER_HOST" || die "Invalid nameserver host: $NAMESERVER_HOST"

    prompt_value BIND_ADDR "Local bind IPv4 for UDP/53" "${BIND_ADDR:-$def_bind}"
    valid_bind_ip "$BIND_ADDR" || die "$BIND_ADDR is not configured on this VPS."

    prompt_value BACKEND_HOST "Backend host" "${BACKEND_HOST:-127.0.0.1}"
    [[ "$BACKEND_HOST" != *[[:space:]]* && -n "$BACKEND_HOST" ]] || die "Invalid backend host."

    local default_port
    case "$BACKEND_MODE" in
        1) default_port="${BACKEND_PORT:-22}" ;;
        *) default_port="${BACKEND_PORT:-443}" ;;
    esac
    prompt_value BACKEND_PORT "Backend TCP port" "$default_port"
    valid_port "$BACKEND_PORT" || die "Invalid TCP port: $BACKEND_PORT"
}

write_config() {
    mkdir -p "$BASE_DIR"
    chmod 0700 "$BASE_DIR"
    {
        printf 'TUNNEL_DOMAIN=%q\n' "$TUNNEL_DOMAIN"
        printf 'NAMESERVER_HOST=%q\n' "${NAMESERVER_HOST:-}"
        printf 'BIND_ADDR=%q\n' "$BIND_ADDR"
        printf 'BACKEND_HOST=%q\n' "$BACKEND_HOST"
        printf 'BACKEND_PORT=%q\n' "$BACKEND_PORT"
        printf 'PRIVKEY_FILE=%q\n' "$PRIVKEY_FILE"
        printf 'PUBKEY_FILE=%q\n' "$PUBKEY_FILE"
        printf 'ENGINE_MODE=%q\n' "compat-exact"
    } > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
}

ensure_keypair() {
    if [[ -s "$PRIVKEY_FILE" && -s "$PUBKEY_FILE" ]]; then
        ok "Existing DNSTT keypair kept unchanged."
        return 0
    fi

    if [[ -e "$PRIVKEY_FILE" || -e "$PUBKEY_FILE" ]]; then
        die "Incomplete DNSTT keypair detected. Refusing to silently replace it. Restore both server.key and server.pub, or remove both only if you intentionally want a new keypair."
    fi

    info "Generating DNSTT keypair with compatibility engine..."
    "$ENGINE_BIN" -gen-key -privkey-file "$PRIVKEY_FILE" -pubkey-file "$PUBKEY_FILE"
    chmod 0400 "$PRIVKEY_FILE"
    chmod 0644 "$PUBKEY_FILE"
    ok "New DNSTT keypair generated."
}

backend_addr_expr() {
    local host="$1" port="$2"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

write_runner() {
    mkdir -p "$LIB_DIR"
    cat > "$RUNNER_FILE" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG_FILE="/etc/opencfg-dnstt/config"
ENGINE_BIN="/usr/local/lib/opencfg-dnstt/dns-server"

[[ -r "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
[[ -x "$ENGINE_BIN" ]] || { echo "Missing engine: $ENGINE_BIN" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ "$BACKEND_HOST" == *:* && "$BACKEND_HOST" != \[*\] ]]; then
    BACKEND_ADDR="[${BACKEND_HOST}]:${BACKEND_PORT}"
else
    BACKEND_ADDR="${BACKEND_HOST}:${BACKEND_PORT}"
fi

# Intentionally no -mtu flag: match the known-working compatibility launch.
exec "$ENGINE_BIN" \
    -udp "${BIND_ADDR}:53" \
    -privkey-file "$PRIVKEY_FILE" \
    "$TUNNEL_DOMAIN" \
    "$BACKEND_ADDR"
RUNNER
    chmod 0755 "$RUNNER_FILE"

    cat > "$STARTDNS_FILE" <<'EOF_START'
#!/usr/bin/env bash
set -e
systemctl start opencfg-dnstt.service
systemctl --no-pager --full status opencfg-dnstt.service
EOF_START
    chmod 0755 "$STARTDNS_FILE"

    cat > "$RESTARTDNS_FILE" <<'EOF_RESTART'
#!/usr/bin/env bash
set -e
systemctl restart opencfg-dnstt.service
systemctl --no-pager --full status opencfg-dnstt.service
EOF_RESTART
    chmod 0755 "$RESTARTDNS_FILE"
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
KillMode=control-group
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload
}

udp53_conflicts() {
    local ip="$1" escaped
    escaped="${ip//./\\.}"
    ss -H -lunp 2>/dev/null | grep -E "[[:space:]](${escaped}:53|0\.0\.0\.0:53|\*:53|\[::\]:53|:::53)[[:space:]]" || true
}

check_udp53_available() {
    local conflicts
    conflicts="$(udp53_conflicts "$BIND_ADDR")"
    if [[ -n "$conflicts" ]]; then
        echo "$conflicts"
        die "UDP/53 is already occupied on $BIND_ADDR (or a wildcard listener). OpenCFG did not modify the conflicting service."
    fi
}

install_or_repair() {
    require_root
    ensure_runtime_tools
    install_self
    collect_config

    if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
        info "Stopping only the existing OpenCFG DNSTT service for repair..."
        systemctl stop "$SERVICE_NAME" || true
    fi

    # Validate the selected bind address after stopping only our own service.
    valid_bind_ip "$BIND_ADDR" || die "$BIND_ADDR is not configured on this VPS."
    check_udp53_available

    install_compat_engine
    ensure_keypair
    write_config
    write_runner
    write_service

    systemctl enable "$SERVICE_NAME" >/dev/null
    if ! systemctl restart "$SERVICE_NAME"; then
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
        die "OpenCFG DNSTT failed to start."
    fi

    sleep 1
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
        die "OpenCFG DNSTT is not active after startup."
    fi

    echo
    ok "OpenCFG DNSTT installed/repaired."
    echo "  Manager version : $APP_VERSION"
    echo "  Build ID        : $BUILD_ID"
    echo "  Engine          : exact compatibility blob $ENGINE_GIT_BLOB_SHA1"
    echo "  Tunnel domain   : $TUNNEL_DOMAIN"
    echo "  UDP listener    : $BIND_ADDR:53"
    echo "  Backend         : $BACKEND_HOST:$BACKEND_PORT"
    echo "  Public key      : $(tr -d '[:space:]' < "$PUBKEY_FILE")"
    echo
    systemctl --no-pager --full status "$SERVICE_NAME" || true
}

show_status() {
    echo -e "${WHITE}$APP_NAME v$APP_VERSION${NC}"
    echo "Build: $BUILD_ID"
    if engine_is_exact; then
        ok "Engine bytes match pinned compatibility blob."
    else
        warn "Engine is missing or does not match pinned compatibility blob."
    fi
    echo
    systemctl --no-pager --full status "$SERVICE_NAME" || true
}

show_config() {
    if ! load_existing_config; then
        die "No valid OpenCFG DNSTT config found."
    fi
    echo "Tunnel domain : $TUNNEL_DOMAIN"
    echo "NS host       : ${NAMESERVER_HOST:-}"
    echo "UDP bind      : $BIND_ADDR:53"
    echo "Backend       : $BACKEND_HOST:$BACKEND_PORT"
    echo "Public key    : $(tr -d '[:space:]' < "$PUBKEY_FILE" 2>/dev/null || true)"
    echo "Engine blob   : $ENGINE_GIT_BLOB_SHA1"
    echo
    echo "Actual launch command:"
    sed -n '/^exec "\$ENGINE_BIN"/,/"\$BACKEND_ADDR"/p' "$RUNNER_FILE" 2>/dev/null || true
}

restart_service() {
    systemctl restart "$SERVICE_NAME"
    sleep 1
    systemctl --no-pager --full status "$SERVICE_NAME"
}

stop_service() {
    systemctl stop "$SERVICE_NAME"
    ok "OpenCFG DNSTT stopped."
}

start_service() {
    systemctl start "$SERVICE_NAME"
    sleep 1
    systemctl --no-pager --full status "$SERVICE_NAME"
}

show_logs() {
    journalctl -u "$SERVICE_NAME" -n 120 --no-pager
}

diagnostics() {
    require_root
    local fail=0 listener="" logged_pub="" file_pub=""
    echo -e "${WHITE}OpenCFG DNSTT diagnostics${NC}"
    echo "Build: $BUILD_ID"
    echo

    if engine_is_exact; then
        ok "Engine hash: exact pinned compatibility binary"
    else
        warn "Engine hash mismatch/missing"
        fail=1
    fi

    if load_existing_config; then
        ok "Config readable"
        echo "    tunnel=$TUNNEL_DOMAIN"
        echo "    bind=$BIND_ADDR:53"
        echo "    backend=$BACKEND_HOST:$BACKEND_PORT"
    else
        warn "Config missing/invalid"
        fail=1
    fi

    if [[ -s "$PRIVKEY_FILE" && -s "$PUBKEY_FILE" ]]; then
        ok "Keypair files exist"
    else
        warn "Keypair incomplete/missing"
        fail=1
    fi

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "systemd service active"
    else
        warn "systemd service not active"
        fail=1
    fi

    if [[ -n "${BIND_ADDR:-}" ]]; then
        listener="$(ss -H -lunp 2>/dev/null | grep -F "${BIND_ADDR}:53" || true)"
        if [[ -n "$listener" ]]; then
            ok "UDP/53 listener present on $BIND_ADDR"
            echo "    $listener"
        else
            warn "No UDP/53 listener found on $BIND_ADDR"
            fail=1
        fi
    fi

    file_pub="$(tr -d '[:space:]' < "$PUBKEY_FILE" 2>/dev/null || true)"
    logged_pub="$(journalctl -u "$SERVICE_NAME" -n 120 --no-pager 2>/dev/null | sed -nE 's/.*pubkey[[:space:]]+([0-9a-fA-F]{64}).*/\1/p' | tail -n1 | tr 'A-F' 'a-f')"
    file_pub="$(printf '%s' "$file_pub" | tr 'A-F' 'a-f')"
    if [[ -n "$logged_pub" ]]; then
        if [[ "$logged_pub" == "$file_pub" ]]; then
            ok "Running server public key matches $PUBKEY_FILE"
        else
            warn "PUBLIC KEY MISMATCH: running server=$logged_pub file=$file_pub"
            fail=1
        fi
    else
        warn "Could not read server pubkey from recent journal logs"
    fi

    if [[ -n "${BACKEND_HOST:-}" && -n "${BACKEND_PORT:-}" ]]; then
        if command_exists timeout && timeout 3 bash -c "</dev/tcp/${BACKEND_HOST}/${BACKEND_PORT}" >/dev/null 2>&1; then
            ok "Backend TCP port accepts a local connection"
        else
            warn "Backend TCP probe could not connect to ${BACKEND_HOST}:${BACKEND_PORT}. This may be expected for some services, but verify the backend is listening."
        fi
    fi

    echo
    echo "Recent DNSTT logs:"
    journalctl -u "$SERVICE_NAME" -n 25 --no-pager 2>/dev/null || true
    echo
    if ((fail == 0)); then
        ok "Local server checks passed. This proves the engine/service/key/listener are internally consistent; it does not by itself prove recursive DNS delegation from the phone."
    else
        warn "One or more local server checks failed."
    fi
}

uninstall_opencfg_only() {
    require_root
    echo "This removes only OpenCFG DNSTT files/service. It will NOT touch firewall, DNS resolver, SSH, Nginx, Xray, Webmin, or other VPN software."
    read -r -p "Continue? [y/N]: " ans || true
    [[ "$ans" =~ ^[Yy]$ ]] || return 0

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$MANAGER_LINK" "$MANAGER_PATH"
    rm -rf "$LIB_DIR"
    # Keep config/keypair by default to prevent accidental client breakage.
    systemctl daemon-reload
    ok "OpenCFG DNSTT service/binaries removed. Keys/config kept in $BASE_DIR."
}

menu() {
    require_root
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${WHITE}  OpenCFG DNSTT Manager v${APP_VERSION}${NC}"
        echo -e "  ${DIM}${BUILD_ID}${NC}"
        echo -e "${CYAN}============================================================${NC}"
        echo " 1) Install / Repair / Reconfigure"
        echo " 2) Status"
        echo " 3) Restart"
        echo " 4) Start"
        echo " 5) Stop"
        echo " 6) Logs"
        echo " 7) Show config / actual launch"
        echo " 8) Diagnostics"
        echo " 9) Uninstall OpenCFG service/binaries only"
        echo " 0) Exit"
        echo
        read -r -p "Choose: " choice || exit 0
        case "$choice" in
            1) install_or_repair; pause ;;
            2) show_status; pause ;;
            3) restart_service; pause ;;
            4) start_service; pause ;;
            5) stop_service; pause ;;
            6) show_logs; pause ;;
            7) show_config; pause ;;
            8) diagnostics; pause ;;
            9) uninstall_opencfg_only; pause ;;
            0) exit 0 ;;
            *) warn "Invalid option"; sleep 1 ;;
        esac
    done
}

require_root
menu
