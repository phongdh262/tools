#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# ============================================================
# Zimbra 10.1.20 FOSS Automated Installer
# OS    : Ubuntu 22.04
# Build : zcs-10.1.20_GA_0326.UBUNTU22_64.20260821115118
#
# Usage:
# bash install-zimbra.sh \
#   --domain example.com \
#   --ip 103.110.85.145 \
#   --password 'StrongPassword'
# ============================================================

readonly ZCS_VERSION="10.1.20"
readonly ZCS_BUILD="0326.UBUNTU22_64.20260821115118"
readonly ZCS_ARCHIVE="zcs-${ZCS_VERSION}_GA_${ZCS_BUILD}.tgz"
readonly DEFAULT_ZCS_URL="https://github.com/phongdh262/tools/releases/download/zimbra-${ZCS_VERSION}/${ZCS_ARCHIVE}"
readonly DEFAULT_ZCS_SHA256="57c16b71a59fc34d2e1675d122ad9c702d464000b5222b434296a93b850aed75"
readonly ZCS_PACKAGES="zimbra-core zimbra-ldap zimbra-logger zimbra-mta zimbra-snmp zimbra-store zimbra-apache zimbra-spell zimbra-memcached zimbra-proxy"

ZCS_SOURCE="$DEFAULT_ZCS_URL"
ZCS_SHA256="$DEFAULT_ZCS_SHA256"
ZCS_TGZ=""

DOMAIN=""
SERVER_IP=""
ADMIN_PASS=""
MAIL_HOST="mail"
TIMEZONE="Asia/Ho_Chi_Minh"

LOG_FILE="/root/zimbra-auto-install.log"
DOWNLOAD_DIR="/root/zimbra-downloads"
WORKDIR=""

usage() {
    cat <<EOF
Usage:
  sudo bash $0 --domain example.com --ip 203.0.113.10 [password option]

Required:
  --domain DOMAIN           Mail domain (for example: example.com)
  --ip IPV4                 Public IPv4 address of this server
  --password PASSWORD       Zimbra admin password

Password alternatives:
  --password-file FILE      Read the password from the first line of FILE
  ZIMBRA_ADMIN_PASSWORD     Environment variable used when no password option is set

Optional:
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

is_valid_domain() {
    local domain="$1"
    local label
    local -a labels

    (( ${#domain} <= 253 )) || return 1
    [[ "$domain" == *.* && "$domain" != *..* ]] || return 1
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        (( ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

escape_config_value() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

installer_is_valid() {
    local archive="$1"

    echo "${ZCS_SHA256}  ${archive}" | sha256sum --check --status && \
        tar -tzf "$archive" >/dev/null
}

verify_installer() {
    local archive="$1"

    installer_is_valid "$archive" || \
        die "SHA-256 verification failed or archive is corrupt: $archive"
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

cleanup() {
    local exit_code=$?

    if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
        rm -rf -- "$WORKDIR"
    fi

    if (( exit_code != 0 )); then
        echo "Installation failed (exit $exit_code). Review: $LOG_FILE" >&2
    fi
}

trap cleanup EXIT

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in

        --domain)
            require_value "$1" "$#" "${2:-}"
            DOMAIN="$2"
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
            shift 2
            ;;

        --password-file)
            require_value "$1" "$#" "${2:-}"
            [[ -r "$2" ]] || die "Cannot read password file: $2"
            IFS= read -r ADMIN_PASS < "$2" || true
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

        -h|--help)
            usage
            exit 0
            ;;

        *)
            die "Unknown option: $1"
            ;;
    esac
done

ADMIN_PASS="${ADMIN_PASS:-${ZIMBRA_ADMIN_PASSWORD:-}}"

[[ -n "$DOMAIN" ]] || die "--domain required"
[[ -n "$SERVER_IP" ]] || die "--ip required"
[[ -n "$ADMIN_PASS" ]] || die "Set --password, --password-file, or ZIMBRA_ADMIN_PASSWORD"
is_valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
[[ "$MAIL_HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || \
    die "Invalid mail host: $MAIL_HOST"
[[ "$TIMEZONE" =~ ^[a-zA-Z0-9_+-]+(/[a-zA-Z0-9_+-]+)+$ ]] || \
    die "Invalid timezone: $TIMEZONE"
[[ "$ZCS_SHA256" =~ ^[a-f0-9]{64}$ ]] || die "Invalid SHA-256 value"
[[ "$ADMIN_PASS" != *$'\n'* && "$ADMIN_PASS" != *$'\r'* ]] || \
    die "Admin password must be a single line"

FQDN="${MAIL_HOST}.${DOMAIN}"
ADMIN_EMAIL="admin@${DOMAIN}"

# ------------------------------------------------------------
# Root
# ------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run script as root"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Capture output only after the root check, so non-root users get a clear error.
exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------------------------------------
# OS validation
# ------------------------------------------------------------

source /etc/os-release

[[ "$ID" == "ubuntu" ]] || die "Ubuntu required"
[[ "$VERSION_ID" == "22.04" ]] || die "Ubuntu 22.04 required"

ARCH=$(uname -m)

[[ "$ARCH" == "x86_64" ]] || die "x86_64 required"

# ------------------------------------------------------------
# IP validation
# ------------------------------------------------------------

if ! is_valid_ipv4 "$SERVER_IP"; then
    die "Invalid IPv4: $SERVER_IP"
fi

# ------------------------------------------------------------
# Check existing Zimbra
# ------------------------------------------------------------

if [[ -d /opt/zimbra ]]; then

    if id zimbra &>/dev/null; then
        echo
        echo "Existing Zimbra detected:"
        su - zimbra -c 'zmcontrol -v' 2>/dev/null || true
    fi

    die "/opt/zimbra already exists. Refusing fresh installation."
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

log "Install OS dependencies"

export DEBIAN_FRONTEND=noninteractive

# Repair interrupted package operations before installing dependencies.
dpkg --configure -a
apt-get -f install -y
apt-get update

apt-get install -y \
    ca-certificates \
    chrony \
    curl \
    dnsutils \
    dnsmasq \
    net-tools \
    netcat-openbsd \
    openssl \
    pax \
    perl \
    resolvconf \
    rsyslog \
    sqlite3 \
    sysstat \
    tar \
    unzip

systemctl enable --now chrony
systemctl enable --now rsyslog

# Download and validate the complete installer before changing host services.
prepare_installer

log "Configuration"

echo "Domain     : $DOMAIN"
echo "Hostname   : $FQDN"
echo "IP         : $SERVER_IP"
echo "Admin      : $ADMIN_EMAIL"
echo "Installer  : $ZCS_TGZ"

# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

log "Configure hostname"

hostnamectl set-hostname "$FQDN"

# Keep one deterministic mapping for this server and retain a recoverable backup.
cp -a /etc/hosts "/etc/hosts.pre-zimbra.$(date +%Y%m%d%H%M%S)"
HOSTS_TMP=$(mktemp /etc/.hosts.zimbra.XXXXXX)
awk -v fqdn="$FQDN" -v server_ip="$SERVER_IP" '
    {
        drop = ($1 == "127.0.1.1" || $1 == server_ip)
        for (i = 2; i <= NF; i++) {
            if ($i == fqdn) {
                drop = 1
            }
        }
        if (!drop) {
            print
        }
    }
' /etc/hosts > "$HOSTS_TMP"
install -m 644 "$HOSTS_TMP" /etc/hosts
rm -f -- "$HOSTS_TMP"

grep -qE '^127\.0\.0\.1([[:space:]]|$)' /etc/hosts || \
    echo "127.0.0.1 localhost" >> /etc/hosts

echo "$SERVER_IP $FQDN $MAIL_HOST" >> /etc/hosts

echo
cat /etc/hosts

echo
echo "hostname -f:"
hostname -f

[[ "$(hostname -f)" == "$FQDN" ]] || die "hostname -f is incorrect"

# ------------------------------------------------------------
# Timezone
# ------------------------------------------------------------

log "Configure timezone"

[[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Unknown timezone: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE"

# ------------------------------------------------------------
# resolv.conf
# VERY IMPORTANT:
# don't make it immutable before installing Zimbra
# ------------------------------------------------------------

log "Prepare resolver"

chattr -i /etc/resolv.conf 2>/dev/null || true

# ------------------------------------------------------------
# Remove conflicting services
# ------------------------------------------------------------

log "Remove conflicting mail/web services"

for service in postfix exim4 nginx apache2; do
    systemctl disable --now "$service" 2>/dev/null || true
done

apt-get purge -y \
    postfix \
    postfix-base \
    'exim4*' \
    nginx \
    nginx-common \
    apache2 \
    apache2-bin \
    apache2-data \
    2>/dev/null || true

# ------------------------------------------------------------
# DNSMASQ
#
# Provides local A + MX before public DNS is pointed.
# zimbra-dnscache will therefore be N.
# ------------------------------------------------------------

log "Configure local DNS"

BACKUP_SUFFIX="pre-zimbra.$(date +%Y%m%d%H%M%S)"
[[ ! -e /etc/dnsmasq.d/zimbra.conf ]] || \
    cp -a /etc/dnsmasq.d/zimbra.conf "/etc/dnsmasq.d/zimbra.conf.${BACKUP_SUFFIX}"

cat > /etc/dnsmasq.d/zimbra.conf <<EOF
listen-address=127.0.0.1
bind-interfaces

server=1.1.1.1
server=8.8.8.8

address=/${FQDN}/${SERVER_IP}
mx-host=${DOMAIN},${FQDN},10
EOF

# Put localhost DNS first via resolvconf
mkdir -p /etc/resolvconf/resolv.conf.d

[[ ! -e /etc/resolvconf/resolv.conf.d/head ]] || \
    cp -a /etc/resolvconf/resolv.conf.d/head \
        "/etc/resolvconf/resolv.conf.d/head.${BACKUP_SUFFIX}"

cat > /etc/resolvconf/resolv.conf.d/head <<EOF
nameserver 127.0.0.1
EOF

resolvconf -u || true

systemctl enable --now dnsmasq

# ------------------------------------------------------------
# DNS validation
# ------------------------------------------------------------

log "Validate DNS"

echo "A:"
dig +short "$FQDN"

echo
echo "MX:"
dig +short MX "$DOMAIN"

A_RESULT=$(dig +short "$FQDN" | tail -1)

[[ "$A_RESULT" == "$SERVER_IP" ]] || \
    die "A resolution failed: expected $SERVER_IP got $A_RESULT"

MX_RESULT=$(dig +short MX "$DOMAIN")

grep -qi "$FQDN" <<< "$MX_RESULT" || \
    die "MX resolution failed"

# ------------------------------------------------------------
# Check ports
# ------------------------------------------------------------

log "Port pre-check"

PORT_CONFLICTS=$(
    ss -lntp |
    grep -E ':(25|80|443|465|587|7071)[[:space:]]' || true
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

# ------------------------------------------------------------
# Software-only installer configuration
#
# Passing a defaults file is deterministic and avoids relying on the order of
# interactive prompts, which can change with repository/package availability.
# ------------------------------------------------------------

log "Create software installer configuration"

SOFTWARE_CONFIG_FILE="/root/zimbra-software-install.conf"

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

./install.sh -s "$SOFTWARE_CONFIG_FILE"

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

# ------------------------------------------------------------
# Zimbra configuration
# ------------------------------------------------------------

log "Generate Zimbra setup configuration"

CONFIG_FILE="/root/zimbra-setup.conf"
CONFIG_ADMIN_PASS=$(escape_config_value "$ADMIN_PASS")

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

SNMPNOTIFY="yes"
SNMPTRAPHOST="$FQDN"

SPELLURL="http://${FQDN}:7780/aspell.php"

STARTSERVERS="yes"

USESPELL="yes"

ZIMBRA_REQ_SECURITY="yes"

ldap_bes_searcher_password="$LDAP_ADMIN_PASS"
ldap_nginx_password="$LDAP_NGINX_PASS"

mailboxd_keystore_password="$CONFIG_ADMIN_PASS"
mailboxd_truststore_password="changeit"

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

if grep -qiE 'Stopped|not running' <<< "$STATUS"; then
    echo
    echo "WARNING: At least one Zimbra service is not running."
fi

# ------------------------------------------------------------
# Generate DKIM if needed
# ------------------------------------------------------------

log "DKIM"

DKIM=$(
    su - zimbra -c \
      "/opt/zimbra/libexec/zmdkimkeyutil -q -d '$DOMAIN'" \
      2>/dev/null || true
)

if [[ -z "$DKIM" ]]; then
    DKIM=$(
        su - zimbra -c \
          "/opt/zimbra/libexec/zmdkimkeyutil -a -d '$DOMAIN'" \
          2>&1 || true
    )
fi

echo "$DKIM"

# ------------------------------------------------------------
# Save credentials / deployment info
# ------------------------------------------------------------

RESULT_FILE="/root/ZIMBRA-INSTALL-INFO.txt"

cat > "$RESULT_FILE" <<EOF
============================================================
ZIMBRA INSTALLATION
============================================================

Domain:
$DOMAIN

Hostname:
$FQDN

IP:
$SERVER_IP

Admin:
$ADMIN_EMAIL

Admin password:
$ADMIN_PASS

Webmail:
https://$FQDN

Admin console:
https://$FQDN:7071


============================================================
DNS RECORDS
============================================================

A:

$FQDN
$SERVER_IP


MX:

$DOMAIN
10 $FQDN


SPF:

v=spf1 mx a ip4:$SERVER_IP ~all


DMARC:

Host:
_dmarc.$DOMAIN

Value:
v=DMARC1; p=none


PTR:

$SERVER_IP -> $FQDN


============================================================
DKIM
============================================================

$DKIM

============================================================
EOF

chmod 600 "$RESULT_FILE"

log "Installation completed"

echo
echo "Webmail:"
echo "  https://$FQDN"

echo
echo "Admin:"
echo "  https://$FQDN:7071"

echo
echo "Login:"
echo "  $ADMIN_EMAIL"

echo
echo "Deployment information:"
echo "  $RESULT_FILE"

echo
echo "Version:"
su - zimbra -c 'zmcontrol -v'

echo
echo "Services:"
su - zimbra -c 'zmcontrol status'
