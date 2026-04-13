#!/bin/sh
# =============================================================================
# SBSM (Sing-Box Subscription Manager) - Podkop Edition
# Description: Manage proxy subscriptions for Sing-Box + Podkop on OpenWRT
# Version: 0.5.1
# =============================================================================

# =============================================================================
# A. Configuration & Globals
# =============================================================================

# Paths (configurable via environment or defaults)
SBSM_CONF_DIR="${SBSM_CONF_DIR:-/etc/sing-box}"
SBSM_DB_FILE="$SBSM_CONF_DIR/sbsm.json"
SBSM_SUBS_FILE="$SBSM_CONF_DIR/sbsm.subs"
SBSM_CONFIG_FILE="$SBSM_CONF_DIR/config.json"
PODKOP_CONFIG="${PODKOP_CONFIG:-/etc/config/podkop}"

# Performance settings
PROXY_TEST_TIMEOUT="${PROXY_TEST_TIMEOUT:-3}"

# Logging
SBSM_LOG_LEVEL="${SBSM_LOG_LEVEL:-info}"
SBSM_LOG_FILE="${SBSM_LOG_FILE:-/var/log/sbsm.log}"

# Temp file tracking
SBSM_TEMP_FILES=""

# Colors (POSIX-compatible ANSI escape codes)
GREEN="\033[1;32m"; RED="\033[1;31m"; CYAN="\033[1;36m"
YELLOW="\033[1;33m"; MAGENTA="\033[1;35m"; BLUE="\033[0;34m"
DGRAY="\033[38;5;244m"; NC="\033[0m"

# =============================================================================
# B. Core Utilities
# =============================================================================

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Try to log to file if writable
    if [ -w "$(dirname "$SBSM_LOG_FILE")" ] 2>/dev/null; then
        printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >> "$SBSM_LOG_FILE" 2>/dev/null
    fi
    
    # Console output based on level
    case "$level" in
        error)
            printf '%s: %s\n' "$level" "$message" >&2
            ;;
        warn)
            printf '%s: %s\n' "$level" "$message" >&2
            ;;
        info)
            printf '%s: %s\n' "$level" "$message" >&2
            ;;
        debug)
            [ "$SBSM_LOG_LEVEL" = "debug" ] && printf '%s: %s\n' "$level" "$message" >&2
            ;;
    esac
}

log_error() { log_message "error" "$1"; }
log_warn() { log_message "warn" "$1"; }
log_info() { log_message "info" "$1"; }
log_debug() { log_message "debug" "$1"; }

create_temp_file() {
    local temp_file
    temp_file=$(mktemp /tmp/sbsm.XXXXXX 2>/dev/null) || {
        # Fallback if mktemp fails
        temp_file="/tmp/sbsm.$$.$(date +%s)"
    }
    chmod 600 "$temp_file" 2>/dev/null
    SBSM_TEMP_FILES="$SBSM_TEMP_FILES $temp_file"
    printf '%s' "$temp_file"
}

cleanup_temp_files() {
    for f in $SBSM_TEMP_FILES; do
        rm -f "$f" 2>/dev/null
    done
    SBSM_TEMP_FILES=""
}

validate_url() {
    local url="$1"
    [ -z "$url" ] && return 1
    
    case "$url" in
        http://*|https://*) ;;
        *) return 1 ;;
    esac
    
    # Basic shell injection prevention
    if printf '%s' "$url" | grep -qE '[;&|`$()]'; then
        log_error "URL contains invalid characters"
        return 1
    fi
    
    # Rough pattern check
    if ! printf '%s' "$url" | grep -qE '^https?://[A-Za-z0-9.-]+(/.*)?$'; then
        return 1
    fi
    return 0
}

# =============================================================================
# C. Initialization & Dependencies
# =============================================================================

dependency_check() {
    local missing=""
    local cmd
    for cmd in jq wget curl grep sed awk base64; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    
    if [ -n "$missing" ]; then
        log_error "Missing required tools:$missing"
        echo -e "${RED}Error: Missing dependencies:${NC}$missing"
        echo "Please install: opkg update && opkg install jq wget curl grep sed gawk coreutils-base64"
        return 1
    fi
    return 0
}

# Config File Management (INI style for BusyBox)
SBSM_CONF_FILE="${SBSM_CONF_FILE:-/etc/sing-box/sbsm.conf}"

cfg_get_raw() {
    local section="$1" key="$2"
    [ -f "$SBSM_CONF_FILE" ] && awk -v sec="$section" -v k="$key" '
        /^\[/ { cur = substr($0, 2, length($0)-2); in_sec = (cur == sec); next }
        in_sec && index($0, "=") > 0 {
            idx = index($0, "="); ck = substr($0, 1, idx-1); gsub(/[[:space:]]/, "", ck)
            if (ck == k) { print substr($0, idx+1); exit }
        }
    ' "$SBSM_CONF_FILE" 2>/dev/null
}

cfg_get() { local v; v=$(cfg_get_raw "$1" "$2"); printf '%s' "${v:-$3}"; }

cfg_set() {
    local section="$1" key="$2" value="$3" tmp="${SBSM_CONF_FILE}.tmp"
    [ ! -f "$SBSM_CONF_FILE" ] && { printf '[%s]\n%s=%s\n' "$section" "$key" "$value" > "$SBSM_CONF_FILE"; return 0; }
    grep -q "^\[$section\]$" "$SBSM_CONF_FILE" 2>/dev/null || { printf '\n[%s]\n%s=%s\n' "$section" "$key" "$value" >> "$SBSM_CONF_FILE"; return 0; }
    # Check if key exists within THIS section only
    local key_in_section=0
    key_in_section=$(awk -v sec="$section" -v k="$key" '
        /^\[/ { cur = substr($0, 2, length($0)-2); in_sec = (cur == sec); next }
        in_sec && index($0, "=") > 0 {
            idx = index($0, "="); ck = substr($0, 1, idx-1); gsub(/[[:space:]]/, "", ck)
            if (ck == k) { print 1; exit }
        }
    ' "$SBSM_CONF_FILE" 2>/dev/null)
    if [ "$key_in_section" = "1" ]; then
        awk -v sec="$section" -v k="$key" -v v="$value" '
            /^\[/ { cur = substr($0, 2, length($0)-2); in_sec = (cur == sec) }
            in_sec && index($0, "=") > 0 {
                idx = index($0, "="); ck = substr($0, 1, idx-1); gsub(/[[:space:]]/, "", ck)
                if (ck == k) { printf "%s=%s\n", k, v; next }
            }
            { print }
        ' "$SBSM_CONF_FILE" > "$tmp" && mv "$tmp" "$SBSM_CONF_FILE"
    else
        # Key not in section — append after section header
        awk -v sec="$section" -v k="$key" -v v="$value" '
            { print }
            /^\[/ { cur = substr($0, 2, length($0)-2) }
            cur == sec && !done { print k "=" v; done = 1 }
        ' "$SBSM_CONF_FILE" > "$tmp" && mv "$tmp" "$SBSM_CONF_FILE"
    fi
}

cfg_init() {
    [ -f "$SBSM_CONF_FILE" ] && return 0
    cat > "$SBSM_CONF_FILE" <<'EOF'
[sbsm_podkop]
mode=by_country
check_url=https://www.gstatic.com/generate_204
check_mode=all

[sbsm_extended]
mode=by_country
sb_mode=tun
check_url=https://www.gstatic.com/generate_204
check_mode=all
EOF
}

init_config() {
    cfg_init 2>/dev/null
    mkdir -p "$SBSM_CONF_DIR" 2>/dev/null
    [ ! -f "$SBSM_DB_FILE" ] && echo "[]" > "$SBSM_DB_FILE"
    [ ! -f "$SBSM_SUBS_FILE" ] && touch "$SBSM_SUBS_FILE"
    return 0
}

get_mode() { cfg_get "sbsm_podkop" "mode" "by_country"; }
set_mode() { cfg_set "sbsm_podkop" "mode" "$1"; }
get_check_url() { cfg_get "sbsm_podkop" "check_url" "https://www.gstatic.com/generate_204"; }
set_check_url() { cfg_set "sbsm_podkop" "check_url" "$1"; }
get_check_mode() { cfg_get "sbsm_podkop" "check_mode" "all"; }
set_check_mode() {
    case "$1" in
        fastest|5|10|20|all) cfg_set "sbsm_podkop" "check_mode" "$1" ;;
        *) log_error "Invalid check_mode: $1 (use: fastest, 5, 10, 20, all)"; return 1 ;;
    esac
}

restart_target() {
    if [ -x "/etc/init.d/podkop" ]; then
        log_info "Restarting Podkop..."
        echo -e "${CYAN}Restarting Podkop...${NC}"
        /etc/init.d/podkop restart 2>/dev/null
        return $?
    fi
    log_warn "Podkop init script NOT found"
    return 1
}

# =============================================================================
# D. Proxy URL Validation
# =============================================================================

# validate_proxy_link() - Main router for proxy URL validation
# Arguments: $1=proxy URL
# Returns: 0=valid, 1=invalid
validate_proxy_link() {
    local url="$1"
    
    # Basic cleanup
    url=$(printf '%s' "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$url" ] && return 1
    
    # Protocol detection
    case "$url" in
        vless://*)       validate_vless_url "$url" ;;
        ss://*)          validate_ss_url "$url" ;;
        trojan://*)      validate_trojan_url "$url" ;;
        socks5://*|socks4://*|socks4a://*) validate_socks_url "$url" ;;
        hy2://*|hysteria2://*) validate_hy2_url "$url" ;;
        *)               log_debug "Unsupported protocol: ${url%%://*}"; return 1 ;;
    esac
}

# validate_vless_url() - Validate VLESS URL
# Format: vless://{uuid}@{host}:{port}?{query_params}#[fragment]
validate_vless_url() {
    local url="$1"
    local body main_part query_part user_host_port user_part host_port host port port_num
    
    body="${url#vless://}"
    
    # Remove fragment
    main_part="${body%%#*}"
    
    # Split host:port and query
    query_part=$(printf '%s' "$main_part" | grep -oE '[?].*$' || true)
    user_host_port=$(printf '%s' "$main_part" | sed 's/[?].*//')
    
    if [ -z "$user_host_port" ]; then
        log_debug "VLESS: missing host/UUID"
        return 1
    fi
    
    # Check for @ separator
    if ! printf '%s' "$user_host_port" | grep -q '@'; then
        log_debug "VLESS: missing @ separator"
        return 1
    fi
    
    user_part=$(printf '%s' "$user_host_port" | sed 's/@.*//')
    host_port=$(printf '%s' "$user_host_port" | sed 's|.*@||')
    
    if [ -z "$user_part" ]; then
        log_debug "VLESS: missing UUID/user"
        return 1
    fi
    
    if [ -z "$host_port" ]; then
        log_debug "VLESS: missing server host and port"
        return 1
    fi
    
    # Parse host:port
    host=$(printf '%s' "$host_port" | cut -d: -f1)
    port=$(printf '%s' "$host_port" | cut -d: -f2 | sed 's/\/.*//')
    
    if [ -z "$host" ]; then
        log_debug "VLESS: missing hostname or IP"
        return 1
    fi
    
    if [ -z "$port" ]; then
        log_debug "VLESS: missing port"
        return 1
    fi
    
    # Validate port is a number
    if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
        log_debug "VLESS: port is not a number"
        return 1
    fi
    
    port_num=$((port + 0))
    if [ "$port_num" -lt 1 ] || [ "$port_num" -gt 65535 ]; then
        log_debug "VLESS: port out of range"
        return 1
    fi
    
    # Check for unsupported transport or security
    if [ -n "$query_part" ]; then
        # VLESS XHTTP is NOT supported by standard Sing-Box in Podkop (v1.12+)
        if printf '%s' "$query_part" | grep -qE 'type=xhttp|transport=xhttp|mode=auto'; then
            log_debug "VLESS: unsupported xhttp transport"
            return 1
        fi
        
        # Reality validation: requires pbk and fp
        if printf '%s' "$query_part" | grep -q 'security=reality'; then
            if ! printf '%s' "$query_part" | grep -qE 'pbk='; then
                log_debug "VLESS: reality requires pbk"
                return 1
            fi
            # fp (fingerprint/uTLS) is mandatory for reality in sing-box
            if ! printf '%s' "$query_part" | grep -qE 'fp=[^&]+'; then
                log_debug "VLESS: reality requires non-empty fp (uTLS)"
                return 1
            fi
        fi
    fi
    
    return 0
}

# validate_ss_url() - Validate Shadowsocks URL
# Format: ss://{base64_creds}@{host}:{port}#[fragment]
validate_ss_url() {
    local url="$1"
    local main_part encrypted_part server_part server port port_num

    # Podkop does not support SS with plugin (v2ray-plugin, simple-obfs, etc.)
    if printf '%s' "$url" | grep -qi 'plugin='; then
        log_debug "SS: plugin parameter not supported by Podkop"
        return 1
    fi

    # Remove fragment and query
    main_part=$(printf '%s' "$url" | sed 's/[?#].*//')

    # Extract base64 part
    encrypted_part=$(printf '%s' "$main_part" | sed -n 's|^ss://\([^/@]*\).*|\1|p')
    if [ -z "$encrypted_part" ]; then
        log_debug "SS: missing base64 credentials"
        return 1
    fi
    
    # Handle both formatted (creds@host:port) and legacy (base64) SS URLs
    if printf '%s' "$main_part" | grep -q '@'; then
        server_part=$(printf '%s' "$url" | sed -n 's|.*://[^@]*@\([^/?#]*\).*|\1|p')
    else
        local decoded
        decoded=$(printf '%s' "$encrypted_part" | base64 -d 2>/dev/null)
        if [ -z "$decoded" ] || ! printf '%s' "$decoded" | grep -qE '^[A-Za-z0-9.+_-]+:[^@]+@[^:]+:[0-9]+'; then
            log_debug "SS: legacy base64 URL is invalid or unparseable"
            return 1
        fi
        server_part=$(printf '%s' "$decoded" | sed 's|.*@||')
    fi
    
    if [ -n "$server_part" ]; then
        server=$(printf '%s' "$server_part" | cut -d: -f1)
        port=$(printf '%s' "$server_part" | cut -d: -f2 | sed 's/[/?#].*//')
        
        if [ -z "$server" ]; then
            log_debug "SS: missing server host"
            return 1
        fi
        if [ -z "$port" ] || ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
            log_debug "SS: invalid or missing port"
            return 1
        fi
        
        port_num=$((port + 0))
        if [ "$port_num" -lt 1 ] || [ "$port_num" -gt 65535 ]; then
            log_debug "SS: port out of range"
            return 1
        fi
    fi
    
    return 0
}

# validate_trojan_url() - Validate Trojan URL
# Format: trojan://{password}@{host}:{port}?{query_params}#[fragment]
validate_trojan_url() {
    local url="$1"
    local body main_part user_host_port user_part host_port host port port_num
    
    body="${url#trojan://}"
    main_part="${body%%#*}"
    
    # Split host:port and query
    user_host_port=$(printf '%s' "$main_part" | sed 's/[?].*//')
    
    if [ -z "$user_host_port" ] || ! printf '%s' "$user_host_port" | grep -q '@'; then
        log_debug "Trojan: missing credentials or @ separator"
        return 1
    fi
    
    user_part=$(printf '%s' "$user_host_port" | sed 's/@.*//')
    host_port=$(printf '%s' "$user_host_port" | sed 's|.*@||')
    
    if [ -z "$user_part" ] || [ -z "$host_port" ]; then
        log_debug "Trojan: missing password or server"
        return 1
    fi
    
    host=$(printf '%s' "$host_port" | cut -d: -f1)
    port=$(printf '%s' "$host_port" | cut -d: -f2 | sed 's/[/?#].*//')
    
    if [ -z "$host" ] || [ -z "$port" ] || ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
        log_debug "Trojan: invalid host or port"
        return 1
    fi
    
    port_num=$((port + 0))
    if [ "$port_num" -lt 1 ] || [ "$port_num" -gt 65535 ]; then
        log_debug "Trojan: port out of range"
        return 1
    fi
    
    return 0
}

# validate_socks_url() - Validate SOCKS URL
# Format: socks5://{user}:{pass}@{host}:{port}
#         socks5://{host}:{port}
validate_socks_url() {
    local url="$1"
    local body auth_host host_port host port port_num auth_part username

    body=$(printf '%s' "$url" | sed 's|^socks5://||' | sed 's|^socks4a://||' | sed 's|^socks4://||')
    auth_host="${body%%#*}"
    
    if printf '%s' "$auth_host" | grep -q '@'; then
        auth_part=$(printf '%s' "$auth_host" | sed 's/@.*//')
        host_port=$(printf '%s' "$auth_host" | sed 's|.*@||')
        
        username=$(printf '%s' "$auth_part" | cut -d: -f1)
        if [ -z "$username" ]; then
            log_debug "SOCKS: missing username"
            return 1
        fi
    else
        host_port="$auth_host"
    fi
    
    if [ -z "$host_port" ]; then
        log_debug "SOCKS: missing host and port"
        return 1
    fi
    
    # Parse host:port
    host=$(printf '%s' "$host_port" | cut -d: -f1)
    port=$(printf '%s' "$host_port" | cut -d: -f2)
    
    if [ -z "$host" ]; then
        log_debug "SOCKS: missing hostname or IP"
        return 1
    fi
    
    if [ -z "$port" ]; then
        log_debug "SOCKS: missing port"
        return 1
    fi
    
    # Validate port
    if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
        log_debug "SOCKS: port is not a number"
        return 1
    fi
    
    port_num=$((port + 0))
    if [ "$port_num" -lt 1 ] || [ "$port_num" -gt 65535 ]; then
        log_debug "SOCKS: port out of range"
        return 1
    fi
    
    # Basic host validation (IP or domain-like)
    # Check if it looks like an IPv4 address
    if printf '%s' "$host" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        # Basic IPv4 format check
        return 0
    fi
    
    # Check if it looks like a domain name
    if printf '%s' "$host" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then
        return 0
    fi
    
    log_debug "SOCKS: invalid host format"
    return 1
}

# validate_hy2_url() - Validate Hysteria2 URL
# Format: hysteria2://{password}@{host}:{port}?{query_params}#[fragment]
#         hy2://{password}@{host}:{port}?{query_params}#[fragment]
validate_hy2_url() {
    local url="$1"
    local prefix body main_part query_part auth_host_port password_part host_port host port port_num insecure obfs
    
    # Detect prefix
    if printf '%s' "$url" | grep -q '^hysteria2://'; then
        prefix="hysteria2://"
    elif printf '%s' "$url" | grep -q '^hy2://'; then
        prefix="hy2://"
    else
        log_debug "HY2: invalid prefix"
        return 1
    fi
    
    # Remove prefix
    body="${url#${prefix}}"
    
    # Remove fragment
    main_part="${body%%#*}"
    
    # Split auth@host:port and query
    query_part=$(printf '%s' "$main_part" | grep -oE '[?].*$' || true)
    auth_host_port=$(printf '%s' "$main_part" | sed 's/[?].*//')
    
    if [ -z "$auth_host_port" ]; then
        log_debug "HY2: missing credentials/server"
        return 1
    fi
    
    # Check for @ separator
    if ! printf '%s' "$auth_host_port" | grep -q '@'; then
        log_debug "HY2: missing @ separator"
        return 1
    fi
    
    password_part=$(printf '%s' "$auth_host_port" | sed 's/@.*//')
    host_port=$(printf '%s' "$auth_host_port" | sed 's|.*@||')
    
    if [ -z "$password_part" ]; then
        log_debug "HY2: missing password"
        return 1
    fi
    
    if [ -z "$host_port" ]; then
        log_debug "HY2: missing host & port"
        return 1
    fi
    
    # Parse host:port
    host=$(printf '%s' "$host_port" | cut -d: -f1)
    port=$(printf '%s' "$host_port" | cut -d: -f2 | sed 's/\/.*//')
    
    if [ -z "$host" ]; then
        log_debug "HY2: missing host"
        return 1
    fi
    
    if [ -z "$port" ]; then
        log_debug "HY2: missing port"
        return 1
    fi
    
    # Validate port
    if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
        log_debug "HY2: port is not a number"
        return 1
    fi
    
    port_num=$((port + 0))
    if [ "$port_num" -lt 1 ] || [ "$port_num" -gt 65535 ]; then
        log_debug "HY2: port out of range"
        return 1
    fi
    
    # Validate query parameters if present
    if [ -n "$query_part" ]; then
        insecure=$(printf '%s' "$query_part" | grep -oE 'insecure=[^&]*' | cut -d= -f2)
        if [ -n "$insecure" ] && [ "$insecure" != "0" ] && [ "$insecure" != "1" ]; then
            log_debug "HY2: insecure must be 0 or 1"
            return 1
        fi
        
        obfs=$(printf '%s' "$query_part" | grep -oE 'obfs=[^&]*' | cut -d= -f2)
        if [ -n "$obfs" ]; then
            case "$obfs" in
                none|salamander) ;;
                *)
                    log_debug "HY2: unsupported obfs type '$obfs'"
                    return 1
                    ;;
            esac
            
            # Check obfs-password when obfs is set and not none
            if [ "$obfs" != "none" ]; then
                if ! printf '%s' "$query_part" | grep -qE 'obfs-password='; then
                    log_debug "HY2: obfs-password required when obfs is set"
                    return 1
                fi
            fi
        fi
        
        # Check sni parameter (must not be empty if present)
        if printf '%s' "$query_part" | grep -qE 'sni=$'; then
            log_debug "HY2: sni cannot be empty"
            return 1
        fi
    fi
    
    return 0
}

# =============================================================================
# E. Emoji Flag Country Detection
# =============================================================================

# get_country_from_remark() - Extract 2-letter ISO code from emoji flag in remark
# Uses ONLY emoji flag detection to avoid false positives
# Arguments: $1=remark (URL-encoded)
# Returns: 2-letter country code or "GENERAL"
get_country_from_remark() {
    local remark="$1"
    local pair h1 h2 n1 n2 c1 c2
    
    # Find first pair of consecutive regional indicator URL-encoded sequences
    # Regional indicators: U+1F1E6 to U+1F1FF (A-Z) = UTF-8 F0 9F 87 (A6-BF)
    pair=$(printf '%s' "$remark" | grep -oiE '%F0%9F%87%[A-Fa-f0-9]{2}%F0%9F%87%[A-Fa-f0-9]{2}' | head -1)
    
    if [ -z "$pair" ]; then
        printf 'GENERAL'
        return
    fi
    
    # Extract hex bytes from each regional indicator
    h1=$(printf '%s' "$pair" | grep -oiE '%F0%9F%87%[A-Fa-f0-9]{2}' | head -1 | sed 's/.*%//')
    h2=$(printf '%s' "$pair" | grep -oiE '%F0%9F%87%[A-Fa-f0-9]{2}' | sed -n '2p' | sed 's/.*%//')
    
    if [ -z "$h1" ] || [ -z "$h2" ]; then
        printf 'GENERAL'
        return
    fi
    
    # Convert hex to decimal and compute letter (0xA6=166 maps to 'A'=65)
    n1=$(printf '%d' "0x${h1}")
    n2=$(printf '%d' "0x${h2}")
    c1=$(awk "BEGIN{printf \"%c\", $n1 - 166 + 65}")
    c2=$(awk "BEGIN{printf \"%c\", $n2 - 166 + 65}")
    
    printf '%s%s' "$c1" "$c2"
}

# =============================================================================
# E. Subscription Management
# =============================================================================

list_subscriptions() {
    if [ ! -s "$SBSM_SUBS_FILE" ]; then
        echo -e "${YELLOW}No subscription sources.${NC}"
        return
    fi
    echo -e "${MAGENTA}Current Subscriptions:${NC}"
    local i=0
    local url
    while IFS= read -r url || [ -n "$url" ]; do
        [ -z "$url" ] && continue
        i=$((i + 1))
        printf '  %d. %s\n' "$i" "$url"
    done < "$SBSM_SUBS_FILE"
    
    return 0
}

add_subscription() {
    echo ""
    printf "${YELLOW}Enter subscription URL: ${NC}"
    read -r new_url
    
    if [ -z "$new_url" ]; then
        echo "Empty URL, cancelled."
        return 1
    fi
    
    if ! validate_url "$new_url"; then
        echo "Error: Invalid URL format"
        return 1
    fi
    
    # Check for duplicates
    if grep -qxF "$new_url" "$SBSM_SUBS_FILE" 2>/dev/null; then
        echo "Error: Subscription already exists"
        return 1
    fi
    
    printf '%s\n' "$new_url" >> "$SBSM_SUBS_FILE"
    log_info "Added subscription: $new_url"
    echo "Added: $new_url"
    return 0
}

remove_subscription() {
    list_subscriptions
    
    local total
    total=$(grep -c . "$SBSM_SUBS_FILE" 2>/dev/null || echo 0)
    
    if [ "$total" -eq 0 ]; then
        echo "No subscriptions to remove."
        return 0
    fi
    
    local num
    printf 'Enter number to remove (1-%s): ' "$total"
    read -r num
    
    # Validate input
    if ! echo "$num" | grep -qE '^[0-9]+$'; then
        echo "Invalid number."
        return 1
    fi
    
    if [ "$num" -lt 1 ] || [ "$num" -gt "$total" ]; then
        echo "Number out of range."
        return 1
    fi
    
    local removed
    removed=$(sed -n "${num}p" "$SBSM_SUBS_FILE")
    sed -i "${num}d" "$SBSM_SUBS_FILE"
    log_info "Removed subscription: $removed"
    echo "Removed subscription #$num: $removed"
    return 0
}

fetch_subscriptions() {
    if [ ! -s "$SBSM_SUBS_FILE" ]; then
        log_warn "No subscriptions configured"
        echo "No subscriptions configured. Add URLs via Settings > Manage Subscriptions."
        return 1
    fi
    
    local raw_file
    raw_file=$(create_temp_file)
    local total_added=0
    local sub_url
    local line
    local count
    
    # Collect all entries in memory to reduce jq calls
    local all_entries="[]"
    
    while IFS= read -r sub_url || [ -n "$sub_url" ]; do
        [ -z "$sub_url" ] && continue

        log_info "Fetching subscription: $sub_url"
        echo -e "${CYAN}Fetching:${NC} $sub_url"

        # BusyBox wget doesn't support --tries, use --timeout only
        if ! wget -qO "$raw_file" "$sub_url" --no-check-certificate --timeout=10 2>/dev/null; then
            log_warn "Failed to download: $sub_url"
            echo -e "  ${RED}Warning: Failed to download.${NC}"
            continue
        fi

        # Base64 detection/decoding
        if ! grep -qE '://' "$raw_file"; then
            log_debug "Potential base64 subscription detected, attempting to decode..."
            local decoded_file
            decoded_file=$(create_temp_file)
            
            # Use tr to clean up potentially broken base64 (removes non-base64 characters like whitespace)
            if base64 -d "$raw_file" > "$decoded_file" 2>/dev/null; then
                if grep -qE '://' "$decoded_file"; then
                    log_info "Base64 subscription decoded successfully"
                    mv "$decoded_file" "$raw_file"
                else
                    # Try cleaning up non-base64 characters (sometimes added by providers)
                    tr -d ' \n\r\t' < "$raw_file" | base64 -d > "$decoded_file" 2>/dev/null
                    if grep -qE '://' "$decoded_file"; then
                        log_info "Base64 subscription decoded after cleanup"
                        mv "$decoded_file" "$raw_file"
                    else
                        rm -f "$decoded_file"
                    fi
                fi
            else
                rm -f "$decoded_file"
            fi
        fi

        count=0
        local valid_count=0
        local invalid_count=0

        # Filter proxies to a temporary file (POSIX compatibility)
        local filtered_file
        filtered_file=$(create_temp_file)
        grep -E '^(vless|vmess|ss|trojan|hy2|hysteria2|socks4|socks4a|socks5)://' "$raw_file" > "$filtered_file" 2>/dev/null
        
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(printf '%s' "$line" | tr -d '\r')
            [ -z "$line" ] && continue

            # ... (protocol filtering already handled by grep above, but keeps Case statement for secondary checks if needed)
            case "$line" in
                vmess://*)
                    log_debug "Skipping unsupported VMess proxy (Podkop incompatible)"
                    echo "  Skipping unsupported VMess proxy."
                    continue
                    ;;
                vless://*type=xhttp*|vless://*transport=xhttp*|vless://*mode=auto*)
                    log_debug "Skipping unsupported VLESS XHTTP proxy"
                    echo "  Skipping unsupported VLESS XHTTP proxy."
                    continue
                    ;;
                ss://*plugin=*)
                    log_debug "Skipping SS with plugin (v2ray-plugin/obfs not supported)"
                    echo "  Skipping SS with unsupported plugin."
                    continue
                    ;;
            esac

            if ! validate_proxy_link "$line"; then
                log_warn "Validation failed, skipping: $(printf '%.60s' "$line")..."
                invalid_count=$((invalid_count + 1))
                continue
            fi

            local remark url_clean
            remark="${line##*#}"
            url_clean=$(printf '%s' "$line" | sed "s/'/'\\\\''/g")

            local new_entry
            new_entry=$(jq -n --arg u "$url_clean" --arg r "$remark" '{"url":$u,"remark":$r}')
            all_entries=$(printf '%s' "$all_entries" | jq --argjson e "$new_entry" '. += [$e]')
            count=$((count + 1))
            valid_count=$((valid_count + 1))
        done < "$filtered_file"
        rm -f "$filtered_file"

        log_info "Added $count proxies from subscription ($valid_count valid, $invalid_count invalid)"
        echo -e "  ${GREEN}Added $valid_count proxies${NC} ($invalid_count invalid skipped)."
        total_added=$((total_added + count))
    done < "$SBSM_SUBS_FILE"
    
    # Merge new entries with existing DB (dedup by URL)
    if [ "$total_added" -gt 0 ]; then
        local existing_db
        existing_db=$(cat "$SBSM_DB_FILE" 2>/dev/null || echo '[]')
        printf '%s' "$existing_db" | jq --argjson new "$all_entries" '. + $new | unique_by(.url)' > "$SBSM_DB_FILE" 2>/dev/null
    else
        log_warn "No new proxies fetched, keeping existing database"
    fi

    local final_count
    final_count=$(jq 'length' "$SBSM_DB_FILE" 2>/dev/null || echo 0)

    rm -f "$raw_file"
    log_info "Fetch complete. Total proxies in DB: $final_count"
    echo -e "${GREEN}Done.${NC} Total proxies in database: ${YELLOW}$final_count${NC}"

    [ "$total_added" -gt 0 ] && return 0 || return 1
}

# =============================================================================
# F. Proxy Availability Check (via sing-box)
# =============================================================================

SBSM_TEST_TIMEOUT="${SBSM_TEST_TIMEOUT:-5000}"

# _parse_host_port() - Extract host:port from proxy URL
# Arguments: $1=proxy URL
# Returns: "host:port" string
_parse_host_port() {
    local url="$1"
    local host_port
    host_port=$(printf '%s' "$url" | sed -n 's|.*://[^@]*@\([^/?#]*\).*|\1|p')
    [ -z "$host_port" ] && host_port=$(printf '%s' "$url" | sed -n 's|.*://\([^/?#]*\).*|\1|p')
    printf '%s' "$host_port"
}

# _build_tag_map() - Build mapping from "host:port" to outbound tag
# Reads sing-box config.json, outputs "host:port tag" lines
# Arguments: $1=config file path
_build_tag_map() {
    local config_file="$1"
    [ ! -f "$config_file" ] && return 1
    jq -r '[.outbounds[] | select(.server and .server_port)] | .[] | (.server + ":" + (.server_port | tostring) + " " + .tag)' \
        "$config_file" 2>/dev/null
}

# _find_tag_by_host_port() - Look up outbound tag by host:port
# Arguments: $1=tag_map_file, $2=host:port
# Returns: tag string or empty
_find_tag_by_host_port() {
    local map_file="$1" target="$2"
    [ ! -f "$map_file" ] && { printf ''; return; }
    grep -E "^${target} " "$map_file" 2>/dev/null | head -1 | sed 's/^[^ ]* //'
}

# _get_clash_api_addr() - Detect sing-box clash_api address from config
# Returns: API base URL or empty string
_get_clash_api_addr() {
    [ ! -f "$SBSM_CONFIG_FILE" ] && { printf ''; return 1; }
    local addr
    addr=$(jq -r '.experimental.clash_api.external_controller // empty' "$SBSM_CONFIG_FILE" 2>/dev/null)
    [ -z "$addr" ] && { printf ''; return 1; }
    printf 'http://%s' "$addr"
}

# _ensure_singbox_running() - Ensure sing-box is running
# Returns: 0=running, 1=could not start
_ensure_singbox_running() {
    if [ -x "/etc/init.d/sing-box" ] && /etc/init.d/sing-box status >/dev/null 2>&1; then
        return 0
    fi
    if [ -x "/etc/init.d/podkop" ] && /etc/init.d/podkop status >/dev/null 2>&1; then
        return 0
    fi
    if [ -f "$SBSM_CONFIG_FILE" ]; then
        if ! sing-box check -c "$SBSM_CONFIG_FILE" >/dev/null 2>&1; then
            log_error "Cannot start sing-box: config validation failed"
            return 1
        fi
        if [ -x "/etc/init.d/sing-box" ]; then
            /etc/init.d/sing-box start >/dev/null 2>&1
        elif [ -x "/etc/init.d/podkop" ]; then
            /etc/init.d/podkop start >/dev/null 2>&1
        else
            sing-box run -c "$SBSM_CONFIG_FILE" &
        fi
        sleep 3
        return 0
    fi
    return 1
}

check_remove_unavailable() {
    local db_file="$SBSM_DB_FILE"
    local check_url; check_url=$(get_check_url)
    local check_mode; check_mode=$(get_check_mode)

    local total
    total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)

    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}Database is empty.${NC}"
        return 0
    fi

    log_info "Checking $total proxies via sing-box (mode=$check_mode, url=$check_url)..."
    echo -e "${MAGENTA}Checking $total proxies${NC} (mode=${YELLOW}$check_mode${NC}, url=${CYAN}${check_url}${NC})..."

    _ensure_singbox_running

    local api_base="" use_api=0
    api_base=$(_get_clash_api_addr)
    if [ -n "$api_base" ]; then
        if curl -s --max-time 3 "${api_base}/version" >/dev/null 2>&1; then
            use_api=1
            log_info "Using clash_api at $api_base"
            echo -e "  ${CYAN}Method: clash_api${NC} ($api_base)"
        fi
    fi

    if [ "$use_api" -eq 0 ] && [ ! -f "$SBSM_CONFIG_FILE" ]; then
        log_error "No sing-box config found, cannot test proxies"
        echo -e "  ${RED}Error: No sing-box config. Run sync first.${NC}"
        return 1
    fi

    if [ "$use_api" -eq 0 ]; then
        log_info "Using sing-box tools fetch"
        echo -e "  ${CYAN}Method: sing-box tools fetch${NC}"
    fi

    local tag_map; tag_map=$(create_temp_file)
    _build_tag_map "$SBSM_CONFIG_FILE" > "$tag_map"

    # Collect results: each line = "delay entry_base64"
    local results_file; results_file=$(create_temp_file)
    : > "$results_file"
    local fail=0 untagged=0

    local index=0
    while [ "$index" -lt "$total" ]; do
        local entry url remark
        entry=$(jq -r ".[$index] | @base64" "$db_file" 2>/dev/null)
        [ -z "$entry" ] && { index=$((index + 1)); continue; }

        url=$(printf '%s' "$entry" | base64 -d 2>/dev/null | jq -r '.url' 2>/dev/null)
        remark=$(printf '%s' "$entry" | base64 -d 2>/dev/null | jq -r '.remark' 2>/dev/null | cut -c1-40)

        local host_port; host_port=$(_parse_host_port "$url")
        local tag; tag=$(_find_tag_by_host_port "$tag_map" "$host_port")

        printf '  Testing %-42s ' "${remark}..."

        if [ -z "$tag" ]; then
            printf "${DGRAY}SKIP${NC} ${DGRAY}(no outbound)${NC}\n"
            untagged=$((untagged + 1))
            index=$((index + 1))
            continue
        fi

        local delay=""
        if [ "$use_api" -eq 1 ]; then
            local api_result
            api_result=$(curl -s --max-time 10 \
                "${api_base}/proxies/${tag}/delay?timeout=${SBSM_TEST_TIMEOUT}&url=${check_url}" 2>/dev/null)
            if [ -n "$api_result" ] && printf '%s' "$api_result" | grep -q '"delay"'; then
                delay=$(printf '%s' "$api_result" | jq -r '.delay' 2>/dev/null)
                printf "${GREEN}OK${NC} ${DGRAY}(%sms)${NC}\n" "$delay"
            else
                printf "${RED}FAIL${NC}\n"
            fi
        else
            rm -f /tmp/sing-box/cache.db 2>/dev/null
            if sing-box -c "$SBSM_CONFIG_FILE" tools fetch \
                --outbound "$tag" "$check_url" >/dev/null 2>/dev/null; then
                delay="0"
                printf "${GREEN}OK${NC}\n"
            else
                printf "${RED}FAIL${NC}\n"
            fi
        fi

        if [ -n "$delay" ]; then
            # Store delay + entry for sorting (delay as integer for sort)
            local delay_int; delay_int=$(printf '%s' "$delay" | sed 's/[^0-9]//g')
            [ -z "$delay_int" ] && delay_int="99999"
            printf '%05d %s\n' "$delay_int" "$entry" >> "$results_file"
        else
            fail=$((fail + 1))
        fi
        index=$((index + 1))
    done

    # Sort by delay (ascending) and apply check_mode filter
    local sorted_file; sorted_file=$(create_temp_file)
    sort -n "$results_file" > "$sorted_file"

    local alive_count; alive_count=$(grep -c . "$sorted_file" 2>/dev/null || echo 0)

    local keep_count
    case "$check_mode" in
        fastest) keep_count=1 ;;
        5)       keep_count=5 ;;
        10)      keep_count=10 ;;
        20)      keep_count=20 ;;
        all|*)   keep_count="$alive_count" ;;
    esac
    [ "$keep_count" -gt "$alive_count" ] && keep_count="$alive_count"

    # Build filtered DB
    local good_list; good_list=$(create_temp_file)
    echo "[]" > "$good_list"
    local temp_results; temp_results=$(create_temp_file)
    local kept=0

    while IFS=' ' read -r delay_padded entry_b64; do
        [ -z "$entry_b64" ] && continue
        [ "$kept" -ge "$keep_count" ] && break
        local entry_json; entry_json=$(printf '%s' "$entry_b64" | base64 -d 2>/dev/null)
        jq --argjson e "$entry_json" '. += [$e]' "$good_list" > "$temp_results" && \
            mv "$temp_results" "$good_list"
        kept=$((kept + 1))
    done < "$sorted_file"

    cp "$good_list" "$SBSM_DB_FILE"

    local removed=$((alive_count - kept))
    log_info "Check complete: $kept kept (of $alive_count alive), $removed filtered out, $fail dead, $untagged skipped"
    echo ""
    echo -e "${GREEN}Results:${NC} $kept kept (of $alive_count alive), ${YELLOW}$removed filtered${NC} by mode '$check_mode', ${RED}$fail dead${NC}, ${DGRAY}$untagged skipped${NC}"

    return 0
}

# =============================================================================
# G. UCI Integration - Podkop Configuration
# =============================================================================

manage_uci() {
    local mode
    mode=$(get_mode)
    log_info "Mode: $mode"
    echo -e "${YELLOW}Mode:${NC} $mode"

    if [ "$mode" = "russia_inside" ]; then
        _manage_uci_russia_inside
        return $?
    fi

    if [ "$mode" = "subscription" ]; then
        _manage_uci_subscription
        return $?
    fi

    local db_file="$SBSM_DB_FILE"
    local groups_dir
    groups_dir=$(create_temp_file)
    rm -rf "$groups_dir"
    mkdir -p "$groups_dir"
    
    local total
    total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)
    
    if [ "$total" -eq 0 ]; then
        log_warn "Database is empty, nothing to sync"
        echo -e "${RED}Warning: Database is empty, nothing to sync.${NC}"
        return 0
    fi
    
    log_info "Grouping $total proxies by country..."
    echo -e "${CYAN}Grouping $total proxies${NC} by country code..."
    
    local index=0
    while [ "$index" -lt "$total" ]; do
        local entry url remark country pair h1 h2 n1 n2 c1 c2
        
        entry=$(jq -r ".[$index] | @base64" "$db_file" 2>/dev/null)
        [ -z "$entry" ] && { index=$((index + 1)); continue; }
        
        url=$(printf '%s' "$entry" | base64 -d 2>/dev/null | jq -r '.url' 2>/dev/null)
        remark=$(printf '%s' "$entry" | base64 -d 2>/dev/null | jq -r '.remark' 2>/dev/null)
        
        country=$(get_country_from_remark "$remark")

        # Additional sanity checks for existing database entries
        case "$url" in
            *type=xhttp*|*transport=xhttp*|*mode=auto*)
                log_debug "Skipping xhttp proxy: $(printf '%.50s' "$url")"
                index=$((index + 1))
                continue ;;
            vless://*security=reality*)
                local ufp; ufp=$(printf '%s' "$url" | grep -oE 'fp=[^&]*' | cut -d= -f2)
                if [ -z "$ufp" ]; then
                    log_debug "Skipping reality proxy with empty fp: $(printf '%.50s' "$url")"
                    index=$((index + 1))
                    continue
                fi ;;
        esac

        printf '%s\n' "$url" >> "$groups_dir/$country"
        index=$((index + 1))
    done

    # Build UCI batch script
    local batch_file
    batch_file=$(create_temp_file)
    : > "$batch_file"
    
    # Remove existing SBSM-managed sections
    if command -v uci >/dev/null 2>&1; then
        uci show podkop 2>/dev/null | grep '=section' | sed 's/=section//' | \
        sed 's/podkop\.//' | while IFS= read -r sec; do
            if echo "$sec" | grep -qE '^[A-Z]{2}$|^GENERAL$|^SERVICES$|^sbsm_'; then
                printf 'delete podkop.%s\n' "$sec" >> "$batch_file"
            fi
        done
    fi
    
    # Generate UCI commands for each country group
    local section_count=0
    local group_file
    
    for group_file in "$groups_dir"/*; do
        [ -e "$group_file" ] || continue
        
        local gname count
        gname=$(basename "$group_file")
        count=$(grep -c . "$group_file" 2>/dev/null || echo 0)
        [ "$count" -eq 0 ] && continue
        
        # Create UCI section
        printf 'set podkop.%s=section\n' "$gname" >> "$batch_file"
        printf 'set podkop.%s.connection_type=proxy\n' "$gname" >> "$batch_file"
        printf 'set podkop.%s.proxy_config_type=urltest\n' "$gname" >> "$batch_file"
        printf 'set podkop.%s.enable_udp_over_tcp=0\n' "$gname" >> "$batch_file"
        printf 'set podkop.%s.urltest_check_interval=3m\n' "$gname" >> "$batch_file"
        printf 'set podkop.%s.urltest_tolerance=50\n' "$gname" >> "$batch_file"
        printf 'set podkop.%s.urltest_testing_url=https://www.gstatic.com/generate_204\n' "$gname" >> "$batch_file"
        printf 'set podkop.%s.user_domain_list_type=disabled\n' "$gname" >> "$batch_file"
        printf 'set podkop.%s.user_subnet_list_type=disabled\n' "$gname" >> "$batch_file"
        
        local n=0
        local link_url
        while IFS= read -r link_url || [ -n "$link_url" ]; do
            link_url=$(printf '%s' "$link_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            [ -z "$link_url" ] && continue
            n=$((n + 1))
            local q_link; q_link=$(printf '%s' "$link_url" | sed "s/'/'\\\\''/g")
            printf "add_list podkop.%s.urltest_proxy_links='%s'\n" "$gname" "$q_link" >> "$batch_file"
        done < "$group_file"
        
        section_count=$((section_count + 1))
        echo -e "  ${CYAN}[$gname]${NC} $n links"
    done
    
    # Execute UCI batch
    if command -v uci >/dev/null 2>&1; then
        log_info "Executing UCI batch..."
        echo -e "${CYAN}Executing UCI batch...${NC}"
        if uci -q batch < "$batch_file" 2>/dev/null; then
            uci commit podkop 2>/dev/null
            log_info "UCI sync complete: $section_count sections"
            echo -e "${GREEN}UCI sync complete.${NC} $section_count sections created."
        else
            log_error "UCI batch failed"
            return 1
        fi
    fi
    return 0
}

_manage_uci_russia_inside() {
    echo "=== Russia Inside Mode ==="
    local db_file="$SBSM_DB_FILE"
    local groups_dir; groups_dir=$(create_temp_file); rm -rf "$groups_dir"; mkdir -p "$groups_dir"
    local ru_file="$groups_dir/RU" other_file="$groups_dir/RUSSIA_INSIDE"

    local total; total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)
    local index=0 ru_count=0 other_count=0

    while [ "$index" -lt "$total" ]; do
        local entry url remark country
        entry=$(jq -r ".[$index] | @base64" "$db_file" 2>/dev/null)
        [ -z "$entry" ] && { index=$((index + 1)); continue; }
        url=$(printf '%s' "$entry" | base64 -d 2>/dev/null | jq -r '.url' 2>/dev/null)
        remark=$(printf '%s' "$entry" | base64 -d 2>/dev/null | jq -r '.remark' 2>/dev/null)
        country=$(get_country_from_remark "$remark")

        case "$url" in
            *xhttp*|*mode=auto*) index=$((index + 1)); continue ;;
            vless://*security=reality*)
                local ufp; ufp=$(printf '%s' "$url" | grep -oE 'fp=[^&]*' | cut -d= -f2)
                if [ -z "$ufp" ]; then index=$((index + 1)); continue; fi ;;
        esac

        local q_link; q_link=$(printf '%s' "$url" | sed "s/'/'\\\\''/g")
        if [ "$country" = "RU" ]; then
            printf '%s\n' "$q_link" >> "$ru_file"; ru_count=$((ru_count + 1))
        else
            printf '%s\n' "$q_link" >> "$other_file"; other_count=$((other_count + 1))
        fi
        index=$((index + 1))
    done

    echo "  RU: $ru_count links | RUSSIA_INSIDE: $other_count links"

    local batch_file; batch_file=$(create_temp_file); : > "$batch_file"
    if command -v uci >/dev/null 2>&1; then
        uci show podkop 2>/dev/null | grep '=section' | sed 's/=section//' | sed 's/podkop\.//' | while IFS= read -r sec; do
            echo "$sec" | grep -qE '^[A-Z]{2}$|^GENERAL$|^SERVICES$|^RUSSIA_INSIDE$|^SUBSCRIPTION$|^sbsm_' && printf 'delete podkop.%s\n' "$sec" >> "$batch_file"
        done
        
        # Create RU section
        if [ -s "$ru_file" ]; then
            printf 'set podkop.RU=section\nset podkop.RU.connection_type=proxy\nset podkop.RU.proxy_config_type=urltest\n' >> "$batch_file"
            printf 'set podkop.RU.urltest_testing_url=https://www.gstatic.com/generate_204\n' >> "$batch_file"
            while IFS= read -r link; do printf "add_list podkop.RU.urltest_proxy_links='%s'\n" "$link" >> "$batch_file"; done < "$ru_file"
        fi
        # Create RUSSIA_INSIDE section
        if [ -s "$other_file" ]; then
            printf 'set podkop.RUSSIA_INSIDE=section\nset podkop.RUSSIA_INSIDE.connection_type=proxy\nset podkop.RUSSIA_INSIDE.proxy_config_type=urltest\n' >> "$batch_file"
            printf 'set podkop.RUSSIA_INSIDE.urltest_testing_url=https://www.gstatic.com/generate_204\n' >> "$batch_file"
            printf "add_list podkop.RUSSIA_INSIDE.community_lists='russia_inside'\n" >> "$batch_file"
            while IFS= read -r link; do printf "add_list podkop.RUSSIA_INSIDE.urltest_proxy_links='%s'\n" "$link" >> "$batch_file"; done < "$other_file"
        fi

        if uci -q batch < "$batch_file" 2>/dev/null; then
            uci commit podkop 2>/dev/null
            echo -e "${GREEN}UCI sync complete.${NC}"
        else
            log_error "UCI sync failed"
            return 1
        fi
    fi
    return 0
}

_manage_uci_subscription() {
    echo "=== Subscription Mode ==="
    local db_file="$SBSM_DB_FILE"
    local sub_file; sub_file=$(create_temp_file); : > "$sub_file"
    local total; total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)
    local index=0 count=0 ufp
    while [ "$index" -lt "$total" ]; do
        local url; url=$(jq -r ".[$index].url" "$db_file" 2>/dev/null)
        case "$url" in *xhttp*|*mode=auto*) index=$((index+1)); continue ;; vless://*security=reality*) ufp=$(printf '%s' "$url" | grep -oE 'fp=[^&]*' | cut -d= -f2); [ -z "$ufp" ] && { index=$((index+1)); continue; } ;; esac
        local q_link; q_link=$(printf '%s' "$url" | sed "s/'/'\\\\''/g")
        printf '%s\n' "$q_link" >> "$sub_file"; count=$((count+1)); index=$((index+1))
    done
    echo "  subscription: $count links"
    local batch_file; batch_file=$(create_temp_file); : > "$batch_file"
    if command -v uci >/dev/null 2>&1; then
        uci show podkop 2>/dev/null | grep '=section' | sed 's/=section//' | sed 's/podkop\.//' | while IFS= read -r sec; do
            echo "$sec" | grep -qE '^[A-Z]{2}$|^GENERAL$|^SERVICES$|^RUSSIA_INSIDE$|^SUBSCRIPTION$|^sbsm_' && printf 'delete podkop.%s\n' "$sec" >> "$batch_file"
        done
        if [ -s "$sub_file" ]; then
            printf 'set podkop.SUBSCRIPTION=section\nset podkop.SUBSCRIPTION.connection_type=proxy\nset podkop.SUBSCRIPTION.proxy_config_type=urltest\n' >> "$batch_file"
            printf 'set podkop.SUBSCRIPTION.urltest_testing_url=https://www.gstatic.com/generate_204\n' >> "$batch_file"
            while IFS= read -r link; do printf "add_list podkop.SUBSCRIPTION.urltest_proxy_links='%s'\n" "$link" >> "$batch_file"; done < "$sub_file"
        fi
        uci -q batch < "$batch_file" && uci commit podkop && echo -e "${GREEN}UCI sync complete.${NC}"
    fi
    return 0
}

remove_empty_sections() {
    command -v uci >/dev/null 2>&1 || return 0
    local removed=0
    uci show podkop 2>/dev/null | grep '=section' | sed 's/=section//;s/podkop\.//' | while IFS= read -r sec; do
        if echo "$sec" | grep -qE '^[A-Z]{2}$|^GENERAL$|^SERVICES$'; then
            links=$(uci get "podkop.${sec}.urltest_proxy_links" 2>/dev/null)
            if [ -z "$links" ]; then uci delete "podkop.$sec"; removed=$((removed + 1)); fi
        fi
    done
    [ "$removed" -gt 0 ] && uci commit podkop && echo "$removed empty groups removed."
    return 0
}

# cmd_validate() - Validate all proxy URLs in database
cmd_validate() {
    local db_file="$SBSM_DB_FILE"
    local total; total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}Database is empty.${NC}"
        return 0
    fi
    echo -e "${MAGENTA}Validating $total proxy URLs...${NC}"
    local valid=0 invalid=0 index=0
    while [ "$index" -lt "$total" ]; do
        local url; url=$(jq -r ".[$index].url" "$db_file" 2>/dev/null)
        local remark; remark=$(jq -r ".[$index].remark" "$db_file" 2>/dev/null | cut -c1-40)
        if validate_proxy_link "$url"; then
            valid=$((valid + 1))
        else
            invalid=$((invalid + 1))
            printf '  ${RED}INVALID${NC} %-42s\n' "${remark}"
        fi
        index=$((index + 1))
    done
    echo ""
    echo -e "${GREEN}Results:${NC} $valid valid, ${RED}$invalid invalid${NC} out of $total total"
    [ "$invalid" -eq 0 ] && return 0 || return 1
}

# =============================================================================
# H. Interactive Menus
# =============================================================================

show_menu() {
    while true; do
        clear
        echo -e "╔════════════════════════════════════════════════════╗"
        echo -e "║  ${BLUE}SBSM — Sing-Box Subscription Manager${NC}              ║"
        echo -e "║  ${BLUE}Podkop Edition${NC}                      ${DGRAY}v0.5.1${NC}        ║"
        echo -e "╚════════════════════════════════════════════════════╝"
        local sb_ver="Unknown"
        command -v sing-box >/dev/null 2>&1 && sb_ver=$(sing-box version 2>/dev/null | head -n1)
        echo -e "${YELLOW}Sing-Box:${NC} $sb_ver"
        local p_count=0; [ -s "$SBSM_DB_FILE" ] && p_count=$(jq 'length' "$SBSM_DB_FILE" 2>/dev/null || echo 0)
        local s_count=0; [ -f "$SBSM_SUBS_FILE" ] && s_count=$(grep -c . "$SBSM_SUBS_FILE" 2>/dev/null || echo 0)
        echo -e "${YELLOW}Proxies:${NC} $p_count | ${YELLOW}Subscriptions:${NC} $s_count | ${YELLOW}Mode:${NC} $(get_mode)"
        echo ""
        echo -e "${CYAN}1) ${GREEN}Update Subscriptions${NC} (download & sync)"
        echo -e "${CYAN}2) ${GREEN}Check Proxies${NC} (remove dead links)"
        echo -e "${CYAN}3) ${GREEN}Settings${NC} (manage subs, change mode)"
        echo -e "${CYAN}0) ${GREEN}Exit${NC}"
        echo -e "${DGRAY}────────────────────────────────────────────────────${NC}"
        printf "${YELLOW}Choice [0-3]:${NC} "; read -r choice
        case "$choice" in
            1) echo ""; if fetch_subscriptions; then manage_uci && restart_target && sleep 3 && check_remove_unavailable && manage_uci && remove_empty_sections && restart_target; fi; echo "Press Enter..."; read -r _ ;;
            2) echo ""; manage_uci && restart_target && sleep 3 && check_remove_unavailable && manage_uci && remove_empty_sections && restart_target; echo "Press Enter..."; read -r _ ;;
            3) show_settings_menu ;;
            0) break ;;
            *) echo "Invalid choice."; sleep 1 ;;
        esac
    done
}

show_settings_menu() {
    while true; do
        clear
        echo "=== Settings ==="
        echo "Group Mode: $(get_mode)"
        echo "Check Mode: $(get_check_mode) | Check URL: $(get_check_url)"
        echo ""
        echo "1. Manage Subscriptions"
        echo "2. Change Group Mode"
        echo "3. Change Checking Mode"
        echo "0. Back"
        printf "Choice [0-3]: "; read -r sc
        case "$sc" in
            1)
                while true; do
                    clear; echo "=== Subscriptions ==="; list_subscriptions; echo ""
                    echo "1. Add"; echo "2. Remove"; echo "0. Back"
                    printf "Choice [0-2]: "; read -r subc
                    case "$subc" in 1) add_subscription ;; 2) remove_subscription ;; 0) break ;; esac
                    echo "Press Enter..."; read -r _
                done ;;
            2)
                echo "Available: 1. Russia Inside | 2. Group by Country | 3. Subscription"
                printf "Enter (1-3): "; read -r m
                case "$m" in 1) set_mode "russia_inside" ;; 2) set_mode "by_country" ;; 3) set_mode "subscription" ;; esac ;;
            3) _check_settings_menu ;;
            0) break ;;
        esac
    done
}

_check_settings_menu() {
    while true; do
        clear
        echo "=== Checking Mode Settings ==="
        echo "Current check mode: $(get_check_mode)"
        echo "Current check URL:  $(get_check_url)"
        echo ""
        echo "1. Fastest (1 proxy with lowest ping)"
        echo "2. Top 5 fastest proxies"
        echo "3. Top 10 fastest proxies"
        echo "4. Top 20 fastest proxies"
        echo "5. All (keep all alive proxies)"
        echo "6. Change Check URL"
        echo "0. Back"
        printf "Choice [0-6]: "; read -r cm
        case "$cm" in
            1) set_check_mode "fastest"; echo "Set: fastest" ;;
            2) set_check_mode "5"; echo "Set: top 5" ;;
            3) set_check_mode "10"; echo "Set: top 10" ;;
            4) set_check_mode "20"; echo "Set: top 20" ;;
            5) set_check_mode "all"; echo "Set: all" ;;
            6) printf "New URL: "; read -r new_url; set_check_url "$new_url"; echo "Set: $new_url" ;;
            0) break ;;
        esac
        echo "Press Enter..."; read -r _
    done
}

# =============================================================================
# I. Main Execution
# =============================================================================

usage() {
    echo "Usage: $0 {fetch|check|sync|update|validate|mode|check_mode|check_url|status|log|menu}"
    exit 0
}

main() {
    trap cleanup_temp_files EXIT INT TERM
    local cmd="${1:-menu}"
    case "$cmd" in
        fetch) dependency_check && init_config && fetch_subscriptions ;;
        check) dependency_check && init_config && manage_uci && restart_target && sleep 3 && check_remove_unavailable && manage_uci && remove_empty_sections && restart_target ;;
        sync)  dependency_check && init_config && manage_uci && restart_target ;;
        update) dependency_check && init_config && fetch_subscriptions && manage_uci && restart_target && sleep 3 && check_remove_unavailable && manage_uci && remove_empty_sections && restart_target ;;
        mode)   init_config; [ -n "$2" ] && set_mode "$2"; get_mode ;;
        check_mode) init_config; [ -n "$2" ] && set_check_mode "$2"; get_check_mode ;;
        check_url)  init_config; [ -n "$2" ] && set_check_url "$2"; get_check_url ;;
        validate) dependency_check && init_config && cmd_validate ;;
        status)
            echo "Sing-Box: $(command -v sing-box >/dev/null && sing-box version | head -n1 || echo 'NOT FOUND')"
            echo "Proxies: $(jq 'length' "$SBSM_DB_FILE" 2>/dev/null || echo 0)"
            echo "Mode: $(get_mode)";;
        log)
            if command -v logread >/dev/null 2>&1; then logread | grep -i podkop | tail -n "${2:-50}";
            elif [ -f "/var/log/podkop.log" ]; then tail -n "${2:-50}" /var/log/podkop.log; fi ;;
        menu) dependency_check && init_config && show_menu ;;
        *) usage ;;
    esac
}

main "$@"
