#!/usr/bin/env bash

set -Eeuo pipefail
# System installers and APT keyrings need world-readable configuration files.
# Files containing credentials are explicitly restricted to mode 600 below.
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR

# ============================================================
# Zimbra 10 FOSS Automated Installer
# Supported OS: Ubuntu 22.04 LTS (Jammy) / Ubuntu 24.04 LTS (Noble)
# Ubuntu 22.04: Zimbra 10.1.20 (GA 0326.UBUNTU22_64.20260821115118)
# Ubuntu 24.04: Zimbra 10.1.20 (GA 0326.UBUNTU24_64.20260821120929)
# Firewall    : ConfigServer Security & Firewall (CSF + LFD)
#
# Usage:
#   sudo bash install-zimbra10.sh --domain example.com
# ============================================================

readonly ZCS_PACKAGES="zimbra-core zimbra-ldap zimbra-logger zimbra-mta zimbra-snmp zimbra-store zimbra-apache zimbra-spell zimbra-memcached zimbra-proxy"
readonly FIREWALL_PUBLIC_TCP_PORTS="25 80 443 465 587 993 995 7071"
IPV6_ENABLED=yes
readonly CSF_VERSION="15.10"
readonly CSF_URL="https://raw.githubusercontent.com/phongdh262/tools/main/csf.tgz"
readonly CSF_SHA256="788317da71d31a338da4cff3bdae9471137efc3978436692fe9d005eb70f54b3"
readonly CSF_TEMPLATE_URL="https://raw.githubusercontent.com/phongdh262/tools/main/csf.conf"
readonly CSF_TEMPLATE_SHA256="783a464ce084d429bffa4affcde646ac57d99f150b6b3c89fe4930470f33995c"
ADMIN_CIDR=""
CSF_CONF_SOURCE=""
LOCAL_IP=""
CSF_TEMPLATE=""
CSF_TGZ=""
FIREWALL_BACKUP=""
FIREWALL_PENDING=no
FIREWALL_TIMER=""
RESOLVER_BACKUP=""
RESOLVER_PENDING=no
HOST_CONFIG_BACKUP=""
HOST_CONFIG_PENDING=no
ONLY_FIREWALL=no
RESULT_FILE="/root/ZIMBRA-INSTALL-INFO.txt"

UBUNTU_CODENAME=""
ZCS_VERSION=""
ZCS_BUILD=""
ZCS_ARCHIVE=""
DEFAULT_ZCS_URL=""
DEFAULT_ZCS_SHA256=""

ZCS_SOURCE=""
ZCS_SHA256=""
ZCS_TGZ=""

DOMAIN=""
SERVER_IP=""
ADMIN_PASS=""
ADMIN_PASS_SOURCE=""
MAIL_HOST="mail"
TIMEZONE="Asia/Ho_Chi_Minh"
CONFIGURE_FIREWALL="yes"
SSH_PORT=""
FIREWALL_STATUS="not configured"
FIREWALL_ADMIN_ACCESS="not configured"
FIREWALL_RULES="not configured"
SYSTEM_ACCOUNTS_CHANGED="no"

LOG_FILE="/root/zimbra-auto-install.log"
DOWNLOAD_DIR="/root/zimbra-downloads"
WORKDIR=""
SOFTWARE_CONFIG_FILE=""
CONFIG_FILE=""

usage() {
    cat <<EOF
Usage:
  sudo bash $0 --domain example.com [options]

Supported Operating Systems:
  Ubuntu 22.04 LTS (Jammy)  -> Zimbra 10.1.20 GA
  Ubuntu 24.04 LTS (Noble)  -> Zimbra 10.1.20 GA

Required:
  --domain DOMAIN           Mail domain (for example: example.com)

Automatic defaults:
  Public IPv4 is detected from the VPS when --ip is omitted.
  A strong admin password is generated when no password option is set.
  Firewall: ConfigServer Security & Firewall (CSF + LFD) is installed and enabled.

Optional overrides:
  --ip IPV4                 Override the detected public IPv4 address
  --password PASSWORD       Deprecated: use --password-file to avoid process/history exposure
  --password-file FILE      Read the password from the first line of FILE
  ZIMBRA_ADMIN_PASSWORD     Environment variable password override
                            Supplied passwords must contain 14-256 characters,
                            contain no control characters, and not equal the
                            domain, FQDN, or administrator email address.

Optional:
  --csf-conf FILE           Use this existing csf.conf file after installing CSF
                            Default: csf.conf in the same directory as this script
  --admin-ip IP             Restrict Zimbra Admin Console (port 7071) to this IP or CIDR
                            Default: auto-detected from current SSH connection
  --local-ip IPV4           Local interface IPv4 (auto-detected; useful behind NAT)
  --skip-firewall           Do not configure or enable CSF firewall
  --only-firewall           Only configure CSF firewall (useful when Zimbra is already installed)
  --mail-host NAME          Hostname prefix (default: mail)
  --timezone ZONE           Timezone (default: Asia/Ho_Chi_Minh)
  --installer PATH_OR_URL   Local archive or download URL
  --sha256 HASH             Expected SHA-256 for the archive
  -h, --help                Show this help
EOF
}

log() {
    echo
    echo "============================================================"
    echo "[$(date '+%F %T')] $*"
    echo "============================================================"
}

summary_rule() {
    local character="${1:-=}"

    printf '%78s\n' '' | tr ' ' "$character"
}

summary_section() {
    echo
    printf '[ %s ]\n' "$1"
}

summary_field() {
    printf '  %-20s : %s\n' "$1" "$2"
}

print_install_summary() {
    summary_rule '='
    printf '%s\n' '                    ZIMBRA INSTALLATION COMPLETED'
    summary_rule '='

    summary_section "SYSTEM & OS"
    summary_field "OS" "Ubuntu ${VERSION_ID} (${UBUNTU_CODENAME})"
    summary_field "ZCS Version" "${ZCS_VERSION} GA (${ZCS_BUILD})"
    summary_field "Host backup" "$HOST_CONFIG_BACKUP"
    summary_field "Resolver backup" "$RESOLVER_BACKUP"

    summary_section "ADMIN LOGIN"
    summary_field "URL" "https://$FQDN:7071"
    summary_field "Username" "$ADMIN_EMAIL"
    if [[ "${1:-}" == "--include-password" ]]; then
        summary_field "Password" "$ADMIN_PASS"
    else
        summary_field "Credentials file" "$RESULT_FILE (root only)"
    fi

    summary_section "DKIM DNS RECORD"
    summary_field "Host / Name" "$DKIM_DNS_NAME"
    summary_field "Type" "TXT"
    summary_field "Value" "$DKIM_TXT_VALUE"

    summary_section "CSF FIREWALL CONFIGURATION"
    summary_field "Status" "$FIREWALL_STATUS"
    summary_field "SSH" "$SSH_PORT"
    printf '%s\n' "$FIREWALL_RULES" | sed 's/^/  /'

    summary_section "ZIMBRA SERVICE STATUS"
    printf '%s\n' "$STATUS" | sed 's/^/  /'

    echo
    summary_rule '='
    summary_field "Admin access" "$FIREWALL_ADMIN_ACCESS"
    printf '%s\n' 'Store the credentials file securely; do not include it in support logs.'
    summary_rule '='
}

parse_dkim_query() {
    local query_output="$1"
    local public_signature

    DKIM_SELECTOR=$(awk '
        /^DKIM Selector:$/ {
            getline
            print
            exit
        }
    ' <<< "$query_output")

    public_signature=$(awk '
        /^DKIM Public signature:$/ {
            capture = 1
            next
        }
        /^DKIM Identity:$/ {
            capture = 0
        }
        capture {
            print
        }
    ' <<< "$query_output")

    # Join the quoted DNS chunks into the single value expected by DNS UIs.
    DKIM_TXT_VALUE=$(printf '%s\n' "$public_signature" | \
        perl -0777 -ne 'my @parts = /"([^"]*)"/g; print join("", @parts);')

    [[ -n "$DKIM_SELECTOR" && "$DKIM_TXT_VALUE" == v=DKIM1\;* ]]
}

zimbra_account_exists() {
    local account="$1"

    su - zimbra -c \
        "/opt/zimbra/bin/zmprov -l ga '$account' zimbraAccountStatus" \
        >/dev/null 2>&1
}

zimbra_global_account_value() {
    local attribute="$1"

    su - zimbra -c \
        "/opt/zimbra/bin/zmprov -l gacf '$attribute'" 2>/dev/null | \
        awk -F ': ' -v attribute="$attribute" \
            '$1 == attribute { print $2; exit }'
}

ensure_zimbra_system_account() {
    local account="$1"
    local password="$2"
    local description="$3"
    local lifetime="${4:-}"
    local command

    if zimbra_account_exists "$account"; then
        echo "System account exists: $account"
        return
    fi

    command="/opt/zimbra/bin/zmprov -l ca '$account' '$password'"
    command+=" amavisBypassSpamChecks TRUE"
    command+=" zimbraAttachmentsIndexingEnabled FALSE"
    command+=" zimbraIsSystemAccount TRUE"
    command+=" zimbraIsSystemResource TRUE"
    command+=" zimbraHideInGal TRUE"
    command+=" zimbraMailQuota 0"
    [[ -z "$lifetime" ]] || \
        command+=" zimbraMailMessageLifetime '$lifetime'"
    command+=" description '$description'"

    su - zimbra -c "$command" || \
        die "Cannot create Zimbra system account: $account"

    zimbra_account_exists "$account" || \
        die "Zimbra system account verification failed: $account"

    SYSTEM_ACCOUNTS_CHANGED="yes"
    echo "Created system account: $account"
}

ensure_zimbra_system_accounts() {
    local current_spam
    local current_ham
    local current_quarantine

    log "Verify Zimbra system accounts"

    su - zimbra -c \
        "/opt/zimbra/bin/zmprov -l gd '$DOMAIN' zimbraDomainName" \
        >/dev/null 2>&1 || die "Zimbra domain was not created: $DOMAIN"

    zimbra_account_exists "$ADMIN_EMAIL" || \
        die "Zimbra admin account was not created: $ADMIN_EMAIL"

    ensure_zimbra_system_account \
        "$SPAM_ACCOUNT" "$SPAM_ACCOUNT_PASS" \
        "System account for spam training."
    ensure_zimbra_system_account \
        "$HAM_ACCOUNT" "$HAM_ACCOUNT_PASS" \
        "System account for non-spam training."
    ensure_zimbra_system_account \
        "$QUARANTINE_ACCOUNT" "$QUARANTINE_ACCOUNT_PASS" \
        "System account for antivirus quarantine." "30d"

    current_spam=$(zimbra_global_account_value zimbraSpamIsSpamAccount || true)
    current_ham=$(zimbra_global_account_value zimbraSpamIsNotSpamAccount || true)
    current_quarantine=$(zimbra_global_account_value zimbraAmavisQuarantineAccount || true)

    if [[ "$current_spam" != "$SPAM_ACCOUNT" || \
          "$current_ham" != "$HAM_ACCOUNT" || \
          "$current_quarantine" != "$QUARANTINE_ACCOUNT" ]]; then
        su - zimbra -c \
            "/opt/zimbra/bin/zmprov -l mcf \
            zimbraSpamIsSpamAccount '$SPAM_ACCOUNT' \
            zimbraSpamIsNotSpamAccount '$HAM_ACCOUNT' \
            zimbraAmavisQuarantineAccount '$QUARANTINE_ACCOUNT'" || \
            die "Cannot configure Zimbra spam and quarantine accounts"
        SYSTEM_ACCOUNTS_CHANGED="yes"
    fi

    [[ "$(zimbra_global_account_value zimbraSpamIsSpamAccount)" == \
        "$SPAM_ACCOUNT" ]] || die "Spam account configuration verification failed"
    [[ "$(zimbra_global_account_value zimbraSpamIsNotSpamAccount)" == \
        "$HAM_ACCOUNT" ]] || die "Ham account configuration verification failed"
    [[ "$(zimbra_global_account_value zimbraAmavisQuarantineAccount)" == \
        "$QUARANTINE_ACCOUNT" ]] || \
        die "Quarantine account configuration verification failed"

    if [[ "$SYSTEM_ACCOUNTS_CHANGED" == "yes" ]]; then
        echo "System account configuration repaired; restarting Zimbra services"
        su - zimbra -c 'zmcontrol restart' || \
            die "Zimbra restart failed after system account repair"
    else
        echo "Spam, ham and quarantine accounts are configured correctly."
    fi

    echo "Spam training    : $SPAM_ACCOUNT"
    echo "Ham training     : $HAM_ACCOUNT"
    echo "Virus quarantine : $QUARANTINE_ACCOUNT"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_value() {
    local option="$1"
    local count="$2"
    local value="${3:-}"

    (( count >= 2 )) || die "$option requires a value"
    [[ -n "$value" && "$value" != --* ]] || die "$option requires a value"
}

is_valid_ipv4() {
    local ip="$1"
    local octet
    local -a octets

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

is_valid_admin_network() {
    local target="$1" ip prefix
    if [[ "$target" =~ ^([0-9.]+)/([0-9]{1,2})$ ]]; then
        ip="${BASH_REMATCH[1]}"
        prefix="${BASH_REMATCH[2]}"
        is_valid_ipv4 "$ip" || return 1
        (( prefix >= 0 && prefix <= 32 )) || return 1
        return 0
    elif is_valid_ipv4 "$target"; then
        return 0
    elif [[ "$target" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]; then
        return 0
    fi
    return 1
}

detect_ssh_port() {
    local candidate=""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        candidate=$(awk '{print $4}' <<< "$SSH_CONNECTION")
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        candidate=$(awk '{print $3}' <<< "$SSH_CLIENT")
    elif command -v sshd >/dev/null 2>&1; then
        candidate=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
    fi

    [[ "$candidate" =~ ^[0-9]{1,5}$ ]] || candidate="22"
    (( 10#$candidate >= 1 && 10#$candidate <= 65535 )) || candidate="22"
    printf '%s' "$candidate"
}

detect_ubuntu_version() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found. Ubuntu 22.04 LTS or Ubuntu 24.04 LTS required."
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu required (found: ${ID:-unknown})"

    case "${VERSION_ID:-}" in
        "22.04")
            UBUNTU_CODENAME="jammy"
            ZCS_VERSION="10.1.20"
            ZCS_BUILD="0326.UBUNTU22_64.20260821115118"
            ZCS_ARCHIVE="zcs-${ZCS_VERSION}_GA_${ZCS_BUILD}.tgz"
            DEFAULT_ZCS_URL="https://github.com/phongdh262/tools/releases/download/zimbra-${ZCS_VERSION}/${ZCS_ARCHIVE}"
            DEFAULT_ZCS_SHA256="57c16b71a59fc34d2e1675d122ad9c702d464000b5222b434296a93b850aed75"
            ;;
        "24.04")
            UBUNTU_CODENAME="noble"
            ZCS_VERSION="10.1.20"
            ZCS_BUILD="0326.UBUNTU24_64.20260821120929"
            ZCS_ARCHIVE="zcs-${ZCS_VERSION}_GA_${ZCS_BUILD}.tgz"
            DEFAULT_ZCS_URL="https://github.com/phongdh262/tools/releases/download/zimbra-${ZCS_VERSION}-u24/${ZCS_ARCHIVE}"
            DEFAULT_ZCS_SHA256="07bbd4662e3f5211986c71b68cf2fe28b2185bd3c796ad8a69c8c10a6ef2fa69"
            ;;
        *)
            die "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Supported: 22.04, 24.04"
            ;;
    esac

    if [[ -z "$ZCS_SOURCE" ]]; then
        ZCS_SOURCE="$DEFAULT_ZCS_URL"
    fi
    if [[ -z "$ZCS_SHA256" ]]; then
        [[ "$ZCS_SOURCE" == "$DEFAULT_ZCS_URL" ]] || die "Custom installer requires --sha256"
        ZCS_SHA256="$DEFAULT_ZCS_SHA256"
    fi
}

detect_server_ipv4() {
    local candidate
    local endpoint

    for endpoint in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://checkip.amazonaws.com"; do
        candidate=$(curl \
            --ipv4 \
            --fail \
            --silent \
            --connect-timeout 5 \
            --max-time 10 \
            "$endpoint" 2>/dev/null || true)
        candidate=${candidate//[[:space:]]/}

        if is_valid_ipv4 "$candidate" && [[ "$candidate" != 127.* ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    # Fallback for VPS providers that block public IP lookup services.
    candidate=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "src") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ')

    if is_valid_ipv4 "$candidate" && [[ "$candidate" != 127.* ]]; then
        printf '%s' "$candidate"
        return 0
    fi

    return 1
}

is_valid_domain() {
    local domain="$1"
    local label
    local -a labels

    (( ${#domain} <= 253 )) || return 1
    [[ "$domain" == *.* && "$domain" != *..* && "$domain" != *. ]] || return 1
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        (( ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

validate_fqdn() {
    local fqdn="$1"
    local fqdn_lower

    (( ${#fqdn} <= 253 )) || die "FQDN exceeds 253 characters: $fqdn"
    is_valid_domain "$fqdn" || die "Invalid FQDN: $fqdn"
    fqdn_lower=$(printf '%s' "$fqdn" | tr '[:upper:]' '[:lower:]')
    [[ "$fqdn_lower" != "localhost" && "$fqdn_lower" != *.localhost ]] || \
        die "FQDN must not use the reserved localhost domain: $fqdn"
}

validate_admin_password() {
    local password="$1"
    local password_lower domain_lower admin_email_lower fqdn_lower
    local LC_ALL=C

    (( ${#password} >= 14 )) || \
        die "Admin password must contain at least 14 characters"
    (( ${#password} <= 256 )) || \
        die "Admin password must not exceed 256 characters"
    [[ ! "$password" =~ [[:cntrl:]] ]] || \
        die "Admin password must not contain control characters"

    password_lower=$(printf '%s' "$password" | tr '[:upper:]' '[:lower:]')
    domain_lower=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
    admin_email_lower=$(printf '%s' "$ADMIN_EMAIL" | tr '[:upper:]' '[:lower:]')
    fqdn_lower=$(printf '%s' "$FQDN" | tr '[:upper:]' '[:lower:]')
    [[ "$password_lower" != "$domain_lower" && \
       "$password_lower" != "$admin_email_lower" && \
       "$password_lower" != "$fqdn_lower" ]] || \
        die "Admin password must not equal the domain, FQDN, or admin address"
}

read_admin_password_file() {
    local file="$1"
    local mode

    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || \
        die "Password file must be a readable regular file, not a symlink: $file"
    mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null) || \
        die "Cannot inspect password file permissions: $file"
    (( (8#$mode & 077) == 0 )) || \
        die "Password file must not be accessible by group or other users: $file"

    IFS= read -r ADMIN_PASS < "$file" || true
    [[ -n "$ADMIN_PASS" ]] || die "Password file is empty: $file"
}

check_fqdn_dns_safety() {
    local addresses

    addresses=$(
        {
            timeout 10 getent ahostsv4 "$FQDN" 2>/dev/null || true
            timeout 10 getent ahostsv6 "$FQDN" 2>/dev/null || true
        } | awk '{print $1}' | sort -u
    )
    if grep -Eq '^(127\.|0\.0\.0\.0$|::1$|::$)' <<< "$addresses"; then
        die "FQDN $FQDN resolves to a loopback or unspecified address"
    fi
}

report_ptr_status() {
    local ptr
    local fqdn_lower

    ptr=$(dig @1.1.1.1 +short +time=3 +tries=1 -x "$SERVER_IP" 2>/dev/null | \
        head -1 | sed 's/\.$//' | tr '[:upper:]' '[:lower:]' || true)
    fqdn_lower=$(printf '%s' "$FQDN" | tr '[:upper:]' '[:lower:]')
    if [[ -z "$ptr" ]]; then
        echo "WARNING: No public PTR record found for $SERVER_IP; configure it as $FQDN with the VPS provider."
    elif [[ "$ptr" != "$fqdn_lower" ]]; then
        echo "WARNING: PTR for $SERVER_IP is $ptr; recommended value: $FQDN"
    else
        echo "PTR record      : $SERVER_IP -> $ptr"
    fi
}

escape_config_value() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

installer_is_valid() {
    local archive="$1"

    verify_sha256 "$archive" "$ZCS_SHA256" && tar -tzf "$archive" >/dev/null
}

verify_installer() {
    local archive="$1"

    installer_is_valid "$archive" || \
        die "SHA-256 verification failed or archive is corrupt: $archive"
}

patch_zimbra_installer() {
    local utilfunc="$1/util/utilfunc.sh"
    # shellcheck disable=SC2016
    local unsafe_condition='if [ $P7ZIPREQUIRED = "yes" ]; then'
    # shellcheck disable=SC2016
    local safe_condition='if [ "${P7ZIPREQUIRED:-no}" = "yes" ]; then'
    local unsafe_count

    [[ -f "$utilfunc" ]] || \
        die "Bundled Zimbra utility is missing: $utilfunc"

    if grep -Fq "$safe_condition" "$utilfunc"; then
        echo "Bundled installer P7ZIP condition is already safe."
        return
    fi

    unsafe_count=$(grep -Fc "$unsafe_condition" "$utilfunc" || true)
    [[ "$unsafe_count" == "1" ]] || \
        die "Unexpected P7ZIP condition in bundled Zimbra installer"

    # shellcheck disable=SC2016
    sed -i.zimbra-auto-backup \
        's/if \[ \$P7ZIPREQUIRED = "yes" \]; then/if [ "${P7ZIPREQUIRED:-no}" = "yes" ]; then/' \
        "$utilfunc"
    rm -f -- "${utilfunc}.zimbra-auto-backup"

    grep -Fq "$safe_condition" "$utilfunc" || \
        die "Cannot patch bundled Zimbra P7ZIP condition"
    bash -n "$utilfunc" || \
        die "Bundled Zimbra utility failed syntax validation after patching"

    echo "Patched bundled installer: initialized empty P7ZIPREQUIRED as no."
}

prepare_installer() {
    local download_tmp

    [[ ! "$ZCS_SOURCE" =~ ^http:// ]] || die "Installer URL must use HTTPS"

    if [[ "$ZCS_SOURCE" =~ ^https:// ]]; then
        mkdir -p "$DOWNLOAD_DIR"
        ZCS_TGZ="${DOWNLOAD_DIR}/${ZCS_ARCHIVE}"

        if [[ -f "$ZCS_TGZ" ]] && installer_is_valid "$ZCS_TGZ"; then
            log "Use verified cached Zimbra archive"
            return
        fi

        if [[ -e "$ZCS_TGZ" ]]; then
            mv -- "$ZCS_TGZ" "${ZCS_TGZ}.invalid.$(date +%s)"
        fi

        log "Download Zimbra ${ZCS_VERSION}"
        download_tmp=$(mktemp "${DOWNLOAD_DIR}/.${ZCS_ARCHIVE}.part.XXXXXX")
        if ! curl \
            --fail \
            --location \
            --proto '=https' \
            --retry 5 \
            --retry-all-errors \
            --connect-timeout 20 \
            --output "$download_tmp" \
            "$ZCS_SOURCE"; then
            rm -f -- "$download_tmp"
            die "Cannot download Zimbra archive: $ZCS_SOURCE"
        fi

        if ! installer_is_valid "$download_tmp"; then
            rm -f -- "$download_tmp"
            die "SHA-256 verification failed or downloaded archive is corrupt"
        fi
        mv -- "$download_tmp" "$ZCS_TGZ"
    else
        ZCS_TGZ="$ZCS_SOURCE"
        [[ -f "$ZCS_TGZ" ]] || die "Cannot find Zimbra archive: $ZCS_TGZ"
        verify_installer "$ZCS_TGZ"
    fi
}

check_zimbra_repository() {
    local repository_path
    local repository_url

    for repository_path in 87 1000 1010; do
        repository_url="https://repo.zimbra.com/apt/${repository_path}/dists/${UBUNTU_CODENAME}/Release"
        curl \
            --fail \
            --location \
            --silent \
            --show-error \
            --connect-timeout 10 \
            --max-time 30 \
            --output /dev/null \
            "$repository_url" || \
            die "Cannot access the Zimbra APT repository: $repository_url"
    done
}

repair_zimbra_apt_keyring_permissions() {
    local keyring="/etc/apt/trusted.gpg.d/zimbra.gpg"

    [[ -f "$keyring" ]] || return 0

    chown root:root /etc/apt /etc/apt/trusted.gpg.d "$keyring"
    chmod 755 /etc/apt /etc/apt/trusted.gpg.d
    chmod 644 "$keyring"

    if ! su -s /bin/sh _apt -c "test -r '$keyring'"; then
        echo "APT keyring path permissions:"
        namei -l "$keyring" || true
        die "User _apt still cannot read the Zimbra keyring"
    fi
}

fetch_reference_epoch() {
    local date_header
    local endpoint
    local epoch
    local -a epochs=()

    for endpoint in \
        "https://archive.ubuntu.com/ubuntu/dists/${UBUNTU_CODENAME}-security/InRelease" \
        "https://repo.zimbra.com/apt/1010/dists/${UBUNTU_CODENAME}/Release" \
        "https://api.github.com"; do
        date_header=""

        if command -v curl >/dev/null 2>&1; then
            date_header=$(curl \
                --head \
                --location \
                --fail \
                --silent \
                --show-error \
                --connect-timeout 5 \
                --max-time 15 \
                "$endpoint" 2>/dev/null | \
                tr -d '\r' | \
                awk 'tolower($1) == "date:" {
                    $1 = ""
                    sub(/^ /, "")
                    value = $0
                } END {print value}')
        elif command -v wget >/dev/null 2>&1; then
            date_header=$(wget \
                --server-response \
                --spider \
                --timeout=15 \
                "$endpoint" 2>&1 | \
                tr -d '\r' | \
                awk 'tolower($1) == "date:" {
                    $1 = ""
                    sub(/^ /, "")
                    value = $0
                } END {print value}')
        fi

        if [[ -n "$date_header" ]]; then
            epoch=$(date -u --date="$date_header" +%s 2>/dev/null || true)
            [[ "$epoch" =~ ^[0-9]{10,}$ ]] && epochs+=("$epoch")
        fi
    done

    (( ${#epochs[@]} >= 2 )) || return 1
    local minimum maximum
    minimum=$(printf '%s\n' "${epochs[@]}" | sort -n | head -1)
    maximum=$(printf '%s\n' "${epochs[@]}" | sort -n | tail -1)
    (( maximum - minimum <= 60 )) || return 1

    printf '%s\n' "${epochs[@]}" | sort -n | \
        awk '{values[NR] = $1} END {print values[int((NR + 1) / 2)]}'
}

synchronize_system_clock() {
    local attempt=1
    local clock_offset=0
    local clock_source="NTP"
    local local_epoch
    local ntp_synchronized="no"
    local reference_epoch=""

    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Unknown timezone: $TIMEZONE"
    timedatectl set-timezone "$TIMEZONE"
    timedatectl set-local-rtc 0 2>/dev/null || true

    log "Configure timezone and synchronize system clock"

    timedatectl set-ntp true 2>/dev/null || true

    if command -v chronyc >/dev/null 2>&1; then
        systemctl enable --now chrony 2>/dev/null || true
        chronyc -a makestep 2>/dev/null || true
    elif systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
        systemctl enable --now systemd-timesyncd 2>/dev/null || true
        systemctl restart systemd-timesyncd 2>/dev/null || true
    fi

    while (( attempt <= 30 )); do
        ntp_synchronized=$(timedatectl show \
            --property=NTPSynchronized \
            --value 2>/dev/null || true)

        if [[ "$ntp_synchronized" == "yes" ]]; then
            break
        fi

        sleep 2
        (( attempt++ ))
    done

    # A cached HTTP Date must never override an already synchronized NTP clock.
    if [[ "$ntp_synchronized" != yes ]]; then reference_epoch=$(fetch_reference_epoch || true); fi

    if [[ "$reference_epoch" =~ ^[0-9]{10,}$ ]]; then
        local_epoch=$(date -u +%s)
        clock_offset=$(( reference_epoch - local_epoch ))

        if (( clock_offset < -60 || clock_offset > 60 )); then
            echo "WARNING: NTP clock differs from trusted HTTPS time by ${clock_offset} seconds."
            timedatectl set-ntp false 2>/dev/null || true
            date --utc --set="@${reference_epoch}" >/dev/null || \
                die "Cannot correct the VPS clock; ask the VPS provider to fix host time"
            hwclock --systohc --utc 2>/dev/null || true
            clock_source="HTTPS median correction"
            ntp_synchronized="temporarily disabled until Chrony starts"
        fi
    else
        clock_source="NTP (HTTPS validation unavailable)"
    fi

    echo "Timezone         : $TIMEZONE ($(date '+%:z'))"
    echo "Local time       : $(date '+%F %T %Z')"
    echo "UTC time         : $(date -u '+%F %T UTC')"
    echo "NTP synchronized : $ntp_synchronized"
    echo "Clock source     : $clock_source"
    echo "HTTPS offset     : ${clock_offset} seconds"

    if [[ "$ntp_synchronized" != "yes" ]]; then
        echo "WARNING: NTP has not confirmed synchronization; APT will perform the final clock validity check."
    fi
}

verify_sha256() {
    local file="$1" expected="$2"
    [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(sha256sum -- "$file" | awk '{print $1}')" == "$expected" ]]
}

fetch_verified() {
    local url="$1" expected="$2" destination="$3"
    local temporary
    temporary=$(mktemp "${destination}.part.XXXXXX")
    if ! curl --fail --location --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 15 --max-time 1200 \
        --output "$temporary" "$url"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! verify_sha256 "$temporary" "$expected"; then
        rm -f -- "$temporary"
        return 1
    fi
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$destination"
}

validate_csf_template() {
    perl - "$1" <<'PERL'
use strict;
use warnings;
my %seen;
while (<>) {
    next if /^\s*(?:#|$)/;
    /^([A-Za-z][A-Za-z0-9_]*)\s*=\s*"([^"\r\n]*)"\s*$/ or die "Invalid CSF configuration line $.\n";
    die "Duplicate CSF key: $1\n" if $seen{$1}++;
}
for my $key (qw(TESTING TCP_IN TCP_OUT TCP6_IN TCP6_OUT UDP_IN UDP_OUT UDP6_IN UDP6_OUT IPV6 UI)) {
    die "Missing CSF key: $key\n" unless $seen{$key};
}
PERL
}

set_csf_value() {
    local file="$1" key="$2" value="$3"
    CSF_KEY="$key" CSF_VALUE="$value" perl -i -pe '
        if (/^\Q$ENV{CSF_KEY}\E\s*=/) {
            $_ = "$ENV{CSF_KEY} = \"$ENV{CSF_VALUE}\"\n"; $found = 1;
        }
        END {die "Missing CSF key $ENV{CSF_KEY}\n" unless $found}
    ' "$file"
}

remove_csf_tcp_port() {
    local file="$1" port="$2"
    CSF_REMOVE_PORT="$port" perl -i -pe '
        if (/^(TCP_IN|TCP6_IN)\s*=\s*"([^"]*)"/) {
            my $key = $1;
            my @ports = grep { $_ ne $ENV{CSF_REMOVE_PORT} } split(/\s*,\s*/, $2);
            $_ = "$key = \"" . join(",", @ports) . "\"\n";
        }
    ' "$file"
}

add_csf_tcp_ports() {
    local file="$1" ports="$2"
    CSF_REQUIRED_PORTS="$ports" perl -i -pe '
        if (/^(TCP_IN|TCP6_IN)\s*=\s*"([^"]*)"/) {
            my $key = $1;
            my %ports = map { $_ => 1 }
                grep { /^\d+(?::\d+)?$/ } split(/\s*,\s*/, $2);
            for my $port (split(/,/, $ENV{CSF_REQUIRED_PORTS})) {
                $ports{$port} = 1 if $port =~ /^\d+$/;
            }
            my @sorted = sort {
                (split(/:/, $a))[0] <=> (split(/:/, $b))[0]
            } keys %ports;
            $_ = "$key = \"" . join(",", @sorted) . "\"\n";
        }
    ' "$file"
}

build_csf_config() {
    local template="$1" output="$2" ports="$3"
    validate_csf_template "$template" || return 1
    # Use the supplied configuration as the complete replacement. Only enforce
    # settings needed to activate it safely and keep required public/SSH ports.
    install -m 600 "$template" "$output"
    if [[ -n "$ADMIN_CIDR" ]]; then
        remove_csf_tcp_port "$output" 7071
    fi
    add_csf_tcp_ports "$output" "$ports"
    set_csf_value "$output" TESTING 0
    if [[ "$IPV6_ENABLED" == yes ]]; then set_csf_value "$output" IPV6 1
    else set_csf_value "$output" IPV6 0; fi
    validate_csf_template "$output"
}

write_zimbra_auth_module() {
    cat > "$1" <<'PERL'
package ZimbraAuth;
use strict;
use warnings;
use Socket qw(AF_INET AF_INET6 inet_pton);
sub match {
    my ($line, $file) = @_;
    return unless $file eq '/opt/zimbra/log/audit.log';
    # Only accept the address in Zimbra's structured metadata, never a username,
    # error message or client-supplied forwarded address. Do not ban the proxy.
    return unless $line =~ /^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d+\s+\S+\s+\[[^\]\r\n]*\]\s+\[([^\]\r\n]*)\]\s+security - .*\berror=authentication failed\b/;
    my $metadata = $1;
    my @addresses = $metadata =~ /(?:^|;)ip=([^;]+)(?=;|$)/g;
    return unless @addresses == 1;
    my $ip = $addresses[0];
    my $packed = inet_pton(AF_INET, $ip) // inet_pton(AF_INET6, $ip);
    return unless defined $packed;
    return if $ip =~ /^127\./ || $ip eq '::1' || $ip eq '0.0.0.0' || $ip eq '::';
    return ('Failed Zimbra authentication from', $ip, 'zimbraauth', 5,
            '443,993,995,7071', 300, 0);
}
1;
PERL
}

install_zimbra_lfd_filter() {
    local custom=/usr/local/csf/bin/regex.custom.pm
    [[ -f "$custom" ]] || die "Missing CSF custom regex hook"
    write_zimbra_auth_module /usr/local/csf/bin/zimbra-auth.pm
    chmod 600 /usr/local/csf/bin/zimbra-auth.pm
    if ! grep -q 'ZIMBRA_AUTO_AUTH_HOOK' "$custom"; then
        perl -0777 -i -pe '
            $n = s/(sub custom_line\s*\{)/$1\n    # ZIMBRA_AUTO_AUTH_HOOK\n    require "\/usr\/local\/csf\/bin\/zimbra-auth.pm";\n    my \@zimbra_match = ZimbraAuth::match(\@_);\n    return \@zimbra_match if \@zimbra_match;\n/;
            die "Unexpected CSF custom_line format\n" unless $n == 1;
        ' "$custom"
    fi
    perl -c /usr/local/csf/bin/zimbra-auth.pm
    perl -c "$custom"
}

prepare_firewall_assets() {
    local local_csf_conf
    install -d -m 700 "$DOWNLOAD_DIR"
    CSF_TEMPLATE="$DOWNLOAD_DIR/csf-template.conf"
    local_csf_conf="${CSF_CONF_SOURCE:-$SCRIPT_DIR/csf.conf}"
    if [[ -e "$local_csf_conf" ]]; then
        [[ -f "$local_csf_conf" && ! -L "$local_csf_conf" ]] || \
            die "CSF configuration must be a regular file, not a symlink: $local_csf_conf"
        install -m 600 "$local_csf_conf" "$CSF_TEMPLATE"
        echo "Using uploaded CSF configuration: $local_csf_conf"
        echo "CSF configuration SHA-256: $(sha256sum -- "$local_csf_conf" | awk '{print $1}')"
    else
        [[ -z "$CSF_CONF_SOURCE" ]] || die "Cannot find CSF configuration: $CSF_CONF_SOURCE"
        fetch_verified "$CSF_TEMPLATE_URL" "$CSF_TEMPLATE_SHA256" "$CSF_TEMPLATE" || \
            die "Cannot download and verify CSF template"
        echo "Using verified repository CSF configuration"
    fi
    validate_csf_template "$CSF_TEMPLATE" || die "Invalid CSF template"
    if ! command -v csf >/dev/null 2>&1; then
        CSF_TGZ="$DOWNLOAD_DIR/csf-${CSF_VERSION}.tgz"
        if [[ -f "$SCRIPT_DIR/csf.tgz" ]] && verify_sha256 "$SCRIPT_DIR/csf.tgz" "$CSF_SHA256"; then
            install -m 600 "$SCRIPT_DIR/csf.tgz" "$CSF_TGZ"
            echo "Using local verified CSF archive: $SCRIPT_DIR/csf.tgz"
        elif ! verify_sha256 "$CSF_TGZ" "$CSF_SHA256"; then
            fetch_verified "$CSF_URL" "$CSF_SHA256" "$CSF_TGZ" || die "Cannot download and verify CSF"
        fi
        tar -tzf "$CSF_TGZ" >/dev/null || die "Corrupt CSF archive"
    fi
}

snapshot_firewall() {
    FIREWALL_BACKUP=$(mktemp -d /root/zimbra-firewall-backup.XXXXXX)
    chmod 700 "$FIREWALL_BACKUP"
    iptables-save > "$FIREWALL_BACKUP/ipv4.rules"
    if [[ "$IPV6_ENABLED" == yes ]]; then ip6tables-save > "$FIREWALL_BACKUP/ipv6.rules"; fi
    local service
    for service in csf lfd ufw firewalld; do
        systemctl is-enabled "$service" > "$FIREWALL_BACKUP/$service.state" 2>/dev/null || true
        systemctl is-active --quiet "$service" && touch "$FIREWALL_BACKUP/$service.active"
        systemctl is-enabled --quiet "$service" && touch "$FIREWALL_BACKUP/$service.enabled"
    done
    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep -q '^Status: active'; then
        touch "$FIREWALL_BACKUP/ufw.active"
    fi
    [[ ! -d /etc/csf ]] || cp -a /etc/csf "$FIREWALL_BACKUP/csf"
    [[ ! -d /etc/ufw ]] || cp -a /etc/ufw "$FIREWALL_BACKUP/ufw"
    [[ ! -f /etc/default/ufw ]] || cp -a /etc/default/ufw "$FIREWALL_BACKUP/ufw.default"
    [[ ! -f /usr/local/csf/bin/regex.custom.pm ]] || \
        cp -a /usr/local/csf/bin/regex.custom.pm "$FIREWALL_BACKUP/regex.custom.pm"
    [[ ! -f /usr/local/csf/bin/zimbra-auth.pm ]] || \
        cp -a /usr/local/csf/bin/zimbra-auth.pm "$FIREWALL_BACKUP/zimbra-auth.pm"
    printf '%s\n' "$$" > "$FIREWALL_BACKUP/installer.pid"
    awk '{print $22}' /proc/$$/stat > "$FIREWALL_BACKUP/installer.start"
    cat > "$FIREWALL_BACKUP/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
set -u
cd -- "$(dirname -- "$0")" || exit 1
# Serialise rollback and the installer's final commit, including timer races.
exec 9>transaction.lock
flock 9
[[ ! -e committed && ! -e rolled-back ]] || exit 0
if [[ "${1:-}" == --watchdog ]]; then
    pid=$(cat installer.pid)
    if [[ -f /proc/$pid/stat ]] && [[ "$(awk '{print $22}' /proc/"$pid"/stat)" == "$(cat installer.start)" ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        pkill -TERM -P "$pid" 2>/dev/null || true
    fi
fi
failed=0
if [[ ! -d csf ]] && command -v csf >/dev/null; then csf -x || failed=1; fi
systemctl stop lfd csf 2>/dev/null || true
systemctl disable lfd csf 2>/dev/null || true
if [[ -d csf ]]; then
    rm -rf /etc/csf
    cp -a csf /etc/csf || failed=1
fi
for file in regex.custom.pm zimbra-auth.pm; do
    if [[ -f "$file" ]]; then cp -a "$file" "/usr/local/csf/bin/$file" || failed=1
    else rm -f "/usr/local/csf/bin/$file"; fi
done
if [[ -d ufw ]]; then
    rm -rf /etc/ufw
    cp -a ufw /etc/ufw || failed=1
fi
[[ ! -f ufw.default ]] || cp -a ufw.default /etc/default/ufw || failed=1
for service in csf lfd ufw firewalld; do
    if [[ "$(cat "$service.state")" == masked ]]; then
        systemctl mask "$service" || failed=1
        continue
    fi
    systemctl unmask "$service" 2>/dev/null || true
    if [[ -f "$service.enabled" ]]; then systemctl enable "$service" || failed=1
    else systemctl disable "$service" 2>/dev/null || true; fi
    if [[ -f "$service.active" ]]; then systemctl restart "$service" || failed=1
    else systemctl stop "$service" 2>/dev/null || true; fi
done
# Restore the exact kernel rules after service commands have changed them.
iptables-restore -w 10 < ipv4.rules || failed=1
if [[ -f ipv6.rules ]]; then ip6tables-restore -w 10 < ipv6.rules || failed=1; fi
if (( failed )); then echo "Firewall rollback incomplete; inspect $PWD" >&2; exit 1; fi
touch rolled-back
ROLLBACK
    chmod 700 "$FIREWALL_BACKUP/rollback.sh"
    FIREWALL_TIMER="zimbra-firewall-rollback-$$"
    FIREWALL_PENDING=yes
    systemd-run --quiet --unit="$FIREWALL_TIMER" --on-active=10m \
        /bin/bash "$FIREWALL_BACKUP/rollback.sh" --watchdog
}

commit_firewall() {
    (
        flock 9
        [[ ! -e "$FIREWALL_BACKUP/rolled-back" ]] || exit 1
        touch "$FIREWALL_BACKUP/committed"
    ) 9>"$FIREWALL_BACKUP/transaction.lock" || die "Firewall watchdog already restored the previous rules"
    FIREWALL_PENDING=no
    systemctl stop "${FIREWALL_TIMER}.timer" || true
    echo "Firewall backup: $FIREWALL_BACKUP"
}

configure_csf() {
    local csf_work compatibility ports config_tmp admin_client
    log "Configure CSF firewall"
    systemctl is-active --quiet firewalld && die "firewalld is active; migrate it explicitly before using CSF"
    [[ -s "$CSF_TEMPLATE" ]] || die "CSF assets were not prepared"
    if [[ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || \
        [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == 1 ]]; then IPV6_ENABLED=no; fi
    # Preserve every configured/listening SSH port, including socket activation.
    if [[ -n "$ADMIN_CIDR" ]]; then
        ports="$(printf '%s\n' "$FIREWALL_PUBLIC_TCP_PORTS" | sed 's/\b7071\b//') $(detect_ssh_port)"
    else
        ports="$FIREWALL_PUBLIC_TCP_PORTS $(detect_ssh_port)"
    fi
    if command -v sshd >/dev/null 2>&1; then
        ports+=" $(sshd -T | awk '$1 == "port" {print $2}')"
    fi
    ports+=" $(systemctl show ssh.socket --property=Listen --value 2>/dev/null | awk '{n=split($1,a,":"); print a[n]}' || true)"
    ports+=" $(ss -H -lntp | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}')"
    ports=$(printf '%s\n' "$ports" | tr ' ' '\n' | awk '/^[0-9]+$/ && $1 > 0 && $1 < 65536' | sort -nu | paste -sd, -)
    [[ -z "$ADMIN_CIDR" ]] || is_valid_admin_network "$ADMIN_CIDR" || die "Invalid administrator IP/CIDR: $ADMIN_CIDR"
    snapshot_firewall
    if ! command -v csf >/dev/null 2>&1; then
        csf_work=$(mktemp -d "$DOWNLOAD_DIR/csf-install.XXXXXX")
        tar -xzf "$CSF_TGZ" --no-same-owner -C "$csf_work"
        [[ -f "$csf_work/csf/install.sh" ]] || die "Missing verified CSF installer"
        (cd "$csf_work/csf" && sh install.sh)
        rm -rf -- "$csf_work"
    fi
    command -v csf >/dev/null || die "CSF installation failed"

    # Apply the single staged copy that prepare_firewall_assets already checked.
    # This avoids a second download, checksum bypass, and source-file TOCTOU.
    log "Apply verified CSF configuration"
    install -m 600 "$CSF_TEMPLATE" /etc/csf/csf.conf

    [[ -f /usr/local/csf/bin/csftest.pl ]] || die "CSF compatibility test is missing"
    compatibility=$(perl /usr/local/csf/bin/csftest.pl) || die "CSF compatibility test failed"
    printf '%s\n' "$compatibility"
    # csftest.pl can report FATAL while returning exit code zero.
    grep -q 'RESULT: csf \(should function\|will function\)' <<< "$compatibility" || \
        die "CSF cannot function with this host's firewall modules"
    config_tmp=$(mktemp /etc/csf/.csf.conf.XXXXXX)
    build_csf_config /etc/csf/csf.conf "$config_tmp" "$ports"
    chmod 600 "$config_tmp"
    mv -f -- "$config_tmp" /etc/csf/csf.conf
    # Clean up old temporary admin rules; restrict 7071 only if an admin IP was explicitly specified
    touch /etc/csf/csf.allow
    sed -i '/ # zimbra-auto-admin$/d' /etc/csf/csf.allow
    if [[ -n "$ADMIN_CIDR" ]]; then
        printf 'tcp|in|d=7071|s=%s # zimbra-auto-admin\n' "$ADMIN_CIDR" >> /etc/csf/csf.allow
        FIREWALL_ADMIN_ACCESS="7071/tcp restricted to $ADMIN_CIDR"
    else
        FIREWALL_ADMIN_ACCESS="7071/tcp open (unrestricted)"
    fi
    install_zimbra_lfd_filter
    if command -v ufw >/dev/null 2>&1; then
        ufw disable
        systemctl disable --now ufw
    fi
    csf -e
    csf -r
    systemctl enable csf lfd
    systemctl restart lfd
    systemctl is-active --quiet lfd || die "LFD did not start"
    [[ ! -s /etc/csf/csf.error ]] || die "CSF reported an error; restoring previous firewall"
    # Check effective IPv4 AND IPv6 policy and required public/SSH rules.
    verify_firewall_rules "$ports"
    getent ahostsv4 repo.zimbra.com >/dev/null || die "DNS failed after firewall activation"
    commit_firewall
    FIREWALL_STATUS="active (CSF + LFD)"
    SSH_PORT="$(detect_ssh_port)/tcp; all detected SSH ports preserved"
    FIREWALL_RULES=$(grep -E '^(TCP6?_IN|TCP6?_OUT|UDP6?_IN|UDP6?_OUT) =' /etc/csf/csf.conf)
    printf '%s\n' "$FIREWALL_RULES"
    echo "Administrator access: $FIREWALL_ADMIN_ACCESS"
}

verify_firewall_rules() {
    local ports="$1" command port rules
    for command in iptables ip6tables; do
        [[ "$command" != ip6tables || "$IPV6_ENABLED" == yes ]] || continue
        rules=$("$command" -S)
        grep -q -- '^-P INPUT DROP$' <<< "$rules" || die "$command INPUT is not protected"
        for port in ${ports//,/ }; do
            grep -Eq -- "^-A INPUT .*--dport ${port} .* -j ACCEPT$|^-A INPUT .*--dport ${port} -j ACCEPT$" <<< "$rules" || \
                die "Missing effective $command rule for TCP port $port"
        done
    done
}

snapshot_resolver() {
    [[ -z "$RESOLVER_BACKUP" ]] || return 0
    RESOLVER_BACKUP=$(mktemp -d /root/zimbra-resolver-backup.XXXXXX)
    [[ ! -e /etc/resolv.conf && ! -L /etc/resolv.conf ]] || cp -a /etc/resolv.conf "$RESOLVER_BACKUP/resolv.conf"
    if lsattr -d /etc/resolv.conf 2>/dev/null | awk 'NR == 1 && $1 ~ /i/ {found=1} END {exit !found}'; then
        touch "$RESOLVER_BACKUP/resolv.conf.immutable"
    fi
    [[ ! -f /etc/dnsmasq.d/zimbra.conf ]] || cp -a /etc/dnsmasq.d/zimbra.conf "$RESOLVER_BACKUP/zimbra.conf"
    local service
    for service in systemd-resolved dnsmasq; do
        systemctl is-enabled "$service" > "$RESOLVER_BACKUP/$service.state" 2>/dev/null || true
        systemctl is-active --quiet "$service" && touch "$RESOLVER_BACKUP/$service.active"
        systemctl is-enabled --quiet "$service" && touch "$RESOLVER_BACKUP/$service.enabled"
    done
    RESOLVER_PENDING=yes
}

rollback_resolver() {
    echo "Restoring previous resolver from $RESOLVER_BACKUP" >&2
    systemctl stop dnsmasq 2>/dev/null || true
    rm -f /etc/resolv.conf /etc/dnsmasq.d/zimbra.conf
    [[ ! -e "$RESOLVER_BACKUP/resolv.conf" && ! -L "$RESOLVER_BACKUP/resolv.conf" ]] || \
        cp -a "$RESOLVER_BACKUP/resolv.conf" /etc/resolv.conf
    if [[ -f "$RESOLVER_BACKUP/resolv.conf.immutable" ]]; then
        chattr +i /etc/resolv.conf 2>/dev/null || \
            echo "WARNING: Could not restore the immutable flag on /etc/resolv.conf" >&2
    fi
    [[ ! -f "$RESOLVER_BACKUP/zimbra.conf" ]] || cp -a "$RESOLVER_BACKUP/zimbra.conf" /etc/dnsmasq.d/zimbra.conf
    local service
    for service in systemd-resolved dnsmasq; do
        if [[ "$(cat "$RESOLVER_BACKUP/$service.state")" == masked ]]; then
            systemctl mask "$service" || true
            continue
        fi
        if [[ -f "$RESOLVER_BACKUP/$service.enabled" ]]; then systemctl enable "$service" || true
        else systemctl disable "$service" 2>/dev/null || true; fi
        if [[ -f "$RESOLVER_BACKUP/$service.active" ]]; then systemctl restart "$service" || true; fi
    done
}

snapshot_host_config() {
    [[ -z "$HOST_CONFIG_BACKUP" ]] || return 0

    HOST_CONFIG_BACKUP=$(mktemp -d /root/zimbra-host-backup.XXXXXX)
    chmod 700 "$HOST_CONFIG_BACKUP"
    hostname > "$HOST_CONFIG_BACKUP/runtime-hostname"
    [[ ! -e /etc/hostname && ! -L /etc/hostname ]] || \
        cp -a /etc/hostname "$HOST_CONFIG_BACKUP/hostname"
    [[ ! -e /etc/hosts && ! -L /etc/hosts ]] || \
        cp -a /etc/hosts "$HOST_CONFIG_BACKUP/hosts"
    HOST_CONFIG_PENDING=yes
}

rollback_host_config() {
    local previous_hostname

    echo "Restoring previous hostname and hosts file from $HOST_CONFIG_BACKUP" >&2
    previous_hostname=$(cat "$HOST_CONFIG_BACKUP/runtime-hostname")
    hostnamectl set-hostname "$previous_hostname" 2>/dev/null || \
        hostname "$previous_hostname" 2>/dev/null || true

    rm -f /etc/hostname /etc/hosts
    [[ ! -e "$HOST_CONFIG_BACKUP/hostname" && ! -L "$HOST_CONFIG_BACKUP/hostname" ]] || \
        cp -a "$HOST_CONFIG_BACKUP/hostname" /etc/hostname
    [[ ! -e "$HOST_CONFIG_BACKUP/hosts" && ! -L "$HOST_CONFIG_BACKUP/hosts" ]] || \
        cp -a "$HOST_CONFIG_BACKUP/hosts" /etc/hosts
}

commit_host_network_config() {
    HOST_CONFIG_PENDING=no
    RESOLVER_PENDING=no
    echo "Host configuration backup: $HOST_CONFIG_BACKUP"
    echo "Resolver backup          : $RESOLVER_BACKUP"
}

clear_internal_secrets() {
    unset LDAP_ROOT_PASS LDAP_ADMIN_PASS LDAP_AMAVIS_PASS LDAP_POSTFIX_PASS
    unset LDAP_NGINX_PASS LDAP_REP_PASS SPAM_ACCOUNT_PASS HAM_ACCOUNT_PASS
    unset QUARANTINE_ACCOUNT_PASS MAILBOXD_KEYSTORE_PASS
    unset MAILBOXD_TRUSTSTORE_PASS CONFIG_ADMIN_PASS
}

repair_bootstrap_dns() {
    if ! timeout 15 getent ahostsv4 repo.zimbra.com >/dev/null; then
        snapshot_resolver
        echo "Restoring outbound DNS temporarily before APT"
        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f /etc/resolv.conf
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
        timeout 15 getent ahostsv4 repo.zimbra.com >/dev/null || die "Outbound DNS is unavailable"
    fi
}

cleanup() {
    local exit_code=$?
    trap - EXIT
    set +e
    if [[ "$FIREWALL_PENDING" == yes && -f "$FIREWALL_BACKUP/rollback.sh" ]]; then
        if bash "$FIREWALL_BACKUP/rollback.sh"; then
            systemctl stop "${FIREWALL_TIMER}.timer" 2>/dev/null
        else
            echo "Firewall rollback needs attention: $FIREWALL_BACKUP" >&2
        fi
    fi
    if [[ "$RESOLVER_PENDING" == yes ]]; then rollback_resolver; fi
    if [[ "$HOST_CONFIG_PENDING" == yes ]]; then rollback_host_config; fi

    [[ -z "$CONFIG_FILE" ]] || rm -f -- "$CONFIG_FILE"
    [[ -z "$SOFTWARE_CONFIG_FILE" ]] || rm -f -- "$SOFTWARE_CONFIG_FILE"
    clear_internal_secrets

    if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
        rm -rf -- "$WORKDIR"
    fi

    if (( exit_code != 0 )); then
        echo "Installation failed (exit $exit_code). Review: $LOG_FILE" >&2
    fi
    exit "$exit_code"
}

# Sourcing defines helpers only, for isolated regression tests.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ------------------------------------------------------------
# Arguments & Environment Pre-check
# ------------------------------------------------------------

for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

while [[ $# -gt 0 ]]; do
    case "$1" in

        --domain)
            require_value "$1" "$#" "${2:-}"
            DOMAIN="$2"
            shift 2
            ;;

        --csf-conf)
            require_value "$1" "$#" "${2:-}"
            CSF_CONF_SOURCE="$2"
            shift 2
            ;;
        --admin-ip|--admin-cidr)
            require_value "$1" "$#" "${2:-}"
            ADMIN_CIDR="$2"
            shift 2
            ;;
        --local-ip)
            require_value "$1" "$#" "${2:-}"
            LOCAL_IP="$2"
            shift 2
            ;;
        --ip)
            require_value "$1" "$#" "${2:-}"
            SERVER_IP="$2"
            shift 2
            ;;

        --password)
            require_value "$1" "$#" "${2:-}"
            ADMIN_PASS="$2"
            ADMIN_PASS_SOURCE="command line"
            shift 2
            ;;

        --password-file)
            require_value "$1" "$#" "${2:-}"
            read_admin_password_file "$2"
            ADMIN_PASS_SOURCE="password file"
            shift 2
            ;;

        --mail-host)
            require_value "$1" "$#" "${2:-}"
            MAIL_HOST="$2"
            shift 2
            ;;

        --installer)
            require_value "$1" "$#" "${2:-}"
            ZCS_SOURCE="$2"
            shift 2
            ;;

        --sha256)
            require_value "$1" "$#" "${2:-}"
            ZCS_SHA256="${2,,}"
            shift 2
            ;;

        --timezone)
            require_value "$1" "$#" "${2:-}"
            TIMEZONE="$2"
            shift 2
            ;;

        --skip-firewall)
            CONFIGURE_FIREWALL="no"
            shift
            ;;

        --only-firewall|--firewall-only)
            ONLY_FIREWALL="yes"
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            die "Unknown option: $1"
            ;;
    esac
done

detect_ubuntu_version
DOMAIN="${DOMAIN,,}"
MAIL_HOST="${MAIL_HOST,,}"
if [[ -z "$ADMIN_PASS" && -n "${ZIMBRA_ADMIN_PASSWORD:-}" ]]; then
    ADMIN_PASS="$ZIMBRA_ADMIN_PASSWORD"
    ADMIN_PASS_SOURCE="environment variable"
fi
unset ZIMBRA_ADMIN_PASSWORD
[[ "$ONLY_FIREWALL" != yes || "$CONFIGURE_FIREWALL" != no ]] || die "Conflicting firewall options"
[[ -z "$LOCAL_IP" ]] || is_valid_ipv4 "$LOCAL_IP" || die "Invalid local IPv4"
[[ -z "$ADMIN_CIDR" ]] || is_valid_admin_network "$ADMIN_CIDR" || die "Invalid administrator IP/CIDR: $ADMIN_CIDR"


if [[ "${ONLY_FIREWALL:-no}" != "yes" ]]; then
    [[ -n "$DOMAIN" ]] || die "--domain required"
    is_valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
    [[ -z "$SERVER_IP" ]] || is_valid_ipv4 "$SERVER_IP" || die "Invalid IPv4: $SERVER_IP"
    [[ "$MAIL_HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || \
        die "Invalid mail host: $MAIL_HOST"
    [[ "$TIMEZONE" =~ ^[a-zA-Z0-9_+-]+(/[a-zA-Z0-9_+-]+)+$ ]] || \
        die "Invalid timezone: $TIMEZONE"
    [[ "$ZCS_SHA256" =~ ^[a-f0-9]{64}$ ]] || die "Invalid SHA-256 value"
    FQDN="${MAIL_HOST}.${DOMAIN}"
    ADMIN_EMAIL="admin@${DOMAIN}"
    validate_fqdn "$FQDN"
    if [[ -n "$ADMIN_PASS" ]]; then validate_admin_password "$ADMIN_PASS"; fi
else
    DOMAIN="${DOMAIN:-localhost}"
    MAIL_HOST="${MAIL_HOST:-mail}"
    FQDN="${MAIL_HOST}.${DOMAIN}"
    ADMIN_EMAIL="admin@${DOMAIN}"
fi

# ------------------------------------------------------------
# Root
# ------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run script as root"
exec 9>/root/.zimbra-auto-install.lock
flock -n 9 || die "Another Zimbra installer is already running"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Capture output only after the root check, so non-root users get a clear error.
exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------------------------------------
# System validation
# ------------------------------------------------------------

log "Validate host environment"

ARCH=$(uname -m)

[[ "$ARCH" == "x86_64" ]] || die "x86_64 architecture required (found: $ARCH)"

echo "Detected OS     : Ubuntu ${VERSION_ID} (${UBUNTU_CODENAME})"
echo "Architecture    : ${ARCH}"
echo "ZCS Version     : ${ZCS_VERSION} GA (${ZCS_BUILD})"
if [[ "$ADMIN_PASS_SOURCE" == "command line" ]]; then
    echo "WARNING: --password can be exposed through shell history and the process list; use --password-file instead."
fi

if [[ "$ONLY_FIREWALL" == yes ]]; then
    repair_bootstrap_dns
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl perl iptables ipset iproute2 \
        libwww-perl libio-socket-ssl-perl libnet-libidn-perl libsocket6-perl rsyslog
    systemctl enable --now rsyslog
    prepare_firewall_assets
    configure_csf
    RESOLVER_PENDING=no
    log "CSF firewall configuration completed successfully"
    exit 0
fi

# ------------------------------------------------------------
# Check existing Zimbra
# ------------------------------------------------------------

if [[ -d /opt/zimbra ]]; then

    ZIMBRA_CORE_STATUS=$(dpkg-query -W -f='${db:Status-Status}' zimbra-core 2>/dev/null || true)

    # A failed pre-package installer run leaves only this empty directory.
    # Remove that known-safe residue so the corrected script can be rerun.
    if [[ "$ZIMBRA_CORE_STATUS" != "installed" ]] && ! id zimbra &>/dev/null; then
        if [[ -d /opt/zimbra/.saveconfig ]]; then
            rmdir /opt/zimbra/.saveconfig 2>/dev/null || \
                die "Incomplete /opt/zimbra contains data; inspect it before retrying"
        fi
        rmdir /opt/zimbra 2>/dev/null || \
            die "Incomplete /opt/zimbra contains data; inspect it before retrying"
        log "Removed empty directory left by an incomplete Zimbra installer run"
    fi
fi

if [[ -d /opt/zimbra ]]; then

    if id zimbra &>/dev/null; then
        echo
        echo "Existing Zimbra detected:"
        su - zimbra -c 'zmcontrol -v' 2>/dev/null || true
    fi

    die "/opt/zimbra already exists. Refusing fresh installation. (If you only want to finish CSF firewall setup, run: sudo bash $0 --only-firewall)"
fi

# ------------------------------------------------------------
# Hardware check
# ------------------------------------------------------------

log "Hardware checks"

RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
DISK_GB=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')

if [[ "$RAM_MB" -lt 7000 ]]; then
    die "Minimum approximately 8 GB RAM required. Current: ${RAM_MB} MB"
fi

echo "RAM: ${RAM_MB} MB"
echo "Free disk: ${DISK_GB} GB"

if [[ "$DISK_GB" -lt 20 ]]; then
    die "At least 20 GB free disk space is required. Current: ${DISK_GB} GB"
fi

# ------------------------------------------------------------
# Packages
# ------------------------------------------------------------

# Recover DNS before any APT request; preserve a rollback copy.
repair_bootstrap_dns
synchronize_system_clock
log "Install OS dependencies"

export DEBIAN_FRONTEND=noninteractive

# Older script versions could restrict both the key and its parent directory.
# Verify readability as the same unprivileged user APT uses for downloads.
repair_zimbra_apt_keyring_permissions

# Repair interrupted package operations before installing dependencies.
dpkg --configure -a
apt-get -f install -y
apt-get update

SYSTEM_PACKAGES=(
    apt-transport-https
    ca-certificates
    chrony
    curl
    dirmngr
    dnsutils
    dnsmasq
    gnupg
    iproute2
    ipset
    iptables
    libio-socket-inet6-perl
    libio-socket-ssl-perl
    liblwp-protocol-https-perl
    libnet-libidn-perl
    libsocket6-perl
    libwww-perl
    net-tools
    netcat-openbsd
    openssl
    pax
    perl
    rsyslog
    sqlite3
    sysstat
    tar
    unzip
    wget
)

apt-get install -y "${SYSTEM_PACKAGES[@]}"

systemctl enable --now chrony
chronyc -a makestep 2>/dev/null || true
systemctl enable --now rsyslog

# Detect values only after curl and OpenSSL are guaranteed to be installed.
if [[ -z "$SERVER_IP" ]]; then
    log "Detect public IPv4"
    SERVER_IP=$(detect_server_ipv4) || \
        die "Cannot detect the VPS IPv4 address; rerun with --ip IPV4"
    echo "Detected IPv4: $SERVER_IP"
fi

check_fqdn_dns_safety
report_ptr_status

if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS=$(openssl rand -hex 16)
    ADMIN_PASS_SOURCE="generated"
fi

validate_admin_password "$ADMIN_PASS"
install -m 600 /dev/null "$RESULT_FILE"
printf 'Installation in progress\nAdmin: %s\nPassword: %s\n' "$ADMIN_EMAIL" "$ADMIN_PASS" > "$RESULT_FILE"

# Resolve the local address separately from the externally advertised address.
if [[ -z "$LOCAL_IP" ]]; then
    LOCAL_IP=$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
fi
is_valid_ipv4 "$LOCAL_IP" || die "Cannot detect local IPv4; use --local-ip"
ip -o -4 addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$LOCAL_IP" || \
    die "--local-ip must belong to a local interface"
# Fail early with a clear URL if the external packages required by proxy are
# not reachable. The bundled installer otherwise hides this detail in a log.
check_zimbra_repository

# Download and validate the complete installer before changing host services.
prepare_installer
if [[ "$CONFIGURE_FIREWALL" == yes ]]; then prepare_firewall_assets; fi

log "Check conflicting mail/web services"
for service in postfix exim4 nginx apache2; do
    if systemctl is-active --quiet "$service"; then
        die "Conflicting service $service is active; use a clean dedicated Zimbra server"
    fi
done

log "Configuration"

echo "Domain     : $DOMAIN"
echo "Hostname   : $FQDN"
echo "Public IP  : $SERVER_IP"
echo "Local IP   : $LOCAL_IP"
echo "Admin      : $ADMIN_EMAIL"
echo "Installer  : $ZCS_TGZ"

# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

log "Configure hostname"

snapshot_host_config
hostnamectl set-hostname "$FQDN"

# Keep one deterministic mapping for this server. The original files are kept
# in HOST_CONFIG_BACKUP until the complete Zimbra configuration is verified.
HOSTS_TMP=$(mktemp /etc/.hosts.zimbra.XXXXXX)
awk -v fqdn="$FQDN" -v short="$MAIL_HOST" -v server_ip="$LOCAL_IP" '
    {
        # Drop lines whose IP is 127.0.1.1 or the target server IP entirely.
        if ($1 == "127.0.1.1" || $1 == server_ip) { next }

        # For any other line (including 127.0.0.1), strip the FQDN and short
        # hostname so dnsmasq will not shadow the address= directive.
        output = $1
        has_others = 0
        for (i = 2; i <= NF; i++) {
            if ($i != fqdn && $i != short) {
                output = output " " $i
                has_others = 1
            }
        }
        # Keep the line only if it still has at least one hostname after cleanup.
        if (has_others) { print output }
    }
' /etc/hosts > "$HOSTS_TMP"
install -m 644 "$HOSTS_TMP" /etc/hosts
rm -f -- "$HOSTS_TMP"

grep -qE '^127\.0\.0\.1([[:space:]]|$)' /etc/hosts || \
    echo "127.0.0.1 localhost" >> /etc/hosts

echo "$LOCAL_IP $FQDN $MAIL_HOST" >> /etc/hosts

echo
cat /etc/hosts

echo
echo "hostname -f:"
hostname -f

[[ "$(hostname -f)" == "$FQDN" ]] || die "hostname -f is incorrect"

# ------------------------------------------------------------
# resolv.conf
# VERY IMPORTANT:
# don't make it immutable before installing Zimbra
# ------------------------------------------------------------

log "Prepare resolver"

chattr -i /etc/resolv.conf 2>/dev/null || true

# ------------------------------------------------------------
# DNSMASQ
#
# Provides local A + MX before public DNS is pointed.
# zimbra-dnscache will therefore be N.
# ------------------------------------------------------------

log "Configure local DNS"
snapshot_resolver

BACKUP_SUFFIX="pre-zimbra.$(date +%Y%m%d%H%M%S)"
[[ ! -e /etc/dnsmasq.d/zimbra.conf ]] || \
    cp -a /etc/dnsmasq.d/zimbra.conf "/etc/dnsmasq.d/zimbra.conf.${BACKUP_SUFFIX}"

cat > /etc/dnsmasq.d/zimbra.conf <<EOF
listen-address=127.0.0.1
bind-interfaces
domain-needed
bogus-priv
no-hosts
no-resolv

server=1.1.1.1
server=8.8.8.8

host-record=${FQDN},${LOCAL_IP}
host-record=localhost,127.0.0.1
mx-host=${DOMAIN},${FQDN},10
EOF

# Validate before switching the system resolver. systemd-resolved can keep
# listening on 127.0.0.53 while dnsmasq binds only 127.0.0.1.
dnsmasq --test

chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf

cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
EOF

systemctl unmask dnsmasq 2>/dev/null || true
systemctl enable dnsmasq 2>/dev/null || true
systemctl restart dnsmasq
sleep 1

if ! systemctl is-active --quiet dnsmasq; then
    echo "ERROR: dnsmasq failed to start. Service status:"
    systemctl status dnsmasq --no-pager || true
    die "dnsmasq service failed to start"
fi

# ------------------------------------------------------------
# DNS validation
# ------------------------------------------------------------

log "Validate DNS"

echo "Current /etc/resolv.conf:"
cat /etc/resolv.conf
echo

echo "A (dig +short $FQDN):"
dig +short "$FQDN"

echo
echo "MX (dig +short MX $DOMAIN):"
dig +short MX "$DOMAIN"
echo

A_RESULT=$(dig +short "$FQDN" | tail -1)

[[ "$A_RESULT" == "$LOCAL_IP" ]] || {
    echo "Diagnostic information:"
    echo "Testing direct query to 127.0.0.1:"
    dig +short @127.0.0.1 "$FQDN" || true
    echo "dnsmasq service status:"
    systemctl status dnsmasq --no-pager || true
    echo "/etc/dnsmasq.d/zimbra.conf content:"
    cat /etc/dnsmasq.d/zimbra.conf || true
    die "A resolution failed: expected $LOCAL_IP got $A_RESULT"
}

MX_RESULT=$(dig +short MX "$DOMAIN")

awk -v fqdn="${FQDN,,}." 'tolower($2)==fqdn {found=1} END {exit !found}' <<< "$MX_RESULT" || {
    echo "Diagnostic information:"
    echo "Testing direct MX query to 127.0.0.1:"
    dig +short MX @127.0.0.1 "$DOMAIN" || true
    die "MX resolution failed"
}

# Keep the resolver transaction pending until Zimbra itself is configured and
# verified; a later installation failure will restore the original resolver.
getent ahostsv4 repo.zimbra.com >/dev/null || die "Outbound DNS failed after local DNS setup"
echo "Public DNS (configure A/MX/PTR/SPF/DKIM/DMARC separately):"
dig @1.1.1.1 +short +time=3 +tries=1 "$FQDN" A || true
dig @1.1.1.1 +short +time=3 +tries=1 "$DOMAIN" MX || true

# ------------------------------------------------------------
# Check ports
# ------------------------------------------------------------

log "Port pre-check"

PORT_CONFLICTS=$(
    ss -lntp |
    grep -E ':(25|80|110|143|389|443|465|587|993|995|7025|7071|7072|7073|7110|7143|7780|7993|7995|8080|8443|11211)[[:space:]]' || true
)

if [[ -n "$PORT_CONFLICTS" ]]; then
    echo "$PORT_CONFLICTS"
    die "Required Zimbra ports are already occupied"
fi

# ------------------------------------------------------------
# Extract installer
# ------------------------------------------------------------

log "Extract Zimbra"

WORKDIR=$(mktemp -d /root/zimbra-auto.XXXXXX)

tar xzf "$ZCS_TGZ" -C "$WORKDIR"

ZCS_DIR=$(
    find "$WORKDIR" \
        -maxdepth 1 \
        -type d \
        -name 'zcs-*' \
        -print \
        -quit
)

[[ -n "$ZCS_DIR" ]] || die "Cannot locate extracted Zimbra installer"

echo "Zimbra directory: $ZCS_DIR"

log "Patch bundled Zimbra installer"
patch_zimbra_installer "$ZCS_DIR"

# ------------------------------------------------------------
# Software-only installer configuration
#
# Passing a defaults file is deterministic and avoids relying on the order of
# interactive prompts, which can change with repository/package availability.
# ------------------------------------------------------------

log "Create software installer configuration"

SOFTWARE_CONFIG_FILE=$(mktemp /root/zimbra-software-install.XXXXXX)

install -m 600 /dev/null "$SOFTWARE_CONFIG_FILE"
cat > "$SOFTWARE_CONFIG_FILE" <<EOF
INSTALL_PACKAGES="$ZCS_PACKAGES"
USE_ZIMBRA_PACKAGE_SERVER="yes"
PACKAGE_SERVER="repo.zimbra.com"
EOF

chmod 600 "$SOFTWARE_CONFIG_FILE"

# ------------------------------------------------------------
# Software-only installation
# ------------------------------------------------------------

log "Install Zimbra software"

cd "$ZCS_DIR"

if ! ./install.sh -s "$SOFTWARE_CONFIG_FILE"; then
    echo
    echo "Zimbra installer diagnostics (last 120 log lines):"
    if [[ -r /tmp/install.log ]]; then
        tail -n 120 /tmp/install.log
    else
        echo "Installer log is unavailable: /tmp/install.log"
    fi
    die "Zimbra software installation failed"
fi
rm -f -- "$SOFTWARE_CONFIG_FILE"
SOFTWARE_CONFIG_FILE=""

# ------------------------------------------------------------
# Check software install
# ------------------------------------------------------------

[[ -x /opt/zimbra/libexec/zmsetup.pl ]] || \
    die "Zimbra package installation failed; zmsetup.pl missing"

# ------------------------------------------------------------
# Generate passwords
# ------------------------------------------------------------

LDAP_ROOT_PASS=$(openssl rand -hex 20)
LDAP_ADMIN_PASS=$(openssl rand -hex 20)
LDAP_AMAVIS_PASS=$(openssl rand -hex 20)
LDAP_POSTFIX_PASS=$(openssl rand -hex 20)
LDAP_NGINX_PASS=$(openssl rand -hex 20)
LDAP_REP_PASS=$(openssl rand -hex 20)
MAILBOXD_KEYSTORE_PASS=$(openssl rand -hex 20)
MAILBOXD_TRUSTSTORE_PASS=$(openssl rand -hex 20)
SYSTEM_ACCOUNT_SUFFIX=$(openssl rand -hex 5)
SPAM_ACCOUNT="spam.${SYSTEM_ACCOUNT_SUFFIX}@${DOMAIN}"
HAM_ACCOUNT="ham.${SYSTEM_ACCOUNT_SUFFIX}@${DOMAIN}"
QUARANTINE_ACCOUNT="virus-quarantine.${SYSTEM_ACCOUNT_SUFFIX}@${DOMAIN}"
SPAM_ACCOUNT_PASS=$(openssl rand -hex 16)
HAM_ACCOUNT_PASS=$(openssl rand -hex 16)
QUARANTINE_ACCOUNT_PASS=$(openssl rand -hex 16)

# ------------------------------------------------------------
# Zimbra configuration
# ------------------------------------------------------------

log "Generate Zimbra setup configuration"

CONFIG_FILE=$(mktemp /root/zimbra-setup.XXXXXX)
CONFIG_ADMIN_PASS=$(escape_config_value "$ADMIN_PASS")

install -m 600 /dev/null "$CONFIG_FILE"
cat > "$CONFIG_FILE" <<EOF
AVDOMAIN="$DOMAIN"
AVUSER="$ADMIN_EMAIL"

CREATEADMIN="$ADMIN_EMAIL"
CREATEADMINPASS="$CONFIG_ADMIN_PASS"

CREATEDOMAIN="$DOMAIN"

DOCREATEADMIN="yes"
DOCREATEDOMAIN="yes"

DOTRAINSA="yes"
EXPANDMENU="no"

HOSTNAME="$FQDN"

HTTPPORT="8080"
HTTPPROXY="TRUE"
HTTPPROXYPORT="80"

HTTPSPORT="8443"
HTTPSPROXYPORT="443"

IMAPPORT="7143"
IMAPPROXYPORT="143"

IMAPSSLPORT="7993"
IMAPSSLPROXYPORT="993"

POPPORT="7110"
POPPROXYPORT="110"

POPSSLPORT="7995"
POPSSLPROXYPORT="995"

INSTALL_WEBAPPS="service zimlet zimbra zimbraAdmin"

LDAPAMAVISPASS="$LDAP_AMAVIS_PASS"
LDAPPOSTPASS="$LDAP_POSTFIX_PASS"
LDAPROOTPASS="$LDAP_ROOT_PASS"
LDAPADMINPASS="$LDAP_ADMIN_PASS"
LDAPREPPASS="$LDAP_REP_PASS"

LDAPBESSEARCHSET="set"

LDAPHOST="$FQDN"
LDAPPORT="389"
LDAPREPLICATIONTYPE="master"

MAILPROXY="TRUE"

MODE="https"
PROXYMODE="https"

MYSQLMEMORYPERCENT="30"

REMOVE="no"

RUNARCHIVING="no"
RUNAV="yes"
RUNDKIM="yes"
RUNSA="yes"

SERVICEWEBAPP="yes"

SMTPDEST="$ADMIN_EMAIL"
SMTPHOST="$FQDN"
SMTPNOTIFY="yes"
SMTPSOURCE="$ADMIN_EMAIL"

SNMPNOTIFY="no"
SNMPTRAPHOST="$FQDN"

SPELLURL="http://${FQDN}:7780/aspell.php"

STARTSERVERS="yes"

TRAINSAHAM="$HAM_ACCOUNT"
TRAINSASPAM="$SPAM_ACCOUNT"
VIRUSQUARANTINE="$QUARANTINE_ACCOUNT"

USESPELL="yes"

ZIMBRA_REQ_SECURITY="yes"

ldap_bes_searcher_password="$LDAP_ADMIN_PASS"
ldap_nginx_password="$LDAP_NGINX_PASS"

mailboxd_keystore_password="$MAILBOXD_KEYSTORE_PASS"
mailboxd_truststore_password="$MAILBOXD_TRUSTSTORE_PASS"

zimbraIPMode="ipv4"

zimbraPrefTimeZoneId="$TIMEZONE"

zimbraReverseProxyLookupTarget="TRUE"

INSTALL_PACKAGES="$ZCS_PACKAGES"
EOF

chmod 600 "$CONFIG_FILE"

# ------------------------------------------------------------
# Setup Zimbra
# ------------------------------------------------------------

log "Configure Zimbra"

/opt/zimbra/libexec/zmsetup.pl -c "$CONFIG_FILE"
rm -f -- "$CONFIG_FILE"
CONFIG_FILE=""

# Some Zimbra builds fall back to HOSTNAME for these three accounts even when
# AVDOMAIN is set. Verify them against the primary mail domain and repair the
# configuration before reporting a successful installation.
ensure_zimbra_system_accounts
clear_internal_secrets

# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

log "Verify installation"

VERSION=$(
    su - zimbra -c 'zmcontrol -v' 2>&1
)

STATUS=$(
    su - zimbra -c 'zmcontrol status' 2>&1
)

echo "$VERSION"
echo
echo "$STATUS"
[[ "$VERSION" == *"${ZCS_VERSION}.GA"* || "$VERSION" == *"${ZCS_VERSION}_GA"* ]] || \
    die "Installed Zimbra version differs from the verified installer: $VERSION"

if grep -qiE 'Stopped|not running' <<< "$STATUS"; then
    echo
    die "At least one Zimbra service is not running"
fi

# Zimbra is now configured and running with this hostname and resolver. Keep
# their backups for manual recovery, but do not roll them back if a later
# post-install step such as DKIM or the optional firewall fails.
commit_host_network_config

# ------------------------------------------------------------
# Generate DKIM if needed
# ------------------------------------------------------------

log "DKIM"

if ! DKIM_QUERY=$(su - zimbra -c \
    "/opt/zimbra/libexec/zmdkimkeyutil -q -d '$DOMAIN'" 2>/dev/null); then
    if ! DKIM_ADD_OUTPUT=$(su - zimbra -c \
        "/opt/zimbra/libexec/zmdkimkeyutil -a -d '$DOMAIN'" 2>&1); then
        echo "$DKIM_ADD_OUTPUT"
        die "Cannot generate DKIM data for $DOMAIN"
    fi
    echo "$DKIM_ADD_OUTPUT"

    DKIM_QUERY=$(su - zimbra -c \
        "/opt/zimbra/libexec/zmdkimkeyutil -q -d '$DOMAIN'" 2>&1) || \
        die "Cannot retrieve generated DKIM data for $DOMAIN"
fi

parse_dkim_query "$DKIM_QUERY" || die "Cannot parse DKIM DNS data"

DKIM_DNS_NAME="${DKIM_SELECTOR}._domainkey.${DOMAIN}"
unset DKIM_QUERY

echo "DKIM selector : $DKIM_SELECTOR"
echo "DKIM DNS host : $DKIM_DNS_NAME"
echo "DKIM TXT data : prepared for the installation summary"

# ------------------------------------------------------------
# Host firewall
# ------------------------------------------------------------

if [[ "$CONFIGURE_FIREWALL" == "yes" ]]; then
    configure_csf
else
    SSH_PORT="$(detect_ssh_port)/tcp (unchanged)"
    FIREWALL_STATUS="skipped by --skip-firewall"
    FIREWALL_ADMIN_ACCESS="unchanged"
    FIREWALL_RULES="CSF configuration skipped by --skip-firewall"
    log "Skip CSF firewall configuration"
fi

# ------------------------------------------------------------
# Save credentials / deployment info
# ------------------------------------------------------------

RESULT_FILE="/root/ZIMBRA-INSTALL-INFO.txt"

install -m 600 /dev/null "$RESULT_FILE"
print_install_summary --include-password > "$RESULT_FILE"

log "Installation completed"
print_install_summary
