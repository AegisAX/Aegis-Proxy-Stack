#!/bin/bash
set -o pipefail

# ==============================================================================
# Aegis-Proxy-Stack Verifier
# ==============================================================================

# [Locale Setup]
export LC_ALL=C
export LANG=C

# --- [Universal Color Palette] ---
TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
TXT_MAGENTA='\033[1;35m'
TXT_CYAN='\033[1;36m'
TXT_WHITE='\033[1;37m'
TXT_GRAY='\033[0;90m'

# Background Colors
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'
BG_MAGENTA='\033[45m'
BG_CYAN='\033[46m'
BG_WHITE='\033[47m'

# Formatting
BOLD='\033[1m'
BLINK='\033[5m'
RESET='\033[0m'

# --- [Visual Helper Functions] ---

print_banner() {
    clear
    local width=64
    local title="Aegis-Proxy-Stack Verifier"
    local title_len=${#title}
    
    local inner_width=$((width - 2))
    local pad_left=$(( (inner_width - title_len) / 2 ))
    local pad_right=$(( inner_width - title_len - pad_left ))
    
    local padding_l=$(printf '%*s' "$pad_left" "")
    local padding_r=$(printf '%*s' "$pad_right" "")
    local horizontal_line=$(printf '%*s' "$width" "" | tr ' ' '#')
    local empty_line=$(printf '%*s' "$inner_width" "")

    echo ""
    echo -e "${TXT_BLUE}   ${horizontal_line}${RESET}"
    echo -e "${TXT_BLUE}   #${RESET}${empty_line}${TXT_BLUE}#${RESET}"
    echo -e "${TXT_BLUE}   #${RESET}${padding_l}${TXT_WHITE}${BOLD}${title}${RESET}${padding_r}${TXT_BLUE}#${RESET}"
    echo -e "${TXT_BLUE}   #${RESET}${empty_line}${TXT_BLUE}#${RESET}"
    echo -e "${TXT_BLUE}   ${horizontal_line}${RESET}"
    echo -e "    ${TXT_CYAN}Automated Configuration & Security Verification${RESET}"
    echo ""
}

# --- [ Dependency Check ] ---
check_dependencies() {
    echo -ne "   TASK  Checking Node.js & Modules..."
    
    # Node.js 설치 확인
    if ! command -v node >/dev/null 2>&1; then
        echo -e "\n   FAIL  Node.js is not installed."
        echo "         Please install Node.js (v18+) to run the verifier."
        exit 1
    fi

    node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' ||
        { echo "Node.js 18+ is required."; exit 1; }
    (cd aegis-config/scripts && node -e '
        const expected = require("./package.json").dependencies["js-yaml"];
        process.exit(require("./node_modules/js-yaml/package.json").version === expected ? 0 : 1);
    ' 2>/dev/null) || npm ci --ignore-scripts --no-fund --prefix aegis-config/scripts || exit 1
    echo -e "\r   DONE  Node.js & Modules are ready.      "
}

log_step() {
    echo -e "\n${TXT_WHITE}[ Step $1 ] $2${RESET}"
    echo -e "${TXT_GRAY}----------------------------------------------------------------${RESET}"
}

log_info() {
    echo -e "   ${BG_CYAN}${TXT_WHITE}${BOLD} INFO ${RESET} $1"
    echo ""
}

log_task() {
    echo -e "   ${BG_BLUE}${TXT_WHITE}${BOLD} TASK ${RESET} $1"
    echo ""
}

log_success() {
    echo -e "   ${BG_GREEN}${TXT_WHITE}${BOLD} DONE ${RESET} $1"
    echo ""
}

log_warn() {
    echo -e "   ${BLINK}${BG_YELLOW}${TXT_WHITE}${BOLD} WARN ${RESET} $1"
    echo ""
}

log_error() {
    echo -e "   ${BLINK}${BG_RED}${TXT_WHITE}${BOLD} FAIL ${RESET} $1"
    echo ""
}

log_input() {
    echo -ne "   ${BG_MAGENTA}${TXT_WHITE}${BOLD} INPUT ${RESET} $1 "
}

# --- [Advanced Spinner Logic] ---
execute_with_spinner() {
    local msg="$1"
    shift
    local cmd="$@"
    
    tput civis
    eval "$cmd" > /dev/null 2>&1 &
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    local temp
    
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}
        printf "\r   ${BG_MAGENTA}${TXT_WHITE}${BOLD}  %c  ${RESET} %s" "$spinstr" "$msg"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    wait $pid
    local exit_code=$?
    
    tput cnorm
    printf "\r\033[K" # Clear line

    if [ $exit_code -eq 0 ]; then
        echo -e "   ${BG_GREEN}${TXT_WHITE}${BOLD} DONE ${RESET} $msg"
    else
        echo -e "   ${BG_RED}${TXT_WHITE}${BOLD} FAIL ${RESET} $msg"
        return 1
    fi
    echo ""
}

# --- [Main Script Start] ---

cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
print_banner
check_dependencies

# ------------------------------------------------------------------------------
# 0. Load Configuration & Initialize Credentials
# ------------------------------------------------------------------------------
# Initialize with environment variables if passed
NPM_USER="${MASTER_EMAIL:-}"
NPM_PASS="${MASTER_PASSWORD:-}"

# Logic: If missing, prompt immediately
if [ -z "$NPM_USER" ] || [ -z "$NPM_PASS" ]; then
    while true; do
        log_input "Enter NPM Admin Email:"
        read -r NPM_USER || exit 1
        echo ""
        if [ -n "$NPM_USER" ]; then break; fi
    done

    while true; do
        log_input "Enter NPM Admin Password:"
        read -rs NPM_PASS || exit 1
        echo ""
        echo ""
        if [ -n "$NPM_PASS" ]; then break; fi
    done
fi

# ------------------------------------------------------------------------------
# 1. Container Status Check
# ------------------------------------------------------------------------------
log_step 1 "Docker Container & Agent Status Check"

echo -e "   ${TXT_WHITE}[ Docker Container Status ]${RESET}"
echo -e "   ${TXT_GRAY}------------------------------------------------${RESET}"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

if docker compose ps agent | grep -q "Up"; then
    execute_with_spinner "Retrieving open-appsec Agent Status..." "sleep 1"
    
    echo -e "   ${TXT_WHITE}[ open-appsec Agent Status ]${RESET}"
    echo -e "   ${TXT_GRAY}------------------------------------------------${RESET}"
    docker compose exec -T agent open-appsec-ctl --status ||
        { log_error "Could not retrieve open-appsec status."; exit 1; }
    echo ""
    
    log_success "Agent container is running and accessible."
else
    log_error "Agent container is NOT running. Please check logs."
    exit 1
fi


# ------------------------------------------------------------------------------
# 2. NPM Authentication & Policy Sync
# ------------------------------------------------------------------------------
log_step 2 "NPM Authentication & Policy Sync"

admin_address=$(docker compose port npm 81) || exit 1
case "$admin_address" in
    0.0.0.0:*) admin_address="127.0.0.1:${admin_address##*:}" ;;
    '[::]:'*) admin_address="[::1]:${admin_address##*:}" ;;
esac
NPM_API="http://$admin_address/api"

# 2-1. Service Wait
check_api() {
    local max_retries=90
    local count=0
    while [ $count -lt $max_retries ]; do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$NPM_API/schema")
        if [ "$code" == "200" ]; then return 0; fi
        sleep 2
        count=$((count+1))
    done
    return 1
}

execute_with_spinner "Waiting for NPM API (max 180s)..." check_api || { log_error "NPM API timed out."; exit 1; }

# [Helper] JSON Generator
get_token() {
    local u=$1
    local p=$2
    printf '%s' "$p" | jq -Rsc --arg u "$u" '{identity:$u,secret:.}' |
        curl -sS --max-time 15 -X POST "$NPM_API/tokens" -H "Content-Type: application/json" --data-binary @-
}

# 2-2. Authenticate (Loop until success)
log_task "Authenticating with NPM..."

TOKEN=""
while true; do
    RAW_RES=$(get_token "$NPM_USER" "$NPM_PASS")
    TOKEN=$(echo "$RAW_RES" | jq -r '.token // empty')

    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
        log_success "Login successful."
        break
    else
        log_warn "Login failed. Credentials might be incorrect."
        echo -e "   ${TXT_GRAY}Please re-enter valid credentials to proceed.${RESET}\n"
        
        NPM_USER=""
        NPM_PASS=""
        
        while true; do
            log_input "Enter NPM Admin Email:"
            read -r NPM_USER || exit 1
            echo ""
            if [ -n "$NPM_USER" ]; then break; fi
        done

        while true; do
            log_input "Enter NPM Admin Password:"
            read -rs NPM_PASS || exit 1
            echo ""
            echo ""
            if [ -n "$NPM_PASS" ]; then break; fi
        done
    fi
done

# Check deployments previously verified with a public proxy to the management listener.
hosts=$(curl -fsS --max-time 15 "$NPM_API/nginx/proxy-hosts" -H "Authorization: Bearer $TOKEN") || exit 1
if ! legacy_admin=$(jq -er 'if type == "array" then
    [.[] | select(.enabled != false and .enabled != 0 and (.domain_names | index("test.aegis.local")) and
    (.forward_port | tostring) == "81" and (.forward_host | IN("127.0.0.1","localhost","::1","npm","aegis-npm")))] | length
    else error("Invalid proxy host inventory") end' <<< "$hosts"); then exit 1; fi
if (( legacy_admin )); then
    log_error "The legacy test.aegis.local proxy still forwards to the admin listener. Review this host in NPM."
    exit 1
fi

# 2-4. Execute Policy Controller
log_task "Executing Policy Controller..."

# Inject Configuration for Node Script
export NPM_USER="$NPM_USER"
export NPM_PASS="$NPM_PASS"
export NPM_API="$NPM_API"
export APPSEC_MODE="prevent-learn"      # [Config] Mode
export APPSEC_CONFIDENCE="medium"       # [Config] Confidence
export POLICY_FILE="../policy/local_policy.yaml"

# Check if script exists
SCRIPT_PATH="aegis-config/scripts/policy_generator.js"
if [ ! -f "$SCRIPT_PATH" ]; then
    log_error "Policy Generator script not found at $SCRIPT_PATH"
    exit 1
fi

# Execute Static Script
cd aegis-config/scripts
node policy_generator.js
CD_RES=$?
cd ../..

if [ $CD_RES -ne 0 ]; then
    log_error "Policy generation failed."
    exit 1
fi
echo "" 

# Use the same file shared with NPM and propagate a failed reload.
execute_with_spinner "Applying WAF policy..." "docker compose exec -T agent open-appsec-ctl --apply-policy /ext/appsec/local_policy.yaml" || exit 1
docker compose exec -T npm nginx -t || exit 1
log_success "NPM authentication, NGINX configuration and WAF policy reload passed."

# Optional end-to-end verification uses the operator's existing HTTPS test host and benign paths.
host=${AEGIS_VERIFY_HOST:-}
allowed=${AEGIS_VERIFY_ALLOW_PATH:-}
denied=${AEGIS_VERIFY_DENY_PATH:-}
if [[ -z $host && -z $allowed && -z $denied ]]; then
    log_info "End-to-end WAF blocking was not tested. Set AEGIS_VERIFY_HOST, AEGIS_VERIFY_ALLOW_PATH and AEGIS_VERIFY_DENY_PATH to test an existing policy."
    exit 0
fi
if [[ ! $host =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ || ! $allowed =~ ^/[a-zA-Z0-9_./-]*$ ||
      ! $denied =~ ^/[a-zA-Z0-9_./-]*$ || $denied == "$allowed" ]]; then
    log_error "Provide a hostname and two distinct plain paths for the allow and deny checks."
    exit 1
fi
probe() {
    curl --silent --show-error --max-time 10 --noproxy '*' --resolve "$host:443:127.0.0.1" \
        --output /dev/null --write-out '%{http_code}' "https://$host$1"
}
allow_code=$(probe "$allowed") && deny_code=$(probe "$denied") || exit 1
if [[ $allow_code == 200 && $deny_code == 403 ]]; then
    log_success "HTTPS test host returned 200 on the allow path and 403 on the deny path."
else
    log_error "Expected HTTP 200/403. Received $allow_code/$deny_code."
    exit 1
fi
