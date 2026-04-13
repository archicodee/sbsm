#!/bin/sh
# =============================================================================
# SBSM (Sing-Box Subscription Manager) - Extended Edition
# Description: Manage proxy subscriptions for sing-box extended
# Version: 0.7.0
# =============================================================================

# =============================================================================
# A. Configuration & Globals
# =============================================================================

# Paths (configurable via environment or defaults)
SBSM_CONF_DIR="${SBSM_CONF_DIR:-/etc/sing-box}"
SBSM_DB_FILE="$SBSM_CONF_DIR/sbsm.json"
SBSM_SUBS_FILE="$SBSM_CONF_DIR/sbsm.subs"
SBSM_CONFIG_FILE="$SBSM_CONF_DIR/config.json"
SBSM_CONF_FILE="${SBSM_CONF_FILE:-/etc/sing-box/sbsm.conf}"

# Performance settings
SBSM_TEST_TIMEOUT="${SBSM_TEST_TIMEOUT:-5000}"
SBSM_CHECK_API_PORT="${SBSM_CHECK_API_PORT:-9091}"

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
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ -w "$(dirname "$SBSM_LOG_FILE")" ] 2>/dev/null; then
        printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >> "$SBSM_LOG_FILE" 2>/dev/null
    fi
    case "$level" in
        error) printf '%s: %s\n' "$level" "$message" >&2 ;;
        warn) printf '%s: %s\n' "$level" "$message" >&2 ;;
        info) printf '%s: %s\n' "$level" "$message" >&2 ;;
        debug) [ "$SBSM_LOG_LEVEL" = "debug" ] && printf '%s: %s\n' "$level" "$message" >&2 ;;
    esac
}

log_error() { log_message "error" "$1"; }
log_warn() { log_message "warn" "$1"; }
log_info() { log_message "info" "$1"; }
log_debug() { log_message "debug" "$1"; }

create_temp_file() {
    local temp_file; temp_file=$(mktemp /tmp/sbsm.XXXXXX 2>/dev/null) || temp_file="/tmp/sbsm.$$.$(date +%s)"
    chmod 600 "$temp_file" 2>/dev/null
    SBSM_TEMP_FILES="$SBSM_TEMP_FILES $temp_file"
    printf '%s' "$temp_file"
}

cleanup_temp_files() {
    # Kill check sing-box instance if running
    if [ -f /tmp/sbsm_check.pid ]; then
        kill "$(cat /tmp/sbsm_check.pid)" 2>/dev/null
        rm -f /tmp/sbsm_check.pid
    fi
    # Note: /tmp/sbsm_check.json is cleaned by _stop_check_singbox()
    for f in $SBSM_TEMP_FILES; do rm -f "$f" 2>/dev/null; done
    SBSM_TEMP_FILES=""
}

validate_url() {
    local url="$1"; [ -z "$url" ] && return 1
    case "$url" in http://*|https://*) ;; *) return 1 ;; esac
    if printf '%s' "$url" | grep -qE '[;&|`$()]'; then log_error "URL contains invalid characters"; return 1; fi
    if ! printf '%s' "$url" | grep -qE '^https?://[A-Za-z0-9.-]+(/.*)?$'; then return 1; fi
    return 0
}

# =============================================================================
# C. Initialization & Dependencies
# =============================================================================

dependency_check() {
    local missing=""; local cmd
    for cmd in jq wget curl grep sed awk base64; do
        if ! command -v "$cmd" >/dev/null 2>&1; then missing="$missing $cmd"; fi
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
ru_srs_urls=
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

get_mode() { cfg_get "sbsm_extended" "mode" "by_country"; }
get_sb_mode() { cfg_get "sbsm_extended" "sb_mode" "tun"; }
set_mode() {
    case "$1" in
        by_country|russia_inside|subscription) cfg_set "sbsm_extended" "mode" "$1" ;;
        *) return 1 ;;
    esac
}
set_sb_mode() {
    case "$1" in
        tun|tproxy_fakeip) cfg_set "sbsm_extended" "sb_mode" "$1" ;;
        *) return 1 ;;
    esac
}
get_ru_srs() { cfg_get "sbsm_extended" "ru_srs_urls" ""; }
set_ru_srs() { cfg_set "sbsm_extended" "ru_srs_urls" "$1"; }
get_check_url() { cfg_get "sbsm_extended" "check_url" "https://www.gstatic.com/generate_204"; }
set_check_url() { cfg_set "sbsm_extended" "check_url" "$1"; }
get_check_mode() { cfg_get "sbsm_extended" "check_mode" "all"; }
set_check_mode() {
    case "$1" in
        fastest|5|10|20|all) cfg_set "sbsm_extended" "check_mode" "$1" ;;
        *) log_error "Invalid check_mode: $1 (use: fastest, 5, 10, 20, all)"; return 1 ;;
    esac
}
get_batch_size() { cfg_get "sbsm_extended" "batch_size" "10"; }
set_batch_size() {
    case "$1" in
        1|2|3|4|5|10|15|20|25|30) cfg_set "sbsm_extended" "batch_size" "$1" ;;
        *) log_error "Invalid batch_size: $1 (use: 1-30)"; return 1 ;;
    esac
}
get_check_timeout() { cfg_get "sbsm_extended" "check_timeout" "5000"; }
set_check_timeout() {
    case "$1" in
        1000|2000|3000|5000|10000|15000) cfg_set "sbsm_extended" "check_timeout" "$1" ;;
        *) log_error "Invalid check_timeout: $1 (use: 1000-15000 ms)"; return 1 ;;
    esac
}

DEFAULT_GEOSITE_RU="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-ru-blocked.srs"
DEFAULT_GEOIP_RU="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru-blocked.srs"

restart_target() {
    local config_file="$SBSM_CONFIG_FILE"
    if [ -f "$config_file" ]; then
        if ! sing-box check -c "$config_file" >/dev/null 2>&1; then
            log_error "JSON validation failed! Service start aborted."
            echo -e "${RED}Config validation FAILED! Service start aborted.${NC}"
            return 1
        fi
    fi
    if [ -x "/etc/init.d/sing-box" ]; then
        log_info "Restarting Sing-Box..."
        echo -e "${CYAN}Restarting Sing-Box...${NC}"
        /etc/init.d/sing-box restart 2>/dev/null
        return $?
    fi
    log_warn "Sing-Box init script NOT found"
    echo -e "${YELLOW}Warning: /etc/init.d/sing-box not found${NC}"
    return 1
}

# =============================================================================
# D. Proxy URL Validation (Sing-Box Extended)
# =============================================================================

validate_proxy_link() {
    local url="$1"; url=$(printf '%s' "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$url" ] && return 1
    case "$url" in
        vless://*)       validate_vless_url "$url" ;;
        ss://*)          validate_ss_url "$url" ;;
        trojan://*)      validate_trojan_url "$url" ;;
        socks5://*|socks4://*|socks4a://*) validate_socks_url "$url" ;;
        hy2://*|hysteria2://*) validate_hy2_url "$url" ;;
        tuic://*)        validate_tuic_url "$url" ;;
        vmess://*)       validate_vmess_url "$url" ;;
        http://*|https://*) validate_http_url "$url" ;;
        *)               return 1 ;;
    esac
}

validate_vless_url() {
    local body="${1#vless://}" main="${body%%#*}" host_port; host_port=$(printf '%s' "$main" | sed 's/[?].*//')
    [ -z "$host_port" ] || ! printf '%s' "$host_port" | grep -q '@' && return 1
    if printf '%s' "$main" | grep -q 'security=reality' && ! printf '%s' "$main" | grep -qE 'fp=[^&]+'; then return 1; fi
    local flow=$(printf '%s' "$main" | grep -oE 'flow=[^&]*' | cut -d= -f2)
    [ "$flow" = "xtls-rprx-vision-udp443" ] && return 1
    return 0
}
validate_ss_url() {
    local url="$1" main_part encrypted_part server_part server port
    main_part=$(printf '%s' "$url" | sed 's/[?#].*//')
    encrypted_part=$(printf '%s' "$main_part" | sed -n 's|^ss://\([^/@]*\).*|\1|p')
    [ -z "$encrypted_part" ] && return 1
    if printf '%s' "$main_part" | grep -q '@'; then
        server_part=$(printf '%s' "$url" | sed -n 's|.*://[^@]*@\([^/?#]*\).*|\1|p')
    else
        local decoded; decoded=$(printf '%s' "$encrypted_part" | base64 -d 2>/dev/null)
        if [ -z "$decoded" ] || ! printf '%s' "$decoded" | grep -qE '^[A-Za-z0-9.+_-]+:[^@]+@[^:]+:[0-9]+'; then
            return 1
        fi
        server_part=$(printf '%s' "$decoded" | sed 's|.*@||')
    fi
    [ -n "$server_part" ] || return 1
    server=$(printf '%s' "$server_part" | cut -d: -f1)
    port=$(printf '%s' "$server_part" | cut -d: -f2 | sed 's/[/?#].*//')
    [ -n "$server" ] && [ -n "$port" ] && printf '%s' "$port" | grep -qE '^[0-9]+$'
}
validate_trojan_url() {
    local body="${1#trojan://}" main host_port
    main=$(printf '%s' "$body" | sed 's/[?#].*//')
    host_port="${main#*@}"
    [ "$host_port" = "$main" ] && return 1
    printf '%s' "$host_port" | grep -qE '[^:]+:[0-9]+'
}
validate_socks_url() {
    local body="${1#*://}" main host_port
    main=$(printf '%s' "$body" | sed 's/[?#].*//')
    host_port="${main#*@}"
    [ "$host_port" = "$main" ] && host_port="$main"
    printf '%s' "$host_port" | grep -qE '[^:]+:[0-9]+'
}
validate_hy2_url() {
    local body="${1#*://}" main host_port
    main=$(printf '%s' "$body" | sed 's/[?#].*//')
    host_port="${main#*@}"
    [ "$host_port" = "$main" ] && return 1
    printf '%s' "$host_port" | grep -qE '[^:]+:[0-9]+'
}
validate_tuic_url() {
    local body="${1#tuic://}" main host_port
    main=$(printf '%s' "$body" | sed 's/[?#].*//')
    host_port="${main#*@}"
    [ "$host_port" = "$main" ] && return 1
    printf '%s' "$host_port" | grep -qE '[^:]+:[0-9]+'
}
validate_vmess_url() {
    local url="$1" body encoded decoded
    body="${url#vmess://}"
    [ -z "$body" ] && return 1
    encoded=$(printf '%s' "$body" | sed 's/[?#].*//')
    decoded=$(printf '%s' "$encoded" | base64 -d 2>/dev/null)
    [ -z "$decoded" ] && return 1
    printf '%s' "$decoded" | grep -qE '"v"\s*:\s*"2"' || return 1
    printf '%s' "$decoded" | grep -qE '"(add|port|id)"' || return 1
    return 0
}
validate_http_url() {
    local body="${1#*://}" main host_port
    main=$(printf '%s' "$body" | sed 's/[?#].*//')
    host_port="${main#*@}"
    [ "$host_port" = "$main" ] && host_port="$main"
    printf '%s' "$host_port" | grep -qE '[^:]+:[0-9]+'
}

# =============================================================================
# E. Emoji Flag Country Detection
# =============================================================================

get_country_from_remark() {
    local remark="$1" pair h1 h2 n1 n2 c1 c2
    pair=$(printf '%s' "$remark" | grep -oiE '%F0%9F%87%[A-Fa-f0-9]{2}%F0%9F%87%[A-Fa-f0-9]{2}' | head -1)
    [ -z "$pair" ] && { printf 'GENERAL'; return; }
    h1=$(printf '%s' "$pair" | grep -oiE '%F0%9F%87%[A-Fa-f0-9]{2}' | head -1 | sed 's/.*%//')
    h2=$(printf '%s' "$pair" | grep -oiE '%F0%9F%87%[A-Fa-f0-9]{2}' | sed -n '2p' | sed 's/.*%//')
    [ -z "$h1" ] || [ -z "$h2" ] && { printf 'GENERAL'; return; }
    n1=$(printf '%d' "0x${h1}"); n2=$(printf '%d' "0x${h2}")
    c1=$(awk "BEGIN{printf \"%c\", $n1 - 166 + 65}"); c2=$(awk "BEGIN{printf \"%c\", $n2 - 166 + 65}")
    printf '%s%s' "$c1" "$c2"
}

# =============================================================================
# F. JSON Generation (Sing-Box Format)
# =============================================================================

url_to_json() {
    local url="$1" proto="${1%%://*}" body="${1#*://}"
    local main; main=$(printf '%s' "$body" | sed 's/[?#].*//')
    local query; query=$(printf '%s' "$body" | sed -n 's/^[^?]*\?//p' | sed 's/#.*//')
    local user host port remark; remark="${body##*#}"; [ "$remark" = "$body" ] && remark=""
    local tag; tag=$(printf '%s' "$remark" | sed 's/%F0%9F%87%[0-9A-Fa-f][0-9A-Fa-f]%F0%9F%87%[0-9A-Fa-f][0-9A-Fa-f]//g;s/%20/ /g;s/%2C/,/g;s/%7C/|/g;s/%5B/[/g;s/%5D/]/g' | sed 's/[^A-Za-z0-9 _-]//g' | cut -c1-20)
    [ -z "$tag" ] && tag="proxy"
    tag="${tag}-${2:-0}"
    local user_host_port="${main}"; host_port="${user_host_port#*@}"; user="${user_host_port%@*}"
    [ "$host_port" = "$user_host_port" ] && { user=""; host_port="$user_host_port"; }
    host="${host_port%:*}"; port="${host_port#*:}"; [ "$port" = "$host_port" ] && port=""
    port=$(printf '%s' "$port" | sed 's/\/.*//')
    [ -z "$port" ] && return 1
    case "$proto" in
        vless)
            local flow=$(printf '%s' "$query" | grep -oE 'flow=[^&]*' | cut -d= -f2)
            local security=$(printf '%s' "$query" | grep -oE 'security=[^&]*' | cut -d= -f2)
            local transport=$(printf '%s' "$query" | grep -oE 'type=[^&]*' | cut -d= -f2)
            [ -z "$transport" ] && transport=$(printf '%s' "$query" | grep -oE 'transport=[^&]*' | cut -d= -f2)
            local sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2 | sed 's/%[A-Fa-f0-9]\{2\}/\x&/g')
            local fp=$(printf '%s' "$query" | grep -oE 'fp=[^&]*' | cut -d= -f2)
            local pbk=$(printf '%s' "$query" | grep -oE 'pbk=[^&]*' | cut -d= -f2)
            local sid=$(printf '%s' "$query" | grep -oE 'sid=[^&]*' | cut -d= -f2)
            local path=$(printf '%s' "$query" | grep -oE 'path=[^&]*' | cut -d= -f2 | sed 's/%2F/\//g;s/%3F/?/g;s/%3D/=/g;s/%26/\&/g')
            local host_param=$(printf '%s' "$query" | grep -oE 'host=[^&]*' | cut -d= -f2)
            local service_name=$(printf '%s' "$query" | grep -oE 'serviceName=[^&]*' | cut -d= -f2)

            local json=$(jq -n --arg tr "$transport" --arg h "$host" --arg p "$port" --arg u "$user" --arg tag "$tag" \
                '{"type":"vless","tag":$tag,"server":$h,"server_port":($p|tonumber),"uuid":$u}')
            [ -n "$flow" ] && json=$(printf '%s' "$json" | jq --arg f "$flow" '.flow=$f')
            
            local tls_json="{}"
            [ "$security" = "tls" ] && tls_json=$(jq -n --arg sni "$sni" --arg fp "$fp" '{"enabled":true,"server_name":$sni,"utls":{"enabled":true,"fingerprint":$fp}}')
            [ "$security" = "reality" ] && tls_json=$(jq -n --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" \
                '{"enabled":true,"server_name":$sni,"utls":{"enabled":true,"fingerprint":$fp},"reality":{"enabled":true,"public_key":$pbk,"short_id":$sid}}')
            [ "$security" != "none" ] && json=$(printf '%s' "$json" | jq --argjson tls "$tls_json" '.tls=$tls')

            local transport_json="{}"
            case "$transport" in
                ws) transport_json=$(jq -n --arg p "$path" --arg h "$host_param" '{"type":"ws","path":$p,"headers":{"Host":$h}}') ;;
                grpc) transport_json=$(jq -n --arg s "$service_name" '{"type":"grpc","service_name":$s}') ;;
                httpupgrade) transport_json=$(jq -n --arg p "$path" --arg h "$host_param" '{"type":"httpupgrade","path":$p,"host":$h}') ;;
                xhttp) transport_json=$(jq -n --arg p "$path" --arg h "$host_param" '{"type":"xhttp","path":$p,"host":$h}') ;;
            esac
            [ "$transport" != "tcp" ] && [ "$transport" != "" ] && json=$(printf '%s' "$json" | jq --argjson t "$transport_json" '.transport=$t')
            printf '%s' "$json" ;;
        ss)
            # Skip SS with plugin (v2ray-plugin, simple-obfs)
            if printf '%s' "$url" | grep -qi 'plugin='; then
                return 1
            fi
            local method_pass; [ -n "$user" ] && method_pass=$(printf '%s' "$user" | base64 -d 2>/dev/null)
            local method="${method_pass%:*}"; local password="${method_pass#*:}"
            [ -z "$method" ] || [ -z "$password" ] && return 1
            jq -n --arg h "$host" --arg p "$port" --arg m "$method" --arg pw "$password" --arg tag "$tag" \
                '{"type":"shadowsocks","tag":$tag,"server":$h,"server_port":($p|tonumber),"method":$m,"password":$pw}' ;;
        trojan)
            local sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
            jq -n --arg h "$host" --arg p "$port" --arg pw "$user" --arg tag "$tag" --arg sni "$sni" \
                '{"type":"trojan","tag":$tag,"server":$h,"server_port":($p|tonumber),"password":$pw,"tls":{"enabled":true,"server_name":$sni}}' ;;
        hy2|hysteria2)
            local pw="$user"; local sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
            local insecure=$(printf '%s' "$query" | grep -oE 'insecure=[^&]*' | cut -d= -f2)
            local obfs=$(printf '%s' "$query" | grep -oE 'obfs=[^&]*' | cut -d= -f2)
            local obfs_pw=$(printf '%s' "$query" | grep -oE 'obfs-password=[^&]*' | cut -d= -f2)
            local json=$(jq -n --arg h "$host" --arg p "$port" --arg pw "$pw" --arg tag "$tag" \
                '{"type":"hysteria2","tag":$tag,"server":$h,"server_port":($p|tonumber),"password":$pw}')
            local tls_json=$(jq -n --arg sni "$sni" '{"enabled":true,"server_name":$sni}')
            [ "$insecure" = "1" ] && tls_json=$(printf '%s' "$tls_json" | jq '.insecure=true')
            json=$(printf '%s' "$json" | jq --argjson tls "$tls_json" '.tls=$tls')
            [ -n "$obfs" ] && [ "$obfs" != "none" ] && json=$(printf '%s' "$json" | jq --arg t "$obfs" --arg p "$obfs_pw" '.obfs={"type":$t,"password":$p}')
            printf '%s' "$json" ;;
        socks5|socks4a|socks4)
            local version="5"; [ "$proto" = "socks4" ] || [ "$proto" = "socks4a" ] && version="4"
            local user_p="${user%:*}"; local pass_p="${user#*:}"
            local json=$(jq -n --arg h "$host" --arg p "$port" --arg tag "$tag" --arg v "$version" \
                '{"type":"socks","tag":$tag,"server":$h,"server_port":($p|tonumber),"version":$v}')
            [ -n "$user_p" ] && json=$(printf '%s' "$json" | jq --arg u "$user_p" --arg pw "$pass_p" '.username=$u|.password=$pw')
            printf '%s' "$json" ;;
        vmess)
            local vmess_body; vmess_body="${url#vmess://}"
            vmess_body=$(printf '%s' "$vmess_body" | sed 's/[?#].*//')
            local vmess_decoded; vmess_decoded=$(printf '%s' "$vmess_body" | base64 -d 2>/dev/null)
            [ -z "$vmess_decoded" ] && return 1
            local vmess_host; vmess_host=$(printf '%s' "$vmess_decoded" | jq -r '.add // empty')
            local vmess_port; vmess_port=$(printf '%s' "$vmess_decoded" | jq -r '.port // empty')
            local vmess_uuid; vmess_uuid=$(printf '%s' "$vmess_decoded" | jq -r '.id // empty')
            [ -z "$vmess_host" ] || [ -z "$vmess_port" ] || [ -z "$vmess_uuid" ] && return 1
            local vmess_net; vmess_net=$(printf '%s' "$vmess_decoded" | jq -r '.net // "tcp"')
            local vmess_tls; vmess_tls=$(printf '%s' "$vmess_decoded" | jq -r '.tls // ""')
            local vmess_sni; vmess_sni=$(printf '%s' "$vmess_decoded" | jq -r '.sni // ""')
            local vmess_alpn; vmess_alpn=$(printf '%s' "$vmess_decoded" | jq -r '.alpn // ""')
            local vmess_fp; vmess_fp=$(printf '%s' "$vmess_decoded" | jq -r '.fp // ""')
            local vmess_path; vmess_path=$(printf '%s' "$vmess_decoded" | jq -r '.path // ""')
            local vmess_host_hdr; vmess_host_hdr=$(printf '%s' "$vmess_decoded" | jq -r '.host // ""')
            local vmess_service; vmess_service=$(printf '%s' "$vmess_decoded" | jq -r '.path // ""' | sed 's/.*serviceName=//;s/&.*//')
            [ "$vmess_net" = "grpc" ] && vmess_service=$(printf '%s' "$vmess_decoded" | jq -r '.path // ""')
            local vmess_aid; vmess_aid=$(printf '%s' "$vmess_decoded" | jq -r '.aid // "0"')
            local json; json=$(jq -n --arg h "$vmess_host" --arg p "$vmess_port" --arg u "$vmess_uuid" --arg tag "$tag" --arg aid "$vmess_aid" \
                '{"type":"vmess","tag":$tag,"server":$h,"server_port":($p|tonumber),"uuid":$u,"alter_id":($aid|tonumber),"security":"auto"}')
            if [ "$vmess_tls" = "tls" ]; then
                local tls_json; tls_json=$(jq -n --arg sni "$vmess_sni" --arg fp "$vmess_fp" '{"enabled":true,"server_name":$sni,"utls":{"enabled":true,"fingerprint":$fp}}')
                [ -n "$vmess_alpn" ] && tls_json=$(printf '%s' "$tls_json" | jq --arg a "$vmess_alpn" '.alpn=($a | split(","))')
                json=$(printf '%s' "$json" | jq --argjson tls "$tls_json" '.tls=$tls')
            fi
            case "$vmess_net" in
                ws)
                    local t_json; t_json=$(jq -n --arg p "$vmess_path" --arg h "$vmess_host_hdr" '{"type":"ws","path":$p,"headers":{"Host":$h}}')
                    json=$(printf '%s' "$json" | jq --argjson t "$t_json" '.transport=$t') ;;
                grpc)
                    local t_json; t_json=$(jq -n --arg s "$vmess_service" '{"type":"grpc","service_name":$s}')
                    json=$(printf '%s' "$json" | jq --argjson t "$t_json" '.transport=$t') ;;
                h2|http)
                    local t_json; t_json=$(jq -n --arg p "$vmess_path" --arg h "$vmess_host_hdr" '{"type":"http","path":$p,"host":[$h]}')
                    json=$(printf '%s' "$json" | jq --argjson t "$t_json" '.transport=$t') ;;
            esac
            printf '%s' "$json" ;;
        tuic)
            local tuic_body; tuic_body="${url#tuic://}"
            local tuic_main; tuic_main=$(printf '%s' "$tuic_body" | sed 's/[?#].*//')
            local tuic_user; tuic_user="${tuic_main%%@*}"
            local tuic_uuid; tuic_uuid="${tuic_user%%:*}"
            local tuic_pw; tuic_pw="${tuic_user#*:}"
            [ "$tuic_pw" = "$tuic_user" ] && tuic_pw=""
            local tuic_hp; tuic_hp="${tuic_main#*@}"
            local tuic_host; tuic_host="${tuic_hp%:*}"
            local tuic_port; tuic_port="${tuic_hp#*:}"
            tuic_port=$(printf '%s' "$tuic_port" | sed 's/\/.*//')
            [ -z "$tuic_host" ] || [ -z "$tuic_port" ] && return 1
            local tuic_sni; tuic_sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
            local tuic_alpn; tuic_alpn=$(printf '%s' "$query" | grep -oE 'alpn=[^&]*' | cut -d= -f2)
            local tuic_cc; tuic_cc=$(printf '%s' "$query" | grep -oE 'congestion_control=[^&]*' | cut -d= -f2)
            local json; json=$(jq -n --arg h "$tuic_host" --arg p "$tuic_port" --arg u "$tuic_uuid" --arg pw "$tuic_pw" --arg tag "$tag" \
                '{"type":"tuic","tag":$tag,"server":$h,"server_port":($p|tonumber),"uuid":$u,"password":$pw}')
            [ -n "$tuic_cc" ] && json=$(printf '%s' "$json" | jq --arg c "$tuic_cc" '.congestion_control=$c')
            local tls_json; tls_json=$(jq -n --arg sni "$tuic_sni" '{"enabled":true,"server_name":$sni}')
            [ -n "$tuic_alpn" ] && tls_json=$(printf '%s' "$tls_json" | jq --arg a "$tuic_alpn" '.alpn=($a | split(","))')
            json=$(printf '%s' "$json" | jq --argjson tls "$tls_json" '.tls=$tls')
            printf '%s' "$json" ;;
        http|https)
            local http_body; http_body="${1#*://}"
            local http_main; http_main=$(printf '%s' "$http_body" | sed 's/[?#].*//')
            local http_hp; http_hp="${http_main#*@}"
            [ "$http_hp" = "$http_main" ] && http_hp="$http_main"
            local http_host; http_host="${http_hp%:*}"
            local http_port; http_port="${http_hp#*:}"
            http_port=$(printf '%s' "$http_port" | sed 's/\/.*//')
            [ -z "$http_host" ] || [ -z "$http_port" ] && return 1
            local http_user; http_user="${http_main%@*}"
            [ "$http_user" = "$http_main" ] && http_user=""
            local http_u; http_u="${http_user%%:*}"
            local http_pw; http_pw="${http_user#*:}"
            [ "$http_pw" = "$http_user" ] && http_pw=""
            local json; json=$(jq -n --arg h "$http_host" --arg p "$http_port" --arg tag "$tag" \
                '{"type":"http","tag":$tag,"server":$h,"server_port":($p|tonumber)}')
            [ -n "$http_u" ] && json=$(printf '%s' "$json" | jq --arg u "$http_u" --arg pw "$http_pw" '.username=$u|.password=$pw')
            [ "$proto" = "https" ] && json=$(printf '%s' "$json" | jq '.tls={"enabled":true}')
            printf '%s' "$json" ;;
    esac
}

# =============================================================================
# G. Subscription Fetch
# =============================================================================

fetch_subscriptions() {
    local sub_file="$SBSM_SUBS_FILE"
    [ ! -s "$sub_file" ] && { log_warn "No subscriptions configured"; echo "No subscriptions configured. Use: subs add <url>"; return 1; }

    local raw_file=$(create_temp_file) total_added=0

    while IFS= read -r sub_url || [ -n "$sub_url" ]; do
        sub_url=$(printf '%s' "$sub_url" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$sub_url" ] && continue

        # Handle base64-encoded subscription URLs
        if printf '%s' "$sub_url" | grep -qE '^[A-Za-z0-9+/=]{20,}$' && ! printf '%s' "$sub_url" | grep -qE '^https?://'; then
            local decoded; decoded=$(printf '%s' "$sub_url" | base64 -d 2>/dev/null)
            if [ -n "$decoded" ] && printf '%s' "$decoded" | grep -qE '^(vless|ss|trojan|hy2|hysteria2|tuic|vmess|socks)://'; then
                printf '%s\n' "$decoded" > "$raw_file"
            else
                log_warn "Failed to decode base64 subscription"; continue
            fi
        elif wget -qO "$raw_file" "$sub_url" --no-check-certificate --timeout=10 2>/dev/null; then
            log_info "Downloaded: $(printf '%.50s' "$sub_url")"
        else
            log_warn "Failed to download: $(printf '%.50s' "$sub_url")"; continue
        fi

        # Handle base64-encoded content in downloaded file
        if ! grep -qE '^(vless|ss|trojan|hy2|hysteria2|tuic|vmess|socks|http)://' "$raw_file" 2>/dev/null; then
            local decoded; decoded=$(tr -d '\n\r ' < "$raw_file" | base64 -d 2>/dev/null)
            if [ -n "$decoded" ] && printf '%s' "$decoded" | grep -qE '^(vless|ss|trojan|hy2|hysteria2|tuic|vmess|socks)://'; then
                printf '%s\n' "$decoded" | tr ';' '\n' > "$raw_file"
            fi
        fi

        local count=0 valid_count=0 invalid_count=0
        # Collect entries in temp file to avoid memory/ARG_MAX overflow on BusyBox
        local all_entries_file; all_entries_file=$(create_temp_file)
        echo "[]" > "$all_entries_file"
        local all_entries_tmp; all_entries_tmp=$(create_temp_file)
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(printf '%s' "$line" | tr -d '\r'); [ -z "$line" ] && continue
            case "$line" in
                vless://*|ss://*|trojan://*|tuic://*|hy2://*|hysteria2://*|vmess://*|socks4://*|socks4a://*|socks5://*|http://*|https://*) ;;
                *) continue ;;
            esac

            if validate_proxy_link "$line"; then
                local remark="${line##*#}" url_clean
                url_clean=$(printf '%s' "$line" | sed "s/'/'\\\\''/g")
                local ne=$(jq -n --arg u "$url_clean" --arg r "$remark" '{"url":$u,"remark":$r}')
                # Append to file instead of memory to avoid ARG_MAX overflow
                jq --argjson e "$ne" '. += [$e]' "$all_entries_file" > "$all_entries_tmp" && \
                    mv "$all_entries_tmp" "$all_entries_file"
                count=$((count + 1)); valid_count=$((valid_count + 1))
            else
                invalid_count=$((invalid_count + 1))
            fi
        done < "$raw_file"

        # Merge with existing DB (use --slurpfile to avoid ARG_MAX overflow on BusyBox)
        local existing="[]"; [ -f "$SBSM_DB_FILE" ] && existing=$(cat "$SBSM_DB_FILE" 2>/dev/null)
        [ -z "$existing" ] || [ "$existing" = "null" ] && existing="[]"
        local existing_file; existing_file=$(create_temp_file)
        printf '%s' "$existing" > "$existing_file"
        if ! jq --slurpfile new "$all_entries_file" '. + $new[0] | unique_by(.url)' "$existing_file" > "$SBSM_DB_FILE" 2>/dev/null; then
            printf '%s' "$existing" | jq --slurpfile new "$all_entries_file" '. + $new[0] | unique_by(.url)' > "$SBSM_DB_FILE" 2>/dev/null
        fi
        # Last resort: if DB is still empty, write new entries directly (dedup skipped)
        if [ ! -s "$SBSM_DB_FILE" ]; then
            cp "$all_entries_file" "$SBSM_DB_FILE"
            log_error "DB merge failed, wrote new entries only (dedup skipped)"
        fi
        rm -f "$all_entries_file" "$existing_file"
        total_added=$((total_added + valid_count))
        echo -e "  Added ${GREEN}$valid_count${NC} proxies (${YELLOW}$invalid_count${NC} invalid skipped)."
    done < "$sub_file"

    rm -f "$raw_file"
    log_info "Fetch complete. Total proxies: $total_added"
    echo -e "${CYAN}Done. Total proxies in database: $total_added${NC}"
    [ "$total_added" -gt 0 ] && return 0 || return 1
}

# =============================================================================
# H. JSON Configuration Generation
# =============================================================================

_manage_by_country() {
    echo -e "${CYAN}=== Grouping by Country Mode ===${NC}"
    local db_file="$SBSM_DB_FILE"
    local total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)
    local all_outbounds='[]' country_data='{}'

    local i=0; while [ "$i" -lt "$total" ]; do
        local url=$(jq -r ".[$i].url" "$db_file" 2>/dev/null)
        local remark=$(jq -r ".[$i].remark" "$db_file" 2>/dev/null)
        local country=$(get_country_from_remark "$remark")
        local obj=$(url_to_json "$url" "$i")
        if [ -n "$obj" ]; then
            all_outbounds=$(printf '%s' "$all_outbounds" | jq --argjson o "$obj" '. += [$o]' 2>/dev/null) || continue
            local tag=$(printf '%s' "$obj" | jq -r '.tag')
            country_data=$(printf '%s' "$country_data" | jq --arg c "$country" --arg t "$tag" '.[$c] = ((.[$c] // []) + [$t])')
        fi
        i=$((i + 1))
    done

    local country_outbounds='[]' selector_tags='[]'
    local countries=$(printf '%s' "$country_data" | jq -r 'keys[]' 2>/dev/null)
    for cname in $countries; do
        local ctags=$(printf '%s' "$country_data" | jq --arg c "$cname" '.[$c]')
        local lc=$(printf '%s' "$ctags" | jq 'length')
        [ "$lc" -eq 0 ] && continue
        local ut=$(jq -n --arg tag "Group-$cname" --argjson o "$ctags" \
            '{"type":"urltest","tag":$tag,"outbounds":$o,"url":"https://www.gstatic.com/generate_204","interval":"3m","tolerance":50}')
        selector_tags=$(printf '%s' "$selector_tags" | jq --arg t "Group-$cname" '. += [$t]')
        country_outbounds=$(printf '%s' "$country_outbounds" | jq --argjson o "$ut" '. += [$o]')
        echo -e "  [${GREEN}$cname${NC}] $lc links"
    done

    _build_and_save "$all_outbounds" "$country_outbounds" "$selector_tags" "proxy"
}

_manage_russia_inside() {
    echo -e "${CYAN}=== Russia Inside Mode ===${NC}"
    local db_file="$SBSM_DB_FILE"
    local total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)
    local all_outbounds='[]' ri_tags='[]' ru_tags='[]'
    local ru_srs=$(get_ru_srs)

    local i=0; while [ "$i" -lt "$total" ]; do
        local url=$(jq -r ".[$i].url" "$db_file" 2>/dev/null)
        local remark=$(jq -r ".[$i].remark" "$db_file" 2>/dev/null)
        local country=$(get_country_from_remark "$remark")

        local obj=$(url_to_json "$url" "$i")
        if [ -n "$obj" ]; then
            all_outbounds=$(printf '%s' "$all_outbounds" | jq --argjson o "$obj" '. += [$o]')
            if [ "$country" = "RU" ]; then
                local tag=$(printf '%s' "$obj" | jq -r '.tag')
                ru_tags=$(printf '%s' "$ru_tags" | jq --arg t "$tag" '. += [$t]')
            else
                local tag=$(printf '%s' "$obj" | jq -r '.tag')
                ri_tags=$(printf '%s' "$ri_tags" | jq --arg t "$tag" '. += [$t]')
            fi
        fi
        i=$((i + 1))
    done

    local ri_count=$(printf '%s' "$ri_tags" | jq 'length')
    local ru_count=$(printf '%s' "$ru_tags" | jq 'length')
    echo -e "  Russia_inside: ${GREEN}$ri_count${NC} links, RU: ${GREEN}$ru_count${NC} links"

    # Build russia_inside urltest
    local country_outbounds='[]' selector_tags='["russia_inside"]'
    if [ "$ri_count" -gt 0 ]; then
        local ri_ut=$(jq -n --argjson o "$ri_tags" \
            '{"type":"urltest","tag":"russia_inside","outbounds":$o,"url":"https://www.gstatic.com/generate_204","interval":"3m","tolerance":50}')
        country_outbounds=$(printf '%s' "$country_outbounds" | jq --argjson o "$ri_ut" '. += [$o]')
    fi
    # Build RU urltest
    if [ "$ru_count" -gt 0 ]; then
        local ru_ut=$(jq -n --argjson o "$ru_tags" \
            '{"type":"urltest","tag":"RU","outbounds":$o,"url":"https://www.gstatic.com/generate_204","interval":"3m","tolerance":50}')
        country_outbounds=$(printf '%s' "$country_outbounds" | jq --argjson o "$ru_ut" '. += [$o]')
        selector_tags=$(printf '%s' "$selector_tags" | jq '. += ["RU"]')
    fi

    # Add SRS rules for russia_inside
    local rule_set='[{"type":"remote","tag":"geosite-ru-blocked","format":"binary","url":"'"$DEFAULT_GEOSITE_RU"'","download_detour":"direct"},{"type":"remote","tag":"geoip-ru-blocked","format":"binary","url":"'"$DEFAULT_GEOIP_RU"'","download_detour":"direct"}]'

    _build_and_save_srs "$all_outbounds" "$country_outbounds" "$selector_tags" "russia_inside" "$rule_set"
}

_manage_subscription() {
    echo -e "${CYAN}=== Subscription Mode ===${NC}"
    local db_file="$SBSM_DB_FILE" total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)
    local all_outbounds='[]' sub_tags='[]'; local count=0

    local i=0; while [ "$i" -lt "$total" ]; do
        local url=$(jq -r ".[$i].url" "$db_file" 2>/dev/null)
        local obj=$(url_to_json "$url" "$i")
        if [ -n "$obj" ]; then
            all_outbounds=$(printf '%s' "$all_outbounds" | jq --argjson o "$obj" '. += [$o]')
            local tag=$(printf '%s' "$obj" | jq -r '.tag')
            sub_tags=$(printf '%s' "$sub_tags" | jq --arg t "$tag" '. += [$t]')
            count=$((count + 1))
        fi
        i=$((i + 1))
    done
    echo -e "  Found ${GREEN}$count${NC} valid proxies for 'subscription' group."
    [ "$count" -eq 0 ] && { log_warn "No valid proxies"; return 1; }

    local sub_ut=$(jq -n --argjson o "$sub_tags" \
        '{"type":"urltest","tag":"subscription","outbounds":$o,"url":"https://www.gstatic.com/generate_204","interval":"3m","tolerance":50}')
    _build_and_save "$all_outbounds" "$sub_ut" '["subscription"]' "subscription"
}

_build_and_save() {
    local all_outbounds="$1" country_outbounds="$2" selector_tags="$3" default_tag="$4"
    local mode=$(get_sb_mode)

    local final_outbounds=$(jq -n --argjson co "$country_outbounds" --argjson all "$all_outbounds" \
        '$co + $all + [{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]')

    local selector=$(jq -n --argjson st "$selector_tags" --arg def "$default_tag" \
        '{"type":"selector","tag":"proxy","outbounds":$st,"default":(if ($st|length)>0 then $def else "direct" end)}')
    final_outbounds=$(printf '%s' "$final_outbounds" | jq --argjson s "$selector" '[$s] + .')

    local inbound_json dns_json
    case "$mode" in
        tun)
            inbound_json='[{"type":"tun","tag":"tun-in","address":["172.18.0.1/30"],"auto_route":true,"strict_route":true,"stack":"mixed","sniff":true},{"type":"mixed","tag":"mixed-in","listen":"::","listen_port":2080}]'
            dns_json='{"servers":[{"type":"tls","tag":"dns-remote","server":"8.8.8.8","detour":"proxy"},{"type":"local","tag":"dns-local"}],"final":"dns-remote"}'
            ;;
        tproxy_fakeip)
            inbound_json='[{"type":"tproxy","tag":"tproxy-in","listen":"::","listen_port":9898,"sniff":true},{"type":"mixed","tag":"mixed-in","listen":"::","listen_port":2080}]'
            dns_json='{"servers":[{"type":"tls","tag":"dns-remote","server":"8.8.8.8","detour":"proxy"},{"type":"local","tag":"dns-local"},{"tag":"fakeip","type":"fakeip","inet4_range":"198.18.0.0/15"}],"rules":[{"query_type":["A","AAAA"],"server":"fakeip"}],"final":"dns-remote"}'
            ;;
        *)
            inbound_json='[{"type":"tun","tag":"tun-in","address":["172.18.0.1/30"],"auto_route":true,"strict_route":true,"stack":"mixed","sniff":true},{"type":"mixed","tag":"mixed-in","listen":"::","listen_port":2080}]'
            dns_json='{"servers":[{"type":"tls","tag":"dns-remote","server":"8.8.8.8","detour":"proxy"},{"type":"local","tag":"dns-local"}],"final":"dns-remote"}'
            ;;
    esac

    jq -n --argjson outbounds "$final_outbounds" --argjson inb "$inbound_json" \
           --argjson dns "$dns_json" --arg final "$default_tag" \
        '{"log":{"level":"info","timestamp":true},"dns":$dns,"inbounds":$inb,"outbounds":$outbounds,"route":{"rules":[{"protocol":"dns","action":"hijack-dns"},{"ip_is_private":true,"action":"route","outbound":"direct"}],"final":$final,"default_domain_resolver":{"server":"dns-local"}},"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","external_ui":"","secret":""}}}' \
        > "$SBSM_CONFIG_FILE" 2>/dev/null

    [ -f "$SBSM_CONFIG_FILE" ] && {
        local sz=$(wc -c < "$SBSM_CONFIG_FILE" 2>/dev/null || echo 0)
        echo -e "${CYAN}Config generated: $SBSM_CONFIG_FILE ($sz bytes)${NC}"
        jq empty "$SBSM_CONFIG_FILE" && echo -e "${GREEN}Config validation: OK${NC}" || echo -e "${RED}Config validation: FAILED${NC}"
    }
}

_build_and_save_srs() {
    local all_outbounds="$1" country_outbounds="$2" selector_tags="$3" default_tag="$4" rule_set="$5"
    local mode=$(get_sb_mode)

    local final_outbounds=$(jq -n --argjson co "$country_outbounds" --argjson all "$all_outbounds" \
        '$co + $all + [{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]')

    local selector=$(jq -n --argjson st "$selector_tags" --arg def "$default_tag" \
        '{"type":"selector","tag":"proxy","outbounds":$st,"default":(if ($st|length)>0 then $def else "direct" end)}')
    final_outbounds=$(printf '%s' "$final_outbounds" | jq --argjson s "$selector" '[$s] + .')

    local inbound_json dns_json
    case "$mode" in
        tun)
            inbound_json='[{"type":"tun","tag":"tun-in","address":["172.18.0.1/30"],"auto_route":true,"strict_route":true,"stack":"mixed","sniff":true},{"type":"mixed","tag":"mixed-in","listen":"::","listen_port":2080}]'
            dns_json='{"servers":[{"type":"tls","tag":"dns-remote","server":"8.8.8.8","detour":"russia_inside"},{"type":"local","tag":"dns-local"}],"final":"dns-remote"}'
            ;;
        tproxy_fakeip)
            inbound_json='[{"type":"tproxy","tag":"tproxy-in","listen":"::","listen_port":9898,"sniff":true},{"type":"mixed","tag":"mixed-in","listen":"::","listen_port":2080}]'
            dns_json='{"servers":[{"type":"tls","tag":"dns-remote","server":"8.8.8.8","detour":"russia_inside"},{"type":"local","tag":"dns-local"},{"tag":"fakeip","type":"fakeip","inet4_range":"198.18.0.0/15"}],"rules":[{"query_type":["A","AAAA"],"server":"fakeip"}],"final":"dns-remote"}'
            ;;
        *)
            inbound_json='[{"type":"tun","tag":"tun-in","address":["172.18.0.1/30"],"auto_route":true,"strict_route":true,"stack":"mixed","sniff":true},{"type":"mixed","tag":"mixed-in","listen":"::","listen_port":2080}]'
            dns_json='{"servers":[{"type":"tls","tag":"dns-remote","server":"8.8.8.8","detour":"russia_inside"},{"type":"local","tag":"dns-local"}],"final":"dns-remote"}'
            ;;
    esac

    jq -n --argjson outbounds "$final_outbounds" \
          --argjson rs "$rule_set" \
          --argjson inb "$inbound_json" \
          --argjson dns "$dns_json" \
        '{"log":{"level":"info","timestamp":true},"dns":$dns,"inbounds":$inb,"outbounds":$outbounds,"route":{"rule_set":$rs,"rules":[{"protocol":"dns","action":"hijack-dns"},{"rule_set":["geosite-ru-blocked","geoip-ru-blocked"],"action":"route","outbound":"russia_inside"},{"ip_is_private":true,"action":"route","outbound":"direct"}],"final":"direct","default_domain_resolver":{"server":"dns-local"}},"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","external_ui":"","secret":""}}}' \
        > "$SBSM_CONFIG_FILE" 2>/dev/null

    [ -f "$SBSM_CONFIG_FILE" ] && {
        local sz=$(wc -c < "$SBSM_CONFIG_FILE" 2>/dev/null || echo 0)
        echo -e "${CYAN}Config generated: $SBSM_CONFIG_FILE ($sz bytes)${NC}"
        jq empty "$SBSM_CONFIG_FILE" && echo -e "${GREEN}Config validation: OK${NC}" || echo -e "${RED}Config validation: FAILED${NC}"
    }
}

# =============================================================================
# G2. Proxy Availability Check (via sing-box)
# =============================================================================

# _generate_check_config() - Generate temporary sing-box config for proxy checking
# Creates config with ALL proxies from DB as outbounds + clash_api
# Writes to /tmp/sbsm_check.json (fixed path, NOT in subshell)
# Arguments: $1=db_file path
# Returns: 0 on success, 1 on failure
_generate_check_config() {
    local db_file="$1"
    local total; total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)
    [ "$total" -eq 0 ] && return 1

    local check_config="/tmp/sbsm_check.json"
    local outbounds_file; outbounds_file=$(create_temp_file)
    echo '[]' > "$outbounds_file"
    local tmp_out; tmp_out=$(create_temp_file)

    local index=0 valid_count=0
    while [ "$index" -lt "$total" ]; do
        local url; url=$(jq -r ".[$index].url" "$db_file" 2>/dev/null)
        [ -z "$url" ] && { index=$((index + 1)); continue; }

        local tag="sbsm-${index}"
        local outbound; outbound=$(url_to_json "$url" "$index")
        if [ -n "$outbound" ]; then
            # Override tag to predictable format
            outbound=$(printf '%s' "$outbound" | jq --arg t "$tag" '.tag=$t')
            jq --argjson o "$outbound" '. += [$o]' "$outbounds_file" > "$tmp_out" && \
                mv "$tmp_out" "$outbounds_file"
            valid_count=$((valid_count + 1))
        fi
        index=$((index + 1))
    done

    [ "$valid_count" -eq 0 ] && { log_error "No valid outbounds generated for check config"; return 1; }

    # Add direct outbound
    jq --argjson o '{"type":"direct","tag":"direct-out"}' '. += [$o]' "$outbounds_file" > "$tmp_out" && \
        mv "$tmp_out" "$outbounds_file"

    # Build full sing-box config: log + clash_api + outbounds + route
    # No inbounds needed — we only use clash_api for delay testing
    jq -n \
        --arg port "${SBSM_CHECK_API_PORT:-9091}" \
        --slurpfile outbounds "$outbounds_file" \
        '{
            "log": {"level": "warn"},
            "experimental": {"clash_api": {"external_controller": ("127.0.0.1:" + $port), "secret": ""}},
            "outbounds": $outbounds[0],
            "route": {"rules": [], "final": "direct-out"}
        }' > "$check_config" 2>/dev/null

    if [ ! -s "$check_config" ]; then
        log_error "Failed to generate check config"
        return 1
    fi

    return 0
}

# _kill_check_singbox() - Kill any running check sing-box process (no file cleanup)
_kill_check_singbox() {
    if [ -f /tmp/sbsm_check.pid ]; then
        local pid; pid=$(cat /tmp/sbsm_check.pid 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            local wait_count=0
            while kill -0 "$pid" 2>/dev/null && [ "$wait_count" -lt 10 ]; do
                sleep 1
                wait_count=$((wait_count + 1))
            done
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f /tmp/sbsm_check.pid
    fi
}

# _stop_check_singbox() - Stop check sing-box AND cleanup all files
_stop_check_singbox() {
    _kill_check_singbox
    rm -f /tmp/sbsm_check.json 2>/dev/null
}

# check_remove_unavailable() - Check proxy availability using dedicated sing-box instance
# Generates temp config with ALL proxies, starts sing-box, tests via clash_api in PARALLEL batches
# Returns: 0 on success, 1 on failure
check_remove_unavailable() {
    local db_file="$SBSM_DB_FILE"
    local check_url; check_url=$(get_check_url)
    local check_mode; check_mode=$(get_check_mode)
    local test_timeout; test_timeout=$(get_check_timeout)
    local batch_size; batch_size=$(get_batch_size)

    local total
    total=$(jq 'length' "$db_file" 2>/dev/null || echo 0)

    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}Database is empty.${NC}"
        return 0
    fi

    log_info "Checking $total proxies via dedicated sing-box (mode=$check_mode, url=$check_url, timeout=${test_timeout}ms, batch=$batch_size)..."
    echo -e "${MAGENTA}Checking $total proxies${NC} (mode=${YELLOW}$check_mode${NC}, url=${CYAN}${check_url}${NC})"
    echo -e "  ${CYAN}Method:${NC} clash_api (dedicated, port ${SBSM_CHECK_API_PORT})"
    echo -e "  ${CYAN}Batch:${NC}  ${batch_size} parallel | ${CYAN}Timeout:${NC} ${test_timeout}ms"

    # Generate check config with ALL proxies from DB
    if ! _generate_check_config "$db_file"; then
        echo -e "  ${RED}Error: Failed to generate check config.${NC}"
        return 1
    fi

    local check_config="/tmp/sbsm_check.json"
    if [ ! -f "$check_config" ]; then
        echo -e "  ${RED}Error: Check config not found.${NC}"
        return 1
    fi

    # Validate config
    if ! sing-box check -c "$check_config" >/dev/null 2>&1; then
        log_error "Check config validation failed"
        echo -e "  ${RED}Error: Check config validation failed.${NC}"
        rm -f "$check_config"
        return 1
    fi

    # Kill any previous check sing-box instance (but don't delete config!)
    _kill_check_singbox

    # Start sing-box with check config in background
    sing-box run -c "$check_config" >/dev/null 2>&1 &
    CHECK_PID=$!
    echo "$CHECK_PID" > /tmp/sbsm_check.pid

    log_info "Started check sing-box (PID=$CHECK_PID)"
    echo -e "  ${DGRAY}Starting sing-box instance...${NC}"

    # Wait for sing-box to start and clash_api to become available
    local api_base="http://127.0.0.1:${SBSM_CHECK_API_PORT}"
    local startup_attempts=0
    local startup_max=10
    while [ "$startup_attempts" -lt "$startup_max" ]; do
        if curl -s --max-time 2 "${api_base}/version" >/dev/null 2>&1; then
            break
        fi
        # Check if process died
        if ! kill -0 "$CHECK_PID" 2>/dev/null; then
            log_error "Check sing-box process died during startup"
            echo -e "  ${RED}Error: sing-box process exited unexpectedly.${NC}"
            rm -f /tmp/sbsm_check.pid
            rm -f "$check_config"
            return 1
        fi
        startup_attempts=$((startup_attempts + 1))
        sleep 1
    done

    if [ "$startup_attempts" -ge "$startup_max" ]; then
        log_error "clash_api did not become available within ${startup_max}s"
        echo -e "  ${RED}Error: clash_api not responding.${NC}"
        _stop_check_singbox
        rm -f "$check_config"
        return 1
    fi

    log_info "clash_api ready at $api_base"
    echo -e "  ${GREEN}clash_api ready${NC} (${startup_attempts}s)"

    # ---- Parallel clash_api delay testing ----
    local cur_mode; cur_mode=$(get_mode)
    local results_file; results_file=$(create_temp_file)
    : > "$results_file"
    local fail=0 skipped=0

    local index=0 batch_num=0
    while [ "$index" -lt "$total" ]; do
        batch_num=$((batch_num + 1))
        local b=0
        # Launch batch of parallel delay tests
        while [ "$b" -lt "$batch_size" ] && [ "$index" -lt "$total" ]; do
            local entry url remark
            entry=$(jq -r ".[$index] | @base64" "$db_file" 2>/dev/null)
            local idx="$index"
            local tag="sbsm-${idx}"

            (
                local api_result
                api_result=$(curl -s --max-time 15 \
                    "${api_base}/proxies/${tag}/delay?timeout=${test_timeout}&url=${check_url}" 2>/dev/null)

                local remark_local
                remark_local=$(jq -r ".[$idx].remark" "$db_file" 2>/dev/null | cut -c1-40)

                if [ -n "$api_result" ] && printf '%s' "$api_result" | grep -q '"delay"'; then
                    local delay; delay=$(printf '%s' "$api_result" | jq -r '.delay' 2>/dev/null)
                    local delay_int; delay_int=$(printf '%s' "$delay" | sed 's/[^0-9]//g')
                    [ -z "$delay_int" ] && delay_int="99999"
                    local country="_"
                    if [ "$cur_mode" = "by_country" ]; then
                        country=$(get_country_from_remark "$remark_local")
                    fi
                    local entry_local; entry_local=$(jq -r ".[$idx] | @base64" "$db_file" 2>/dev/null)
                    printf '%s %05d %s\n' "$country" "$delay_int" "$entry_local" >> "$results_file"
                    # Write display line to batch output file (avoid printf % issues with URL-encoded chars)
                    echo "${idx} OK ${delay}" >> "$results_file.display"
                else
                    if printf '%s' "$api_result" | grep -q 'inactive'; then
                        echo "${idx} SKIP 0" >> "$results_file.display"
                        echo "${idx} SKIP" >> "$results_file.skipped"
                    else
                        echo "${idx} FAIL 0" >> "$results_file.display"
                        echo "${idx} FAIL" >> "$results_file.failed"
                    fi
                fi
            ) &

            b=$((b + 1))
            index=$((index + 1))
        done

        # Wait for batch to complete (polling approach — BusyBox ash "wait" can hang)
        local batch_expected=$b
        local batch_ready=0 batch_wait=0
        while [ "$batch_wait" -lt 30 ]; do
            batch_ready=$(grep -c . "$results_file.display" 2>/dev/null); : "${batch_ready:=0}"
            [ "$batch_ready" -ge "$batch_expected" ] && break
            batch_wait=$((batch_wait + 1))
            sleep 1
        done

        # Print batch results (from subshell display file)
        if [ -f "$results_file.display" ]; then
            sort -t' ' -k1 -n "$results_file.display" | while read -r didx dstatus ddelay; do
                dremark=$(jq -r ".[$didx].remark" "$db_file" 2>/dev/null | cut -c1-40)
                case "$dstatus" in
                    OK)   echo -e "  ${dremark}... ${GREEN}OK${NC} ${DGRAY}(${ddelay}ms)${NC}" ;;
                    SKIP) echo -e "  ${dremark}... ${DGRAY}SKIP${NC} ${DGRAY}(conversion failed)${NC}" ;;
                    FAIL) echo -e "  ${dremark}... ${RED}FAIL${NC}" ;;
                esac
            done
            # Clear display file for next batch
            : > "$results_file.display"
        fi
    done

    # Count skipped/failed from subshell files
    skipped=$(grep -c "SKIP" "$results_file.skipped" 2>/dev/null || echo 0)
    fail=$(grep -c "FAIL" "$results_file.failed" 2>/dev/null || echo 0)
    rm -f "$results_file.skipped" "$results_file.failed" "$results_file.display" 2>/dev/null

    # Stop the check sing-box instance
    _stop_check_singbox

    # Apply check_mode filter
    local alive_count; alive_count=$(grep -c . "$results_file" 2>/dev/null); : "${alive_count:=0}"
    local good_list; good_list=$(create_temp_file)
    echo "[]" > "$good_list"
    local temp_results; temp_results=$(create_temp_file)
    local kept=0

    if [ "$cur_mode" = "by_country" ] && [ "$check_mode" != "all" ]; then
        # Per-country filtering: keep N best per country
        local keep_count
        case "$check_mode" in
            fastest) keep_count=1 ;;
            5)       keep_count=5 ;;
            10)      keep_count=10 ;;
            20)      keep_count=20 ;;
            *)       keep_count="$alive_count" ;;
        esac

        # Get unique country codes from results
        local countries; countries=$(awk '{print $1}' "$results_file" | sort -u)

        # For each country: sort by delay, extract top N base64 entries to temp file
        for c in $countries; do
            grep "^${c} " "$results_file" | sort -k2 -n | awk '{print $3}' | head -n "$keep_count" \
                > "${good_list}_country_${c}" 2>/dev/null
        done

        # Merge all country picks into good_list
        kept=0
        for c in $countries; do
            local cfile="${good_list}_country_${c}"
            if [ -f "$cfile" ] && [ -s "$cfile" ]; then
                while IFS= read -r entry_b64; do
                    [ -z "$entry_b64" ] && continue
                    local entry_json; entry_json=$(printf '%s' "$entry_b64" | base64 -d 2>/dev/null)
                    [ -z "$entry_json" ] && continue
                    jq --argjson e "$entry_json" '. += [$e]' "$good_list" > "$temp_results" && \
                        mv "$temp_results" "$good_list"
                    kept=$((kept + 1))
                done < "$cfile"
                rm -f "$cfile"
            fi
        done

        local alive_countries; alive_countries=$(printf '%s' "$countries" | grep -c . 2>/dev/null); : "${alive_countries:=0}"
        log_info "Check complete (by_country): $kept kept across $alive_countries countries, $fail dead, $skipped skipped"
        echo ""
        echo -e "${GREEN}Results:${NC} $kept kept across ${CYAN}$alive_countries${NC} countries (${YELLOW}$check_mode${NC} per country), ${RED}$fail dead${NC}, ${DGRAY}$skipped skipped${NC}"
    else
        # Global filtering (russia_inside, subscription, or check_mode=all)
        local sorted_file; sorted_file=$(create_temp_file)
        sort -k2 -n "$results_file" > "$sorted_file"

        local keep_count
        case "$check_mode" in
            fastest) keep_count=1 ;;
            5)       keep_count=5 ;;
            10)      keep_count=10 ;;
            20)      keep_count=20 ;;
            all|*)   keep_count="$alive_count" ;;
        esac
        [ "$keep_count" -gt "$alive_count" ] && keep_count="$alive_count"

        while read -r cname delay_padded entry_b64; do
            [ -z "$entry_b64" ] && continue
            [ "$kept" -ge "$keep_count" ] && break
            local entry_json; entry_json=$(printf '%s' "$entry_b64" | base64 -d 2>/dev/null)
            jq --argjson e "$entry_json" '. += [$e]' "$good_list" > "$temp_results" && \
                mv "$temp_results" "$good_list"
            kept=$((kept + 1))
        done < "$sorted_file"

        local removed=$((alive_count - kept))
        log_info "Check complete: $kept kept (of $alive_count alive), $removed filtered out, $fail dead, $skipped skipped"
        echo ""
        echo -e "${GREEN}Results:${NC} $kept kept (of $alive_count alive), ${YELLOW}$removed filtered${NC} by mode '$check_mode', ${RED}$fail dead${NC}, ${DGRAY}$skipped skipped${NC}"
    fi

    cp "$good_list" "$SBSM_DB_FILE"

    return 0
}

# _setup_tproxy_rules() - Check/create iptables/nftables tproxy rules
# Only needed for tproxy_fakeip mode
_setup_tproxy_rules() {
    local sb_mode=$(get_sb_mode)
    [ "$sb_mode" != "tproxy_fakeip" ] && return 0

    if command -v nft >/dev/null 2>&1; then
        if nft list chain inet fw4 SBSM_TPROXY >/dev/null 2>&1; then
            log_info "nftables SBSM_TPROXY chain already exists"
            echo -e "  ${GREEN}nftables:${NC} SBSM_TPROXY chain exists"
            return 0
        fi
        log_info "Creating nftables SBSM_TPROXY chain..."
        echo -e "  ${CYAN}Creating nftables SBSM_TPROXY chain...${NC}"
        nft add chain inet fw4 SBSM_TPROXY '{ type filter hook prerouting priority mangle; }' 2>/dev/null || {
            nft add chain inet fw4 SBSM_TPROXY 2>/dev/null
        }
        nft add rule inet fw4 SBSM_TPROXY meta l4proto tcp tproxy to :9898 meta mark set 1 2>/dev/null
        nft add rule inet fw4 SBSM_TPROXY meta l4proto udp tproxy to :9898 meta mark set 1 2>/dev/null
        if nft list chain inet fw4 SBSM_TPROXY >/dev/null 2>&1; then
            echo -e "  ${GREEN}nftables SBSM_TPROXY chain created${NC}"
        else
            log_warn "Failed to create nftables tproxy rules"
            echo -e "  ${RED}Failed to create nftables tproxy rules${NC}"
        fi
    elif command -v iptables >/dev/null 2>&1; then
        if iptables -t mangle -L SBSM_TPROXY >/dev/null 2>&1; then
            log_info "iptables SBSM_TPROXY chain already exists"
            echo -e "  ${GREEN}iptables:${NC} SBSM_TPROXY chain exists"
            return 0
        fi
        log_info "Creating iptables SBSM_TPROXY chain..."
        echo -e "  ${CYAN}Creating iptables SBSM_TPROXY chain...${NC}"
        iptables -t mangle -N SBSM_TPROXY 2>/dev/null
        iptables -t mangle -A PREROUTING -j SBSM_TPROXY 2>/dev/null
        iptables -t mangle -A SBSM_TPROXY -p tcp -j TPROXY --on-port 9898 --tproxy-mark 1 2>/dev/null
        iptables -t mangle -A SBSM_TPROXY -p udp -j TPROXY --on-port 9898 --tproxy-mark 1 2>/dev/null
        if iptables -t mangle -L SBSM_TPROXY >/dev/null 2>&1; then
            echo -e "  ${GREEN}iptables SBSM_TPROXY chain created${NC}"
        else
            log_warn "Failed to create iptables tproxy rules"
            echo -e "  ${RED}Failed to create iptables tproxy rules${NC}"
        fi
    else
        log_warn "Neither nftables nor iptables found"
        echo -e "  ${YELLOW}Warning: Neither nftables nor iptables found. Tproxy rules not created.${NC}"
    fi
    return 0
}

manage_json_config() {
    local mode=$(get_mode)
    case "$mode" in
        by_country)    _manage_by_country ;;
        russia_inside) _manage_russia_inside ;;
        subscription)  _manage_subscription ;;
        *) log_error "Mode '$mode' not implemented"; return 1 ;;
    esac
    _setup_tproxy_rules
}

# cmd_clear_db() - Clear proxy database
cmd_clear_db() {
    local count; count=$(jq 'length' "$SBSM_DB_FILE" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}Database is already empty.${NC}"
        return 0
    fi
    echo "[]" > "$SBSM_DB_FILE"
    log_info "Database cleared ($count proxies removed)"
    echo -e "${GREEN}Database cleared:${NC} removed $count proxies"
}

# =============================================================================
# I. Main Interface
# =============================================================================

usage() {
    echo "Usage: sbsm_extended.sh [command]"; echo ""
    echo "  fetch          Download subscriptions and build config"
    echo "  update [--clean]  Full cycle: fetch + check + build + restart"
    echo "  update             (add --clean to clear DB first)"
    echo "  build          Generate config.json from database"
    echo "  check          Check proxy availability + build + restart"
    echo "  clear_db       Remove all proxies from database"
    echo "  status         Show current status"
    echo "  validate       Validate all proxy URLs in database"
    echo "  mode [MODE]    Get/set mode: by_country, russia_inside, subscription"
    echo "  sb_mode [MODE] Get/set sb_mode: tun, tproxy_fakeip"
    echo "  ru_srs [URLs]  Get/set custom RU SRS rule URLs"
    echo "  check_mode [M] Get/set checking mode: fastest, 5, 10, 20, all"
    echo "  check_url [U]  Get/set check URL for proxy testing"
    echo "  batch_size [N] Get/set parallel batch size (1-30, default 10)"
    echo "  check_timeout [N] Get/set check timeout in ms (1000-15000, default 5000)"
    echo "  subs list/add  Manage subscriptions"
    echo "  menu           Interactive menu (default)"
    echo "  help           Show this help"
    exit 0
}

show_menu() {
    while true; do
        clear; echo -e "${CYAN}=== SBSM Extended v0.7.0 ===${NC}"; echo ""
        local pc=$(jq 'length' "$SBSM_DB_FILE" 2>/dev/null || echo 0)
        echo -e "Proxies: ${GREEN}$pc${NC}  Mode: ${YELLOW}$(get_mode)${NC}  SB: ${YELLOW}$(get_sb_mode)${NC}"; echo ""
        echo "1. Update Subscriptions (fetch + build + restart)"
        echo "2. Build Config (from database)"
        echo "3. Settings (mode, sb_mode, subs)"
        echo "4. Clear Database (remove all proxies)"
        echo "0. Exit"; echo ""
        printf "Choice: "; read -r c
        case "$c" in
            1) printf "${YELLOW}Clean DB before update? [y/N]:${NC} "; read -r clean_db
               [ "$clean_db" = "y" ] || [ "$clean_db" = "Y" ] && cmd_clear_db
                 fetch_subscriptions && check_remove_unavailable && manage_json_config && restart_target ;;
            2) manage_json_config && restart_target ;;
            3) _settings_menu ;;
            4) printf "${RED}Remove all proxies from database? [y/N]:${NC} "; read -r confirm
               [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] && cmd_clear_db || echo "Cancelled." ;;
            0) break ;;
        esac; echo "Press Enter..."; read -r _
    done
}

_settings_menu() {
    while true; do
        clear; echo -e "${CYAN}=== Settings ===${NC}"; echo ""
        echo "Group Mode: $(get_mode)"; echo "Sing-Box Mode: $(get_sb_mode)"
        echo "Check Mode: $(get_check_mode) | Check URL: $(get_check_url)"
        echo "Batch: $(get_batch_size) parallel | Timeout: $(get_check_timeout)ms"
        subs_list; echo ""
        echo "1. Change Group Mode (by_country/russia_inside/subscription)"
        echo "2. Change Sing-Box Mode (tun/tproxy_fakeip)"
        echo "3. Change Checking Mode"
        echo "4. Add Subscription URL"
        echo "5. Remove Subscription URL"
        echo "0. Back"; printf "Choice: "; read -r sc
        case "$sc" in
            1) echo "1. by_country  2. russia_inside  3. subscription"; printf "Mode: "; read -r m; case "$m" in 1) set_mode "by_country";;2) set_mode "russia_inside";;3) set_mode "subscription";;esac ;;
            2) echo "1. tun  2. tproxy_fakeip"; printf "SB Mode: "; read -r m; case "$m" in 1) set_sb_mode "tun";;2) set_sb_mode "tproxy_fakeip";;esac ;;
            3) _check_settings_menu ;;
            4) printf "URL: "; read -r u; subs_add "$u" ;;
            5) printf "Number: "; read -r n; subs_remove "$n" ;;
            0) break ;;
        esac; echo "Press Enter..."; read -r _
    done
}

_check_settings_menu() {
    while true; do
        clear
        echo "=== Checking Mode Settings ==="
        echo "Check mode:   $(get_check_mode)"
        echo "Check URL:    $(get_check_url)"
        echo "Batch size:   $(get_batch_size) (parallel connections)"
        echo "Timeout:      $(get_check_timeout)ms"
        echo ""
        echo "1. Fastest (1 proxy with lowest ping)"
        echo "2. Top 5 fastest proxies"
        echo "3. Top 10 fastest proxies"
        echo "4. Top 20 fastest proxies"
        echo "5. All (keep all alive proxies)"
        echo "6. Change Check URL"
        echo "7. Change Batch Size (1-30)"
        echo "8. Change Timeout (1000-15000ms)"
        echo "0. Back"
        printf "Choice [0-8]: "; read -r cm
        case "$cm" in
            1) set_check_mode "fastest"; echo "Set: fastest" ;;
            2) set_check_mode "5"; echo "Set: top 5" ;;
            3) set_check_mode "10"; echo "Set: top 10" ;;
            4) set_check_mode "20"; echo "Set: top 20" ;;
            5) set_check_mode "all"; echo "Set: all" ;;
            6) printf "New URL: "; read -r new_url; set_check_url "$new_url"; echo "Set: $new_url" ;;
            7) printf "Batch size (1-30, default 10): "; read -r new_batch; set_batch_size "$new_batch"; echo "Set: $(get_batch_size)" ;;
            8) printf "Timeout ms (1000/2000/3000/5000/10000/15000): "; read -r new_timeout; set_check_timeout "$new_timeout"; echo "Set: $(get_check_timeout)ms" ;;
            0) break ;;
        esac
        echo "Press Enter..."; read -r _
    done
}

subs_list() {
    local sf="$SBSM_SUBS_FILE"; [ ! -s "$sf" ] && { echo "  (none)"; return 0; }
    echo "Subscriptions:"; local i=0
    while IFS= read -r url || [ -n "$url" ]; do
        url=$(printf '%s' "$url" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); [ -z "$url" ] && continue
        i=$((i + 1)); printf '  %d. %s\n' "$i" "$url"
    done < "$sf"
}

subs_add() {
    local url="$1" sf="$SBSM_SUBS_FILE"
    [ -z "$url" ] && { echo "Error: empty URL"; return 1; }
    grep -qxF "$url" "$sf" 2>/dev/null && { echo "Error: already exists"; return 1; }
    printf '%s\n' "$url" >> "$sf"; echo "Added: $url"
}

subs_remove() {
    local idx="$1" sf="$SBSM_SUBS_FILE"
    printf '%s' "$idx" | grep -qE '^[0-9]+$' || { echo "Error: invalid index"; return 1; }
    local total=$(grep -c . "$sf" 2>/dev/null || echo 0)
    [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ] && { echo "Error: index out of range (1-$total)"; return 1; }
    local removed=$(sed -n "${idx}p" "$sf"); sed -i "${idx}d" "$sf"; echo "Removed: $removed"
}

main() {
    trap cleanup_temp_files EXIT INT TERM
    dependency_check || exit 1
    init_config

    local command="${1:-menu}"
    case "$command" in
        fetch)   fetch_subscriptions ;;
        build)   manage_json_config ;;
        check)   check_remove_unavailable && manage_json_config && restart_target ;;
        update)  [ "${2:-}" = "--clean" ] && cmd_clear_db
               fetch_subscriptions && check_remove_unavailable && manage_json_config && restart_target ;;
        clear_db) cmd_clear_db ;;
        status)  echo "Proxies: $(jq 'length' "$SBSM_DB_FILE" 2>/dev/null || echo 0)  Mode: $(get_mode)  SB: $(get_sb_mode)" ;;
        validate)
            local total=$(jq 'length' "$SBSM_DB_FILE" 2>/dev/null || echo 0) valid=0 invalid=0 i=0
            while [ "$i" -lt "$total" ]; do
                local url=$(jq -r ".[$i].url" "$SBSM_DB_FILE" 2>/dev/null)
                if validate_proxy_link "$url"; then valid=$((valid + 1)); else invalid=$((invalid + 1)); fi
                i=$((i + 1))
            done
            echo "Results: $valid valid, $invalid invalid out of $total total"
            ;;
        mode)    if [ -z "${2:-}" ]; then get_mode; else set_mode "$2"; fi ;;
        sb_mode) if [ -z "${2:-}" ]; then get_sb_mode; else set_sb_mode "$2"; fi ;;
        ru_srs)  if [ -z "${2:-}" ]; then get_ru_srs; else set_ru_srs "$2"; fi ;;
        check_mode) init_config; [ -n "$2" ] && set_check_mode "$2"; get_check_mode ;;
        check_url)  init_config; [ -n "$2" ] && set_check_url "$2"; get_check_url ;;
        batch_size) init_config; [ -n "$2" ] && set_batch_size "$2"; get_batch_size ;;
        check_timeout) init_config; [ -n "$2" ] && set_check_timeout "$2"; get_check_timeout ;;
        subs)
            case "${2:-list}" in
                list) subs_list ;; add) subs_add "${3:-}" ;; remove) subs_remove "${3:-}" ;;
            esac ;;
        menu)    show_menu ;;
        help|--help|-h) usage ;;
        *)       echo "Unknown: $command"; echo "Run 'sbsm_extended.sh help'" ;;
    esac
}

case "$(basename "$0" 2>/dev/null)" in *sbsm_extended*) main "$@" ;; esac
