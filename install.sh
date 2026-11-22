#!/bin/bash
set -o pipefail

# ==============================================================================
# Aegis-Proxy-Stack Installer
# ==============================================================================

# [Locale Setup]
export LC_ALL=C
export LANG=C

# [Constraint] Version is fixed until explicit user update
RELEASE_VERSION="v0.4.1"
FRESH_RELEASE="v0.5.0"
release_install=false
install_override=docker-compose.override.yml

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
RESET='\033[0m'

# --- [Visual Helper Functions] ---

print_banner() {
    clear
    local width=64
    local title="Aegis-Proxy-Stack Installer $RELEASE_VERSION"
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
    echo -e "    ${TXT_CYAN}Automated Security Stack Deployment (Core)${RESET}"
    echo ""
}

log_step() {
    echo -e "\n${TXT_WHITE}[ Step $1 ] $2${RESET}"
    echo -e "${TXT_GRAY}----------------------------------------------------------------${RESET}"
}

log_info() {
    echo -e "   ${BG_CYAN}${TXT_WHITE}${BOLD} INFO ${RESET} $1"
}

log_task() {
    echo -e "   ${BG_BLUE}${TXT_WHITE}${BOLD} TASK ${RESET} $1"
}

log_success() {
    echo -e "   ${BG_GREEN}${TXT_WHITE}${BOLD} DONE ${RESET} $1"
}

log_warn() {
    echo -e "   ${BG_YELLOW}${TXT_WHITE}${BOLD} WARN ${RESET} $1"
}

log_error() {
    echo -e "   ${BG_RED}${TXT_WHITE}${BOLD} FAIL ${RESET} $1"
}

log_wait() {
    echo -ne "   ${BG_MAGENTA}${TXT_WHITE}${BOLD} WAIT ${RESET} $1"
}

# [FIX] Inline Input Style (Removed newline)
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

# New installations at the release tag use its checked-in, digest-pinned image set.
prepare_release_install() {
    local tagged_manifest desired current tmp mode file directory entries
    tagged_manifest=$(git show "refs/tags/$FRESH_RELEASE:releases/$FRESH_RELEASE/aegis-security-v0.4.1-b28d59173f7c8ecb643dcfe0457c7f558438619a.json") || return 1
    printf '%s\n' "$tagged_manifest" | jq -es --arg channel security --arg version v0.4.1 \
        --arg revision b28d59173f7c8ecb643dcfe0457c7f558438619a \
        -f aegis-config/scripts/release-manifest.jq >/dev/null || return 1
    jq -e --arg tag "$FRESH_RELEASE" '.release == $tag and .strategy == "stack-v1"' <<< "$tagged_manifest" >/dev/null || return 1
    release_images=$(jq -c '.images' <<< "$tagged_manifest") || return 1
    desired=$(jq -cS --arg version "$FRESH_RELEASE" '
      {"x-aegis-install-release":$version,services:map_values({image:.target,pull_policy:"never"})} |
      .services["log-rotator"] += {command:["crond","-f","-l","8"],
        healthcheck:{test:["CMD","/usr/local/sbin/aegis-check-logrotate","--health"],
                     interval:"5s",timeout:"8s",retries:5}}
    ' <<< "$release_images") || return 1

    [[ ! -L .aegis-update ]] && mkdir -p -m 700 .aegis-update && [[ -O .aegis-update ]] || return 1
    mode=$(stat -c '%a' -- .aegis-update) || return 1
    (( (8#$mode & 077) == 0 )) || return 1
    command -v flock >/dev/null || return 1
    [[ ! -L .aegis-update/lock ]] || return 1
    exec {install_lock}>>.aegis-update/lock || return 1
    flock -n "$install_lock" || return 1
    for file in VERSION .aegis-update/{images,pending,stack-pending,backup-pending}.json; do
        [[ ! -e $file && ! -L $file ]] || return 1
    done
    if [[ -f $install_override && ! -L $install_override ]]; then
        current=$(jq -cS . "$install_override") || return 1
        [[ $current == "$desired" ]]
        return
    fi
    [[ ! -e .env && ! -L .env && ! -e $install_override && ! -L $install_override ]] || return 1
    [[ ! -L aegis-data ]] || return 1
    for directory in aegis-data/{db,npm,certs,learning}; do
        [[ ! -L $directory ]] || return 1
        [[ -e $directory ]] || continue
        [[ -d $directory ]] && entries=$(ls -A -- "$directory") && [[ -z $entries ]] || return 1
    done
    current=$(docker compose -f docker-compose.yml ps --all --quiet 2>/dev/null) || return 1
    [[ -z $current ]] || return 1
    (
        umask 077
        tmp=$(mktemp ./.compose.install.XXXXXXXX) || exit 1
        trap 'rm -f -- "$tmp"' EXIT
        printf '%s\n' "$desired" > "$tmp" && ln -- "$tmp" "$install_override"
    )
}

pull_release_images() {
    local service target expected actual baked id
    for service in db agent npm log-rotator; do
        target=$(jq -er --arg service "$service" '.[$service].target' <<< "$release_images") || return 1
        expected=$(jq -er --arg service "$service" '.[$service].target_id' <<< "$release_images") || return 1
        if ! actual=$(docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$target" 2>/dev/null); then
            docker image pull "$target" || return 1
            actual=$(docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$target") || return 1
        fi
        [[ $actual == "$expected linux/amd64" ]] || { log_error "$service image does not match the release."; return 1; }
    done
    # Keep the scheduler's baked rules consistent with the checked-out configuration.
    id=$(jq -er '.["log-rotator"].target_id' <<< "$release_images") || return 1
    baked=$(docker run --rm --pull never --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges --entrypoint sha256sum "$id" /usr/local/etc/aegis/logrotate.conf) || return 1
    [[ ${baked%% *} == "$(sha256sum < aegis-config/logrotate/aegis-rotate.conf | cut -d ' ' -f 1)" ]]
}

record_fresh_install() (
    umask 022
    tmp=$(mktemp ./.version.install.XXXXXXXX) || exit 1
    trap 'rm -f -- "$tmp"' EXIT
    printf '%s\n' "$FRESH_RELEASE" > "$tmp" && chmod 644 "$tmp" && ln -- "$tmp" VERSION
)

# --- [Main Script Start] ---

cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

# ------------------------------------------------------------------------------
# 0. Check Prerequisites
# ------------------------------------------------------------------------------
for pkg in jq curl node npm docker; do
    if ! command -v $pkg &> /dev/null; then
        log_error "Missing required package: '$pkg'"
        echo -e "            Please install it first (e.g., sudo apt install $pkg)"
        exit 1
    fi
done
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' ||
    { log_error "Node.js 18+ is required."; exit 1; }

if [ ! -f "docker-compose.yml" ]; then
    log_error "File not found: docker-compose.yml"
    exit 1
fi

if [[ ! -e VERSION && ! -L VERSION ]] && command -v git >/dev/null &&
   tag_commit=$(git rev-parse --verify "refs/tags/$FRESH_RELEASE^{commit}" 2>/dev/null) &&
   [[ $tag_commit == "$(git rev-parse HEAD)" ]]; then
    if [[ ! -e .env && ! -L .env ]] || jq -e --arg release "$FRESH_RELEASE" \
        '."x-aegis-install-release" == $release' "$install_override" >/dev/null 2>&1; then
        release_install=true
        RELEASE_VERSION=$FRESH_RELEASE
    fi
elif [[ -s VERSION && ! -L VERSION ]]; then
    RELEASE_VERSION=$(<VERSION)
fi
if [[ $release_install == false && ! -e VERSION && -f $install_override && ! -L $install_override ]] &&
   jq -e --arg release "$FRESH_RELEASE" '."x-aegis-install-release" == $release' "$install_override" >/dev/null 2>&1; then
    log_error "Resume this installation from the v0.5.0 Git tag."
    exit 1
fi
print_banner

# ------------------------------------------------------------------------------
# 1. Initialize Runtime Directories
# ------------------------------------------------------------------------------
log_step 1 "Initializing Data Directories"

if [[ -L .env || ( -e .env && ! -f .env ) ]]; then
    log_error "Expected a regular .env file."; exit 1
fi
if [[ ! -f .env && -e aegis-data/db ]]; then
    if ! entries=$(ls -A -- aegis-data/db) || [[ -n $entries || ! -d aegis-data/db || -L aegis-data/db ]]; then
        log_error "Existing or unreadable database detected. Restore its matching .env before starting."
        exit 1
    fi
fi

if [[ $release_install == true ]]; then
    compose_help=$(docker compose up --help) && grep -Fq -- '--wait-timeout' <<< "$compose_help" ||
        { log_error "v0.5.0 requires Docker Compose with up --wait-timeout support."; exit 1; }
    prepare_release_install || { log_error "Could not prepare the v0.5.0 release for this installation."; exit 1; }
fi

mkdir -p aegis-config/agent
mkdir -p aegis-config/scripts
mkdir -p aegis-config/policy

if [ ! -f "aegis-config/policy/local_policy.yaml" ]; then
    install -m 0640 aegis-config/policy/local_policy.yaml.template aegis-config/policy/local_policy.yaml || exit 1
    log_task "Initialized WAF policy from the project template."
fi

if [ -f "aegis-config/advanced-model/open-appsec-advanced-model.tgz" ]; then
    chmod 640 aegis-config/advanced-model/open-appsec-advanced-model.tgz
    log_task "Secured Advanced ML Model binary."
fi

mkdir -p -m 0750 aegis-data aegis-logs || exit 1
mkdir -p -m 0750 aegis-data/{certs,db,learning,npm} || exit 1
mkdir -p -m 0755 aegis-logs/{npm,waf} || exit 1
log_task "Created data and log directories."



# ------------------------------------------------------------------------------
# 2. User Configuration Input (Unified)
# ------------------------------------------------------------------------------
log_step 2 "Unified Configuration Setup"

echo -e "   ${TXT_GRAY}Enter the NPM administrator account. New installations generate separate database credentials.${RESET}\n"

# 1. Master Email Input
while true; do
    log_input "NPM administrator email:"
    read -r MASTER_EMAIL || exit 1
    echo "" # Spacing after input
    
    if [[ "$MASTER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        break
    else
        log_warn "Invalid email format. Please try again."
        echo ""
    fi
done

# 2. Master Password Input (With Verification)
while true; do
    log_input "NPM administrator password:"
    read -rs MASTER_PASS_1 || exit 1
    echo "" # Newline for hidden input
    echo "" # Spacing gap

    if [[ -z $MASTER_PASS_1 || $MASTER_PASS_1 == changeme ]]; then
        log_warn "Enter a password other than the factory default."
        echo ""
        continue
    fi

    log_input "Confirm NPM administrator password:"
    read -rs MASTER_PASS_2 || exit 1
    echo "" # Newline for hidden input
    echo "" # Spacing gap

    if [ "$MASTER_PASS_1" == "$MASTER_PASS_2" ]; then
        MASTER_PASSWORD="$MASTER_PASS_1"
        log_success "Password verified."
        break
    else
        log_error "Passwords do not match. Please try again."
        echo ""
    fi
done

INPUT_EMAIL="$MASTER_EMAIL"
INPUT_NPM_PASS="$MASTER_PASSWORD"


# ------------------------------------------------------------------------------
# 3. Environment & Version Files
# ------------------------------------------------------------------------------
log_step 3 "Generating Environment Files"

if [[ -f .env ]]; then
    chmod go-rwx .env || exit 1
    log_info "Using existing .env and database credentials."
else
    (
        set -eu
        umask 077
        tmp=$(mktemp ./.env.install.XXXXXXXX) || exit 1
        trap 'rm -f -- "$tmp"' EXIT
        node - "$INPUT_EMAIL" > "$tmp" <<'NODE' || exit 1
const { randomBytes } = require('node:crypto');
const password = () => randomBytes(32).toString('hex');
console.log('AGENT_EMAIL=' + process.argv[2]);
console.log('DB_ROOT_PASSWORD=' + password());
console.log('NPM_DB_PASSWORD=' + password());
console.log('NPM_ADMIN_BIND=127.0.0.1');
NODE
        services=$(docker compose --env-file "$tmp" config --services) || exit 1
        if [[ $release_install == false ]] && grep -Fxq db <<< "$services"; then
            db_image=$(bash aegis-config/db-security/prepare.sh) || exit 1
            [[ $db_image =~ ^aegis-mariadb:local-[a-f0-9]{64}$ ]] || exit 1
            printf 'AEGIS_DB_IMAGE=%s\nAEGIS_DB_PULL_POLICY=never\n' "$db_image" >> "$tmp" || exit 1
        fi
        ln -- "$tmp" .env
    ) || { log_error "Could not create .env."; exit 1; }
    log_success "Generated independent database credentials in .env."
fi

if [[ $release_install == false && ! -s VERSION ]]; then
    printf '%s\n' "$RELEASE_VERSION" > VERSION || exit 1
fi


# ------------------------------------------------------------------------------
# 4. Policy Controller Setup
# ------------------------------------------------------------------------------
log_step 4 "Setting up Policy Controller"

# [Check] Ensure static script exists
if [ ! -f "aegis-config/scripts/policy_generator.js" ]; then
    log_error "File not found: aegis-config/scripts/policy_generator.js"
    echo -e "            Please ensure the policy generator script is present."
    exit 1
else
    log_success "Found policy_generator.js."
fi

log_task "Installing locked policy controller dependencies..."
npm ci --ignore-scripts --no-fund --prefix aegis-config/scripts || exit 1
log_success "Policy Controller dependencies installed."

if [[ $release_install == false && ! -e .aegis-update/images.json && ! -e docker-compose.override.yml && ! -L docker-compose.override.yml && ! -e .aegis-update/pending.json ]]; then
    # A resumed first install can already have .env but no initialized DB or services.
    existing=$(docker compose ps --all --quiet) || exit 1
    if [[ -z $existing ]] && entries=$(ls -A -- aegis-data/db) && [[ -z $entries ]]; then
        config="$PWD/aegis-config/logrotate/aegis-rotate.conf"
        if [[ -f $config && ! -L $config && -O $config && $(stat -c %h -- "$config") == 1 ]]; then
            chmod go-w -- "$config" || exit 1
        fi
        bash aegis-config/logrotate/prepare.sh --install \
            "$config" "$PWD/docker-compose.override.yml" || exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 5. Docker Service Startup & Account Config
# ------------------------------------------------------------------------------
log_step 5 "Docker Service Startup & Configuration"

while true; do
    log_input "Start services now? (Y/n):"
    read -r CONFIRM || exit 1
    echo "" 
    CONFIRM=${CONFIRM:-Y}
    case $CONFIRM in
        [yY]*)
            echo -e "   ${TXT_YELLOW}🔄 Starting Docker Compose...${RESET}"
            compose=(docker compose -f docker-compose.yml)
            [[ ! -f docker-compose.override.yml ]] || compose+=(-f docker-compose.override.yml)
            [[ ! -f .aegis-update/images.json ]] || compose+=(-f .aegis-update/images.json)
            for journal in .aegis-update/{pending,stack-pending,backup-pending}.json; do
                if [[ -e $journal || -L $journal ]]; then
                    log_error "Recover the unfinished operation with update.sh before starting services."
                    exit 1
                fi
            done
            startup=(-d)
            if [[ $release_install == true ]]; then
                pull_release_images || { log_error "Could not verify all v0.5.0 images."; exit 1; }
                startup+=(--pull never --wait --wait-timeout 180)
            fi
            "${compose[@]}" up "${startup[@]}" || { log_error "Docker launch failed."; exit 1; }
            
            echo ""
            log_success "Core services started."
            
            # --- [CRITICAL FIX: Initial Account Configuration] ---
            # Wait for NPM API
            published_admin=$("${compose[@]}" port npm 81) || exit 1
            admin_address=$published_admin
            case "$admin_address" in
                0.0.0.0:*) admin_address="127.0.0.1:${admin_address##*:}" ;;
                '[::]:'*) admin_address="[::1]:${admin_address##*:}" ;;
            esac
            NPM_API="http://$admin_address/api"
            check_api() {
                local count=0
                while [ $count -lt 90 ]; do
                    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$NPM_API/schema")
                    if [ "$code" == "200" ]; then return 0; fi
                    sleep 2
                    count=$((count+1))
                done
                return 1
            }
            
            execute_with_spinner "Waiting for NPM API to initialize..." check_api || { log_error "NPM API timed out."; exit 1; }
            
            # Helper to get token
            get_token() {
                local u=$1; local p=$2
                printf '%s' "$p" | jq -Rsc --arg u "$u" '{identity:$u, secret:.}' |
                    curl -sS --max-time 15 -X POST "$NPM_API/tokens" \
                    -H "Content-Type: application/json" \
                    --data-binary @-
            }

            # NPM 2.13+ exposes first-user setup on the admin listener.
            setup=$(curl -fsS --max-time 10 "$NPM_API/" | jq -r 'if has("setup") then .setup|tostring else "legacy" end') ||
                { log_error "Could not determine NPM setup state."; exit 1; }
            if [[ $setup == false ]]; then
                case "$published_admin" in
                    127.*:*|'[::1]:'*) ;;
                    *) log_error "Complete first-user setup on a loopback listener."; exit 1 ;;
                esac
                printf '%s' "$INPUT_NPM_PASS" | jq -Rsc --arg email "$INPUT_EMAIL" \
                    '{name:"Administrator",nickname:"Admin",email:$email,auth:{type:"password",secret:.}}' |
                    curl -fsS --max-time 20 -o /dev/null "$NPM_API/users" -H 'Content-Type: application/json' \
                    --data-binary @- || { log_error "Could not create the first NPM administrator."; exit 1; }
            fi
            
            token_for() {
                get_token "$1" "$2" | jq -er '.token | select(type == "string" and length > 0)'
            }
            log_task "Verifying the NPM administrator..."
            if ! token_for "$INPUT_EMAIL" "$INPUT_NPM_PASS" >/dev/null; then
                [[ $setup == legacy ]] || { log_error "Could not verify the administrator."; exit 1; }
                DEFAULT_USER="admin@example.com"
                DEFAULT_PASS="changeme"
                # A previous run can have changed the password before updating the email.
                if ! token=$(token_for "$DEFAULT_USER" "$INPUT_NPM_PASS"); then
                    token=$(token_for "$DEFAULT_USER" "$DEFAULT_PASS") ||
                        { log_error "Could not verify the NPM administrator."; exit 1; }
                    printf '%s' "$INPUT_NPM_PASS" | jq -Rsc --arg c "$DEFAULT_PASS" '{type:"password",secret:.,current:$c}' |
                        curl -fsS --max-time 15 -o /dev/null -X PUT "$NPM_API/users/1/auth" \
                        -H "Authorization: Bearer $token" -H "Content-Type: application/json" --data-binary @- || exit 1
                    token=$(token_for "$DEFAULT_USER" "$INPUT_NPM_PASS") || exit 1
                fi
                jq -nc --arg e "$INPUT_EMAIL" '{name:"Administrator",nickname:"Admin",email:$e}' |
                    curl -fsS --max-time 15 -o /dev/null -X PUT "$NPM_API/users/1" \
                    -H "Authorization: Bearer $token" -H "Content-Type: application/json" --data-binary @- || exit 1
                token_for "$INPUT_EMAIL" "$INPUT_NPM_PASS" >/dev/null ||
                    { log_error "Could not verify the configured administrator."; exit 1; }
            fi
            if [[ $release_install == true ]]; then
                record_fresh_install || { log_error "Could not record the installed version."; exit 1; }
            fi
            log_success "NPM administrator login verified."
            log_success "Installation Complete."
            
            # --- [Launch Verification] ---
            log_input "Run verification script (verify_all.sh) now? (Y/n):"
            read -r RUN_VERIFY || exit 0
            echo ""
            RUN_VERIFY=${RUN_VERIFY:-Y}
            
            if [[ "$RUN_VERIFY" =~ ^[yY] ]]; then
                if [ -f "./verify_all.sh" ]; then
                    chmod +x ./verify_all.sh
                    # Pass credentials to verify script
                    export MASTER_EMAIL="$INPUT_EMAIL"
                    export MASTER_PASSWORD="$INPUT_NPM_PASS"
                    ./verify_all.sh
                else
                    log_error "verify_all.sh not found."
                fi
            else
                echo -e "   ${TXT_CYAN}➜ Run './verify_all.sh' manually when ready.${RESET}"
                echo ""
            fi
            break ;;
        [nN]*) log_info "Installation aborted by user."; exit 0 ;;
        *) echo "   ${TXT_YELLOW}[WARN] Please enter Y or N.${RESET}" ;;
    esac
done
