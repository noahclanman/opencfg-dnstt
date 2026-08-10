#!/usr/bin/env bash
# BUILD-ID: OPENCFG-DNSTT-V1.8.0-NOTRACK-STABLE-20260811
# ==============================================================================
# OpenCFG DNSTT Manager v1.8.0
# by Shinusterben / OpenCFG
#
# Compatibility/stability goal:
#   Match the DNSTT release bundled by the OpenCFG Android client:
#     DNSTT v1.20260501.0
#   and avoid Linux conntrack exhaustion under sustained DNS-tunnel traffic.
#   DNSTT binds directly to the VPS private IPv4 on UDP/53. Incoming/outgoing
#   DNSTT UDP/53 packets are marked NOTRACK, so no NAT REDIRECT and no per-query
#   guest conntrack state is required.
#   The server is built with the same security-pinned KCP/smux/noise dependency
#   versions used by tools/Build-DnsttAndroid.ps1 in OpenCFG-Client-App.
#
# Safety guarantees:
#   - Adds only targeted tagged IPv4 rules for BIND_ADDR:53:
#       raw PREROUTING  udp dport 53 -> NOTRACK
#       raw OUTPUT      udp sport 53 -> NOTRACK
#       INPUT           udp dport 53 -> ACCEPT
#       OUTPUT          udp sport 53 -> ACCEPT
#   - Never flushes/replaces firewall tables and never touches ip6tables/nftables,
#     UFW, firewalld, /etc/rc.local, /etc/resolv.conf, or systemd-resolved.
#   - Does not change/restart SSH, Webmin, Nginx, Xray, OpenVPN, or other VPNs.
#   - Rules are idempotent, tagged OPENCFG-DNSTT*, and removed on stop/uninstall.
#   - Existing OpenCFG DNSTT keys are preserved; incomplete keypairs are never
#     silently replaced.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="OpenCFG DNSTT Manager"
APP_VERSION="1.8.0"
BUILD_ID="OPENCFG-DNSTT-V1.8.0-NOTRACK-STABLE-20260811"
AUTHOR="Shinusterben / OpenCFG"

BASE_DIR="/etc/opencfg-dnstt"
CONFIG_FILE="${BASE_DIR}/config"
PRIVKEY_FILE="${BASE_DIR}/server.key"
PUBKEY_FILE="${BASE_DIR}/server.pub"
LIB_DIR="/usr/local/lib/opencfg-dnstt"
ENGINE_BIN="${LIB_DIR}/dnstt-server"
RUNNER_FILE="${LIB_DIR}/run"
STARTDNS_FILE="${LIB_DIR}/startdns"
RESTARTDNS_FILE="${LIB_DIR}/restartdns"
NET_UP_FILE="${LIB_DIR}/net-up"
NET_DOWN_FILE="${LIB_DIR}/net-down"
SERVICE_FILE="/etc/systemd/system/opencfg-dnstt.service"
SERVICE_NAME="opencfg-dnstt.service"
MANAGER_PATH="/usr/local/sbin/opencfg-dnstt"
MANAGER_LINK="/usr/local/bin/opencfg-dnstt"
ENGINE_MARKER_FILE="${BASE_DIR}/engine"

# Match the OpenCFG Android client's pinned DNSTT source release exactly.
# The dependency pins below mirror tools/Build-DnsttAndroid.ps1 so client and
# server run the same KCP/smux/noise generations instead of mixing 2026 client
# code with a 2021 server runtime.
DNSTT_VERSION="v1.20260501.0"
GO_VERSION="1.26.5"
GO_ROOT="/opt/opencfg-dnstt-go"
GO_BIN="${GO_ROOT}/bin/go"
ENGINE_LABEL="DNSTT ${DNSTT_VERSION} OpenCFG client-matched build"
DNSTT_GO_VERSION="1.25.0"
DNSTT_DEP_NOISE="v1.1.0"
DNSTT_DEP_COMPRESS="v1.18.7"
DNSTT_DEP_UTLS="v1.8.2"
DNSTT_DEP_KCP="v5.6.72"
DNSTT_DEP_SMUX="v1.5.57"
DNSTT_DEP_XCRYPTO="v0.54.0"
DNSTT_DEP_XNET="v0.57.0"
DNSTT_DEP_XSYS="v0.47.0"
DNSTT_DEP_XTEXT="v0.40.0"
DNSTT_DEP_XTIME="v0.14.0"
DNS_LISTEN_PORT="53"
RULE_COMMENT="OPENCFG-DNSTT"
NOTRACK_COMMENT="OPENCFG-DNSTT-NOTRACK"

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
    for c in systemctl ss ip sha256sum awk sed grep wc tr iptables; do
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
    apt-get install -y ca-certificates curl iproute2 coreutils grep sed gawk iptables
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
        *) die "Unsupported CPU architecture for automatic Go bootstrap: $arch" ;;
    esac

    if [[ -x "$GO_BIN" ]]; then
        return 0
    fi

    info "Installing private Go ${GO_VERSION} toolchain for DNSTT build..."
    tmp="$(mktemp -d)"
    tarball="${tmp}/go.tar.gz"
    url="https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"

    if command_exists curl; then
        curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tarball" || die "Could not download Go ${GO_VERSION}."
    else
        wget -O "$tarball" --timeout=20 --tries=3 "$url" || die "Could not download Go ${GO_VERSION}."
    fi
    actual_sha256="$(sha256sum "$tarball" | awk '{print $1}')"
    [[ "$actual_sha256" == "$go_sha256" ]] || { rm -rf "$tmp"; die "Go toolchain checksum verification failed."; }

    rm -rf "$GO_ROOT"
    tar -C "$tmp" -xzf "$tarball"
    mv "$tmp/go" "$GO_ROOT"
    rm -rf "$tmp"
    [[ -x "$GO_BIN" ]] || die "Go toolchain installation failed."
}

engine_is_stable() {
    [[ -x "$ENGINE_BIN" && -r "$ENGINE_MARKER_FILE" ]] || return 1
    [[ "$(tr -d '[:space:]' < "$ENGINE_MARKER_FILE" 2>/dev/null)" == "$DNSTT_VERSION" ]] || return 1
    "$ENGINE_BIN" -h 2>&1 | grep -q -- '-udp' || return 1
}

build_stable_engine() {
    local tmp modjson srcdir builddir gobin module
    if engine_is_stable; then
        ok "Client-matched DNSTT ${DNSTT_VERSION} engine already installed."
        return 0
    fi

    install_private_go
    info "Building client-matched DNSTT ${DNSTT_VERSION} server..."
    tmp="$(mktemp -d)"
    gobin="${tmp}/bin"
    mkdir -p "$gobin"
    module="www.bamsoftware.com/git/dnstt.git@${DNSTT_VERSION}"
    modjson="${tmp}/module.json"

    if ! env GOMODCACHE="${tmp}/modcache" GOPROXY="https://proxy.golang.org,direct" GOTOOLCHAIN="local" \
        "$GO_BIN" mod download -json "$module" > "$modjson"; then
        rm -rf "$tmp"
        die "Could not download DNSTT ${DNSTT_VERSION} source module."
    fi

    srcdir="$(sed -n 's/^[[:space:]]*"Dir":[[:space:]]*"\(.*\)",[[:space:]]*$/\1/p' "$modjson" | head -n1)"
    [[ -n "$srcdir" && -d "$srcdir" ]] || {
        rm -rf "$tmp"
        die "DNSTT source directory was not returned by Go module download."
    }

    builddir="${tmp}/src"
    cp -a "$srcdir" "$builddir"
    chmod -R u+w "$builddir"

    (
        cd "$builddir"

        "$GO_BIN" mod edit "-go=${DNSTT_GO_VERSION}"
        "$GO_BIN" mod edit "-require=github.com/flynn/noise@${DNSTT_DEP_NOISE}"
        "$GO_BIN" mod edit "-require=github.com/klauspost/compress@${DNSTT_DEP_COMPRESS}"
        "$GO_BIN" mod edit "-require=github.com/refraction-networking/utls@${DNSTT_DEP_UTLS}"
        "$GO_BIN" mod edit "-require=github.com/xtaci/kcp-go/v5@${DNSTT_DEP_KCP}"
        "$GO_BIN" mod edit "-require=github.com/xtaci/smux@${DNSTT_DEP_SMUX}"
        "$GO_BIN" mod edit "-require=golang.org/x/crypto@${DNSTT_DEP_XCRYPTO}"
        "$GO_BIN" mod edit "-require=golang.org/x/net@${DNSTT_DEP_XNET}"
        "$GO_BIN" mod edit "-require=golang.org/x/sys@${DNSTT_DEP_XSYS}"
        "$GO_BIN" mod edit "-require=golang.org/x/text@${DNSTT_DEP_XTEXT}"
        "$GO_BIN" mod edit "-require=golang.org/x/time@${DNSTT_DEP_XTIME}"

        env GOMODCACHE="${tmp}/modcache" GOPROXY="https://proxy.golang.org,direct" GOTOOLCHAIN="local" \
            "$GO_BIN" mod tidy

        # Verify the two transport dependencies most important for wire/flow behavior.
        [[ "$(env GOMODCACHE="${tmp}/modcache" "$GO_BIN" list -m -f '{{.Version}}' github.com/xtaci/kcp-go/v5)" == "$DNSTT_DEP_KCP" ]]
        [[ "$(env GOMODCACHE="${tmp}/modcache" "$GO_BIN" list -m -f '{{.Version}}' github.com/xtaci/smux)" == "$DNSTT_DEP_SMUX" ]]

        env GOMODCACHE="${tmp}/modcache" GOPROXY="https://proxy.golang.org,direct" GOTOOLCHAIN="local" \
            "$GO_BIN" build -trimpath -ldflags='-s -w -buildid=' -o "${gobin}/dnstt-server" ./dnstt-server
    ) || {
        rm -rf "$tmp"
        die "DNSTT ${DNSTT_VERSION} client-matched server build failed. Existing engine was not replaced."
    }

    [[ -x "${gobin}/dnstt-server" ]] || {
        rm -rf "$tmp"
        die "Built dnstt-server binary not found."
    }

    mkdir -p "$LIB_DIR" "$BASE_DIR"
    chmod 0755 "$LIB_DIR"
    chmod 0700 "$BASE_DIR"
    install -m 0755 "${gobin}/dnstt-server" "${ENGINE_BIN}.new"
    mv -f "${ENGINE_BIN}.new" "$ENGINE_BIN"
    printf '%s\n' "$DNSTT_VERSION" > "$ENGINE_MARKER_FILE"
    chmod 0644 "$ENGINE_MARKER_FILE"
    rm -rf "$tmp"
    ok "Installed client-matched DNSTT ${DNSTT_VERSION} engine."
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
        echo "  UDP path      : direct $BIND_ADDR:53 (NOTRACK)"
        echo "  VPS IPv4      : $BIND_ADDR"
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

    prompt_value BIND_ADDR "Local VPS IPv4" "${BIND_ADDR:-$def_bind}"
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
        printf 'ENGINE_MODE=%q\n' "client-matched-${DNSTT_VERSION}"
        printf 'LISTEN_MODE=%q\n' "direct-53-notrack"
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
ENGINE_BIN="/usr/local/lib/opencfg-dnstt/dnstt-server"

[[ -r "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
[[ -x "$ENGINE_BIN" ]] || { echo "Missing engine: $ENGINE_BIN" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ "$BACKEND_HOST" == *:* && "$BACKEND_HOST" != \[*\] ]]; then
    BACKEND_ADDR="[${BACKEND_HOST}]:${BACKEND_PORT}"
else
    BACKEND_ADDR="${BACKEND_HOST}:${BACKEND_PORT}"
fi

# Bind directly to the VPS private address on UDP/53.
# No NAT REDIRECT and no forced -mtu flag.
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

    # Convenience commands, without overwriting an unrelated existing file.
    if [[ ! -e /usr/local/bin/startdns || -L /usr/local/bin/startdns ]]; then
        ln -sfn "$STARTDNS_FILE" /usr/local/bin/startdns
    fi
    if [[ ! -e /usr/local/bin/restartdns || -L /usr/local/bin/restartdns ]]; then
        ln -sfn "$RESTARTDNS_FILE" /usr/local/bin/restartdns
    fi
}

write_network_helpers() {
    cat > "$NET_UP_FILE" <<'NETUP'
#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG_FILE="/etc/opencfg-dnstt/config"
COMMENT="OPENCFG-DNSTT"
NOTRACK_COMMENT="OPENCFG-DNSTT-NOTRACK"

command -v iptables >/dev/null 2>&1 || {
    echo "iptables is required for OpenCFG DNSTT firewall isolation" >&2
    exit 1
}
[[ -r "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Remove legacy OpenCFG 53->5300 rules from v1.5-v1.7 only.
while iptables -t nat -C PREROUTING -p udp --dport 53 -m comment --comment "$COMMENT" -j REDIRECT --to-ports 5300 2>/dev/null; do
    iptables -t nat -D PREROUTING -p udp --dport 53 -m comment --comment "$COMMENT" -j REDIRECT --to-ports 5300 || break
done
while iptables -C INPUT -p udp --dport 5300 -m comment --comment "$COMMENT" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p udp --dport 5300 -m comment --comment "$COMMENT" -j ACCEPT || break
done

# DNSTT can generate a high rate of short UDP DNS exchanges. Keep only this
# BIND_ADDR:53 traffic out of guest conntrack to avoid nf_conntrack exhaustion.
iptables -t raw -C PREROUTING -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK 2>/dev/null || \
    iptables -t raw -I PREROUTING 1 -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK

iptables -t raw -C OUTPUT -s "$BIND_ADDR" -p udp --sport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK 2>/dev/null || \
    iptables -t raw -I OUTPUT 1 -s "$BIND_ADDR" -p udp --sport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK

# Accept only the DNSTT socket on the selected VPS address. Insert at the top so
# a later stateful firewall jump cannot drop ctstate UNTRACKED DNS packets.
iptables -C INPUT -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$COMMENT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$COMMENT" -j ACCEPT

iptables -C OUTPUT -s "$BIND_ADDR" -p udp --sport 53 -m comment --comment "$COMMENT" -j ACCEPT 2>/dev/null || \
    iptables -I OUTPUT 1 -s "$BIND_ADDR" -p udp --sport 53 -m comment --comment "$COMMENT" -j ACCEPT
NETUP
    chmod 0755 "$NET_UP_FILE"

    cat > "$NET_DOWN_FILE" <<'NETDOWN'
#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG_FILE="/etc/opencfg-dnstt/config"
COMMENT="OPENCFG-DNSTT"
NOTRACK_COMMENT="OPENCFG-DNSTT-NOTRACK"

if command -v iptables >/dev/null 2>&1 && [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    while iptables -t raw -C PREROUTING -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK 2>/dev/null; do
        iptables -t raw -D PREROUTING -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK || break
    done
    while iptables -t raw -C OUTPUT -s "$BIND_ADDR" -p udp --sport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK 2>/dev/null; do
        iptables -t raw -D OUTPUT -s "$BIND_ADDR" -p udp --sport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK || break
    done
    while iptables -C INPUT -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$COMMENT" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$COMMENT" -j ACCEPT || break
    done
    while iptables -C OUTPUT -s "$BIND_ADDR" -p udp --sport 53 -m comment --comment "$COMMENT" -j ACCEPT 2>/dev/null; do
        iptables -D OUTPUT -s "$BIND_ADDR" -p udp --sport 53 -m comment --comment "$COMMENT" -j ACCEPT || break
    done

    # Also clean legacy tagged v1.5-v1.7 rules if they still exist.
    while iptables -t nat -C PREROUTING -p udp --dport 53 -m comment --comment "$COMMENT" -j REDIRECT --to-ports 5300 2>/dev/null; do
        iptables -t nat -D PREROUTING -p udp --dport 53 -m comment --comment "$COMMENT" -j REDIRECT --to-ports 5300 || break
    done
    while iptables -C INPUT -p udp --dport 5300 -m comment --comment "$COMMENT" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p udp --dport 5300 -m comment --comment "$COMMENT" -j ACCEPT || break
    done
fi
NETDOWN
    chmod 0755 "$NET_DOWN_FILE"
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
ExecStartPre=${NET_UP_FILE}
ExecStart=${RUNNER_FILE}
ExecStopPost=${NET_DOWN_FILE}
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

udp53_bind_conflicts() {
    # Binding BIND_ADDR:53 can coexist with systemd-resolved on 127.0.0.53:53.
    ss -H -lunp 2>/dev/null | awk -v ip="$BIND_ADDR" '
        {
            localaddr=$4
            if (localaddr == ip ":53" || localaddr == "0.0.0.0:53" || localaddr == "*:53" || localaddr == "[::]:53" || localaddr == ":::53")
                print
        }'
}

check_udp53_available() {
    local conflicts
    conflicts="$(udp53_bind_conflicts)"
    if [[ -n "$conflicts" ]]; then
        echo "$conflicts"
        die "UDP/53 on $BIND_ADDR is already occupied. OpenCFG did not modify the conflicting service."
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

    build_stable_engine
    ensure_keypair
    write_config
    write_runner
    write_network_helpers
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
    echo "  Engine          : DNSTT $DNSTT_VERSION client-matched build"
    echo "  Tunnel domain   : $TUNNEL_DOMAIN"
    echo "  UDP path        : direct $BIND_ADDR:53 (NOTRACK)"
    echo "  Backend         : $BACKEND_HOST:$BACKEND_PORT"
    echo "  Public key      : $(tr -d '[:space:]' < "$PUBKEY_FILE")"
    echo
    systemctl --no-pager --full status "$SERVICE_NAME" || true
}

show_status() {
    echo -e "${WHITE}$APP_NAME v$APP_VERSION${NC}"
    echo "Build: $BUILD_ID"
    if engine_is_stable; then
        ok "Client-matched DNSTT $DNSTT_VERSION engine installed."
    else
        warn "Stable engine missing or version marker mismatch."
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
    echo "UDP path      : direct $BIND_ADDR:53 (NOTRACK)"
    echo "VPS IPv4      : $BIND_ADDR"
    echo "Backend       : $BACKEND_HOST:$BACKEND_PORT"
    echo "Public key    : $(tr -d '[:space:]' < "$PUBKEY_FILE" 2>/dev/null || true)"
    echo "Engine        : DNSTT $DNSTT_VERSION"
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

    if engine_is_stable; then
        ok "Engine: client-matched DNSTT $DNSTT_VERSION"
    else
        warn "Stable DNSTT engine/version marker missing"
        fail=1
    fi

    if load_existing_config; then
        ok "Config readable"
        echo "    tunnel=$TUNNEL_DOMAIN"
        echo "    path=direct $BIND_ADDR:53 (NOTRACK)"
        echo "    vps_ipv4=$BIND_ADDR"
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

    listener="$(ss -H -lunp 2>/dev/null | grep -F "${BIND_ADDR}:53" || true)"
    if [[ -n "$listener" ]]; then
        ok "dnstt-server listener present on ${BIND_ADDR}:53/udp"
        echo "    $listener"
    else
        warn "No dnstt-server listener found on ${BIND_ADDR}:53/udp"
        fail=1
    fi

    if iptables -t raw -C PREROUTING -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK 2>/dev/null; then
        ok "Incoming DNSTT UDP/53 is NOTRACK"
    else
        warn "Missing raw PREROUTING NOTRACK rule for ${BIND_ADDR}:53"
        fail=1
    fi

    if iptables -t raw -C OUTPUT -s "$BIND_ADDR" -p udp --sport 53 -m comment --comment "$NOTRACK_COMMENT" -j NOTRACK 2>/dev/null; then
        ok "Outgoing DNSTT UDP/53 is NOTRACK"
    else
        warn "Missing raw OUTPUT NOTRACK rule for ${BIND_ADDR}:53"
        fail=1
    fi

    if iptables -C INPUT -d "$BIND_ADDR" -p udp --dport 53 -m comment --comment "$RULE_COMMENT" -j ACCEPT 2>/dev/null; then
        ok "UDP/53 INPUT allow rule present for $BIND_ADDR"
    else
        warn "Missing UDP/53 INPUT allow rule for $BIND_ADDR"
        fail=1
    fi

    if [[ -r /proc/sys/net/netfilter/nf_conntrack_count && -r /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        local ct_count ct_max
        ct_count="$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
        ct_max="$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
        echo "    guest conntrack: ${ct_count}/${ct_max} entries"
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
        ok "Local checks passed, including direct UDP/53 with DNSTT NOTRACK isolation."
    else
        warn "One or more local server checks failed."
    fi
}

uninstall_opencfg_only() {
    require_root
    echo "This removes only OpenCFG DNSTT files/service and its tagged UDP/53 firewall rules. It will NOT touch other firewall rules, DNS resolver, SSH, Nginx, Xray, Webmin, or other VPN software."
    read -r -p "Continue? [y/N]: " ans || true
    [[ "$ans" =~ ^[Yy]$ ]] || return 0

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    [[ -x "$NET_DOWN_FILE" ]] && "$NET_DOWN_FILE" || true
    rm -f "$SERVICE_FILE" "$MANAGER_LINK" "$MANAGER_PATH" /usr/local/bin/startdns /usr/local/bin/restartdns
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
