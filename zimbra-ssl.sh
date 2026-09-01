#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '\n[zimbra-ssl] Không source script này. Hãy chạy: bash zimbra-ssl.sh\n' >&2
  return 1
fi

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="zimbra-ssl.sh"
readonly INSTALL_PATH="/usr/local/sbin/zimbra-ssl"
readonly CONFIG_DIR="/etc/zimbra-ssl"
readonly DOMAIN_FILE="${CONFIG_DIR}/domain"
readonly CERTBOT_FILE="${CONFIG_DIR}/certbot-path"
readonly DEPLOYED_FINGERPRINT_FILE="${CONFIG_DIR}/deployed-fingerprint"
readonly ROOT_CA_FILE="${CONFIG_DIR}/ISRG-Root-X1.pem"
readonly ROOT_CA_URL="https://letsencrypt.org/certs/isrgrootx1.pem"
readonly ROOT_CA_SHA256="96BCEC06264976F37460779ACF28C5A7CFE8A3C0AAE11A8FFCEE05C0BDDF08C6"
readonly CRON_FILE="/etc/cron.d/zimbra-letsencrypt"
readonly ZMCERTMGR="/opt/zimbra/bin/zmcertmgr"
readonly ZMCONTROL="/opt/zimbra/bin/zmcontrol"
readonly COMMERCIAL_DIR="/opt/zimbra/ssl/zimbra/commercial"
readonly RUNTIME_DIR="/run/zimbra-ssl"
readonly WAS_RUNNING_FILE="${RUNTIME_DIR}/was-running"

TEMP_DIR=""
ZIMBRA_NEEDS_START=0
CERT_DEPLOYED=0

info() {
  printf '\n\033[1;34m[zimbra-ssl]\033[0m %s\n' "$*"
}

warn() {
  printf '\n\033[1;33m[zimbra-ssl]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\n\033[1;31m[zimbra-ssl]\033[0m %s\n' "$*" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_domain() {
  local value
  value="$(trim "$1")"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="${value%.}"
  printf '%s' "$value"
}

valid_domain() {
  local domain="$1"
  local label
  local -a labels

  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" != *..* ]] || return 1
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1

  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

require_root() {
  (( EUID == 0 )) || die "Hãy chạy script bằng root hoặc sudo."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Không tìm thấy lệnh: $1"
}

require_zimbra() {
  id zimbra >/dev/null 2>&1 || die "Không tìm thấy user zimbra."
  [[ -x "$ZMCERTMGR" ]] || die "Không tìm thấy: ${ZMCERTMGR}"
  [[ -x "$ZMCONTROL" ]] || die "Không tìm thấy: ${ZMCONTROL}"
  require_command su
}

run_as_zimbra() {
  local command_string=""
  printf -v command_string '%q ' "$@"
  su - zimbra -c "$command_string"
}

zimbra_control() {
  run_as_zimbra "$ZMCONTROL" "$1"
}

zimbra_is_running() {
  local status_output
  status_output="$(zimbra_control status 2>/dev/null || true)"
  grep -qE '(^|[[:space:]])Running([[:space:]]|$)' <<< "$status_output"
}

stop_for_certbot() {
  install -d -o root -g root -m 700 "$RUNTIME_DIR"

  if [[ -f "$WAS_RUNNING_FILE" ]]; then
    warn "Phát hiện lần Certbot trước bị gián đoạn; giữ trạng thái cần khởi động lại."
    return
  fi

  if zimbra_is_running; then
    install -o root -g root -m 600 /dev/null "$WAS_RUNNING_FILE"
    zimbra_control stop
  else
    info "Zimbra đã dừng từ trước; không thay đổi trạng thái dịch vụ."
  fi
}

start_after_certbot() {
  if [[ -f "$WAS_RUNNING_FILE" ]]; then
    zimbra_control start
    rm -f -- "$WAS_RUNNING_FILE"
  fi
}

make_temp_dir() {
  if [[ -z "$TEMP_DIR" ]]; then
    TEMP_DIR="$(mktemp -d /var/tmp/zimbra-ssl.XXXXXX)"
    chmod 700 "$TEMP_DIR"
  fi
}

cleanup() {
  local exit_code="$?"
  trap - EXIT

  if (( ZIMBRA_NEEDS_START )); then
    warn "Đang khởi động lại Zimbra sau lỗi..."
    if ! zimbra_control start; then
      warn "Không thể tự khởi động Zimbra. Hãy chạy: su - zimbra -c 'zmcontrol start'"
      exit_code=1
    fi
  fi

  case "$TEMP_DIR" in
    /var/tmp/zimbra-ssl.*)
      rm -rf -- "$TEMP_DIR"
      ;;
  esac

  exit "$exit_code"
}

trap cleanup EXIT

certificate_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 \
    | cut -d= -f2 \
    | tr -d ':' \
    | tr '[:lower:]' '[:upper:]'
}

ensure_root_ca() {
  local downloaded_ca

  install -d -o root -g root -m 700 "$CONFIG_DIR"

  if [[ -s "$ROOT_CA_FILE" ]] \
    && [[ "$(certificate_fingerprint "$ROOT_CA_FILE" 2>/dev/null || true)" == "$ROOT_CA_SHA256" ]]; then
    return
  fi

  make_temp_dir
  downloaded_ca="${TEMP_DIR}/ISRG-Root-X1.pem"

  info "Đang tải ISRG Root X1..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$ROOT_CA_URL" -o "$downloaded_ca"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$downloaded_ca" "$ROOT_CA_URL"
  else
    die "Cần curl hoặc wget để tải ISRG Root X1."
  fi

  [[ "$(certificate_fingerprint "$downloaded_ca")" == "$ROOT_CA_SHA256" ]] \
    || die "Fingerprint của ISRG Root X1 không hợp lệ."

  install -o root -g root -m 644 "$downloaded_ca" "$ROOT_CA_FILE"
}

find_certbot() {
  local certbot_path

  certbot_path="$(type -P certbot 2>/dev/null || true)"
  if [[ -n "$certbot_path" && -x "$certbot_path" ]]; then
    printf '%s' "$certbot_path"
    return 0
  fi

  for certbot_path in /snap/bin/certbot /usr/local/bin/certbot /usr/bin/certbot; do
    if [[ -x "$certbot_path" ]]; then
      printf '%s' "$certbot_path"
      return 0
    fi
  done

  return 1
}

install_certbot() {
  if find_certbot >/dev/null; then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 \
    || die "Không tìm thấy Certbot. Tự động cài đặt hiện hỗ trợ Debian/Ubuntu có apt-get."

  info "Đang cài Certbot..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
  find_certbot >/dev/null || die "Đã cài nhưng không tìm thấy executable Certbot."
}

deploy_certificate() {
  local lineage="$1"
  local canonical_lineage
  local key_target="${COMMERCIAL_DIR}/commercial.key"
  local deployed_fingerprint
  local fingerprint_tmp

  [[ -d "$lineage" ]] || die "Không tìm thấy certificate lineage: ${lineage}"
  canonical_lineage="$(cd -- "$lineage" && pwd -P)"
  [[ "$canonical_lineage" == /etc/letsencrypt/live/* ]] \
    || die "Certificate lineage nằm ngoài /etc/letsencrypt/live."

  for cert_file in privkey.pem cert.pem chain.pem; do
    [[ -s "${canonical_lineage}/${cert_file}" ]] \
      || die "Thiếu file: ${canonical_lineage}/${cert_file}"
  done

  ensure_root_ca
  make_temp_dir

  install -m 600 "${canonical_lineage}/privkey.pem" "${TEMP_DIR}/commercial.key"
  install -m 644 "${canonical_lineage}/cert.pem" "${TEMP_DIR}/cert.pem"
  install -m 644 "${canonical_lineage}/chain.pem" "${TEMP_DIR}/chain.pem"
  cat "${TEMP_DIR}/chain.pem" "$ROOT_CA_FILE" > "${TEMP_DIR}/full-chain.pem"
  chmod 644 "${TEMP_DIR}/full-chain.pem"

  chown -R zimbra:zimbra "$TEMP_DIR"
  chmod 700 "$TEMP_DIR"
  chmod 600 "${TEMP_DIR}/commercial.key"

  deployed_fingerprint="$(certificate_fingerprint "${TEMP_DIR}/cert.pem")"

  info "Đang kiểm tra certificate và private key..."
  run_as_zimbra \
    "$ZMCERTMGR" verifycrt comm \
    "${TEMP_DIR}/commercial.key" \
    "${TEMP_DIR}/cert.pem" \
    "${TEMP_DIR}/full-chain.pem"

  install -d -o zimbra -g zimbra -m 750 "$COMMERCIAL_DIR"
  install -o zimbra -g zimbra -m 600 "${TEMP_DIR}/commercial.key" "$key_target"

  info "Đang deploy certificate vào Zimbra..."
  run_as_zimbra \
    "$ZMCERTMGR" deploycrt comm \
    "${TEMP_DIR}/cert.pem" \
    "${TEMP_DIR}/full-chain.pem"

  install -d -o root -g root -m 700 "$CONFIG_DIR"
  fingerprint_tmp="$(mktemp "${DEPLOYED_FINGERPRINT_FILE}.XXXXXX")"
  printf '%s\n' "$deployed_fingerprint" > "$fingerprint_tmp"
  install -o root -g root -m 600 "$fingerprint_tmp" "$DEPLOYED_FINGERPRINT_FILE"
  rm -f -- "$fingerprint_tmp"
  CERT_DEPLOYED=1
}

deploy_if_needed() {
  local lineage="$1"
  local current_fingerprint
  local deployed_fingerprint=""

  [[ -s "${lineage}/cert.pem" ]] || die "Thiếu certificate: ${lineage}/cert.pem"
  current_fingerprint="$(certificate_fingerprint "${lineage}/cert.pem")"
  if [[ -s "$DEPLOYED_FINGERPRINT_FILE" ]]; then
    deployed_fingerprint="$(trim "$(< "$DEPLOYED_FINGERPRINT_FILE")")"
  fi

  if [[ "$current_fingerprint" == "$deployed_fingerprint" ]]; then
    info "Certificate hiện tại đã được deploy; không cần thực hiện lại."
    return
  fi

  deploy_certificate "$lineage"
}

resolve_script_path() {
  local source_path="${BASH_SOURCE[0]}"
  local source_dir

  if [[ "$source_path" != */* ]]; then
    source_path="$(command -v -- "$source_path" 2>/dev/null || printf '%s' "$source_path")"
  fi
  if [[ "$source_path" != /* ]]; then
    source_path="${PWD}/${source_path}"
  fi

  source_dir="$(cd -P -- "$(dirname -- "$source_path")" && pwd)"
  printf '%s/%s\n' "$source_dir" "$(basename -- "$source_path")"
}

install_automation() {
  local domain="$1"
  local script_path
  local certbot_path
  local domain_tmp
  local certbot_tmp
  local cron_tmp

  script_path="$(resolve_script_path)"
  certbot_path="$(find_certbot)"
  [[ "$certbot_path" =~ ^/[A-Za-z0-9_./-]+$ ]] \
    || die "Đường dẫn Certbot không an toàn cho cron: ${certbot_path}"
  install -d -o root -g root -m 700 "$CONFIG_DIR"

  domain_tmp="$(mktemp "${DOMAIN_FILE}.XXXXXX")"
  printf '%s\n' "$domain" > "$domain_tmp"
  install -o root -g root -m 600 "$domain_tmp" "$DOMAIN_FILE"
  rm -f -- "$domain_tmp"

  certbot_tmp="$(mktemp "${CERTBOT_FILE}.XXXXXX")"
  printf '%s\n' "$certbot_path" > "$certbot_tmp"
  install -o root -g root -m 600 "$certbot_tmp" "$CERTBOT_FILE"
  rm -f -- "$certbot_tmp"

  if [[ "$script_path" != "$INSTALL_PATH" ]]; then
    install -o root -g root -m 750 "$script_path" "$INSTALL_PATH"
  else
    chown root:root "$INSTALL_PATH"
    chmod 750 "$INSTALL_PATH"
  fi

  cron_tmp="$(mktemp "${CRON_FILE}.XXXXXX")"
  {
    printf '%s\n' 'SHELL=/bin/sh'
    printf '%s\n' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    printf '17 3,15 * * * root %s --renew\n' "$INSTALL_PATH"
  } > "$cron_tmp"
  install -o root -g root -m 644 "$cron_tmp" "$CRON_FILE"
  rm -f -- "$cron_tmp"
}

configured_domain() {
  local domain
  [[ -s "$DOMAIN_FILE" ]] || die "Thiếu cấu hình domain: ${DOMAIN_FILE}"
  domain="$(normalize_domain "$(< "$DOMAIN_FILE")")"
  valid_domain "$domain" || die "Domain cấu hình không hợp lệ: ${domain}"
  printf '%s' "$domain"
}

configured_certbot() {
  local certbot_path

  [[ -s "$CERTBOT_FILE" ]] || die "Thiếu cấu hình Certbot: ${CERTBOT_FILE}"
  certbot_path="$(trim "$(< "$CERTBOT_FILE")")"
  [[ "$certbot_path" =~ ^/[A-Za-z0-9_./-]+$ && -x "$certbot_path" ]] \
    || die "Đường dẫn Certbot không hợp lệ: ${certbot_path}"
  printf '%s' "$certbot_path"
}

renew_certificate() {
  local domain
  local certbot_path
  local lineage
  local renew_exit=0

  domain="$(configured_domain)"
  certbot_path="$(configured_certbot)"
  lineage="/etc/letsencrypt/live/${domain}"

  info "Đang kiểm tra gia hạn certificate cho ${domain}..."
  "$certbot_path" renew \
    --quiet \
    --cert-name "$domain" \
    --pre-hook "${INSTALL_PATH} --stop" \
    --post-hook "${INSTALL_PATH} --start" \
    || renew_exit="$?"

  # Certbot thường tự chạy post-hook; gọi lại để phục hồi nếu hook bị gián đoạn.
  start_after_certbot

  if ! zimbra_is_running; then
    warn "Zimbra đang dừng theo chủ ý của quản trị viên; chưa deploy certificate."
    return 1
  fi

  CERT_DEPLOYED=0
  deploy_if_needed "$lineage"
  if (( CERT_DEPLOYED )); then
    info "Đang restart Zimbra để nạp certificate mới..."
    zimbra_control restart
  fi

  return "$renew_exit"
}

prompt_domain() {
  local domain="${1:-}"

  while true; do
    if [[ -z "$domain" ]]; then
      read -r -p "Domain Zimbra (ví dụ mail.example.com): " domain \
        || die "Không đọc được domain."
    fi
    domain="$(normalize_domain "$domain")"
    if valid_domain "$domain"; then
      printf '%s' "$domain"
      return
    fi
    warn "Domain không hợp lệ. Ví dụ đúng: mail.example.com"
    domain=""
  done
}

prompt_email() {
  local domain="$1"
  local email="${2:-}"
  local default_email="admin@${domain}"

  while true; do
    if [[ -z "$email" ]]; then
      read -r -p "Email đăng ký Let's Encrypt [${default_email}]: " email \
        || die "Không đọc được email."
      email="${email:-$default_email}"
    fi
    email="$(trim "$email")"
    if valid_email "$email"; then
      printf '%s' "$email"
      return
    fi
    warn "Email không hợp lệ."
    email=""
  done
}

initial_install() {
  local domain_arg="${1:-}"
  local email_arg="${2:-}"
  local domain
  local email
  local lineage
  local certbot_path
  local certbot_help
  local -a certbot_args

  require_root
  require_zimbra
  require_command openssl
  require_command mktemp

  domain="$(prompt_domain "$domain_arg")"
  email="$(prompt_email "$domain" "$email_arg")"

  install_certbot
  certbot_path="$(find_certbot)"
  ensure_root_ca
  lineage="/etc/letsencrypt/live/${domain}"

  zimbra_is_running || die "Zimbra đang dừng. Hãy khởi động Zimbra trước khi cài SSL lần đầu."

  info "Đang dừng Zimbra để Certbot sử dụng cổng 80..."
  ZIMBRA_NEEDS_START=1
  zimbra_control stop

  info "Đang cấp hoặc gia hạn certificate cho ${domain}..."
  certbot_args=(
    certonly
    --standalone
    --non-interactive
    --agree-tos
    --email "$email"
    --cert-name "$domain"
    --rsa-key-size 2048
    -d "$domain"
  )
  certbot_help="$("$certbot_path" certonly --help all 2>&1 || true)"
  if grep -q -- '--key-type' <<< "$certbot_help"; then
    certbot_args+=(--key-type rsa)
  fi
  if grep -q -- '--preferred-chain' <<< "$certbot_help"; then
    certbot_args+=(--preferred-chain "ISRG Root X1")
  fi
  "$certbot_path" "${certbot_args[@]}"

  info "Đang khởi động Zimbra để LDAP sẵn sàng cho bước deploy..."
  zimbra_control start
  ZIMBRA_NEEDS_START=0

  deploy_certificate "$lineage"

  info "Đang restart Zimbra để nạp certificate mới..."
  zimbra_control restart

  install_automation "$domain"
  info "Cài SSL thành công. Tự động gia hạn được kiểm tra lúc 03:17 và 15:17 mỗi ngày."
}

usage() {
  cat << EOF
Cách dùng:
  sudo ./${SCRIPT_NAME} [mail.example.com] [admin@example.com]

Các chế độ nội bộ dành cho Certbot:
  ${INSTALL_PATH} --renew
  ${INSTALL_PATH} --stop
  ${INSTALL_PATH} --start
EOF
}

case "${1:-}" in
  --stop)
    require_root
    require_zimbra
    stop_for_certbot
    ;;
  --start)
    require_root
    require_zimbra
    start_after_certbot
    ;;
  --renew)
    require_root
    require_zimbra
    require_command openssl
    renew_certificate
    ;;
  -h | --help)
    usage
    ;;
  --*)
    die "Tùy chọn không hợp lệ: $1"
    ;;
  *)
    (( $# <= 2 )) || die "Quá nhiều tham số. Dùng --help để xem hướng dẫn."
    initial_install "${1:-}" "${2:-}"
    ;;
esac
