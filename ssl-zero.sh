#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '\n[ssl-zero] Không source script này. Hãy chạy: bash ssl-zero.sh\n' >&2
  return 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="ssl-zero.sh"
ACME_BIN="${HOME}/.acme.sh/acme.sh"

info() {
  printf '\n\033[1;34m[ssl-zero]\033[0m %s\n' "$*"
}

warn() {
  printf '\n\033[1;33m[ssl-zero]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\n\033[1;31m[ssl-zero]\033[0m %s\n' "$*" >&2
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
  [[ "$domain" != -* && "$domain" != *- ]] || return 1
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

resolve_script_path() {
  local source_path="${BASH_SOURCE[0]}"
  local source_dir

  if [[ "$source_path" != */* ]]; then
    source_path="$(command -v -- "$source_path" 2>/dev/null || printf '%s' "$source_path")"
  fi

  if [[ "$source_path" != /* ]]; then
    source_path="${PWD}/${source_path}"
  fi

  source_dir="$(cd -P -- "$(dirname -- "$source_path")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "$source_dir" "$(basename -- "$source_path")"
}

self_delete() {
  local script_path="$1"

  if [[ -n "$script_path" && -f "$script_path" && "$(basename -- "$script_path")" == "$SCRIPT_NAME" ]]; then
    if rm -- "$script_path"; then
      info "Đã cài SSL thành công và xóa script: ${script_path}"
      return
    fi
  fi

  warn "SSL đã được cài nhưng không thể tự xóa script. Hãy xóa thủ công bằng lệnh:"
  printf 'rm -- %q\n' "$script_path" >&2
}

(( EUID != 0 )) || die "Hãy chạy bằng tài khoản user cPanel, không chạy bằng root."

if ! command -v uapi >/dev/null 2>&1 && [[ -x /usr/local/cpanel/bin/uapi ]]; then
  PATH="/usr/local/cpanel/bin:${PATH}"
  export PATH
fi

command -v uapi >/dev/null 2>&1 \
  || die "Không tìm thấy lệnh uapi. Script này cần chạy trong cPanel có UAPI."

SCRIPT_PATH=""
if resolved_path="$(resolve_script_path)"; then
  SCRIPT_PATH="$resolved_path"
fi

printf '\nCÀI SSL ZEROSSL CHO CPANEL (QUYỀN USER)\n'
printf '%s\n' '--------------------------------------'

DOMAIN=""
while [[ -z "$DOMAIN" ]]; do
  read -r -p "Domain chính, không gồm http:// (ví dụ example.com): " domain_input \
    || die "Không đọc được domain."
  domain_input="$(normalize_domain "$domain_input")"

  if valid_domain "$domain_input"; then
    DOMAIN="$domain_input"
  else
    warn "Domain không hợp lệ. Ví dụ đúng: example.com"
  fi
done

DEFAULT_WWW="www.${DOMAIN}"
while true; do
  read -r -p "Domain www [${DEFAULT_WWW}] (nhập - nếu không dùng www): " www_input \
    || die "Không đọc được domain www."
  www_input="$(normalize_domain "$www_input")"

  if [[ -z "$www_input" ]]; then
    WWW_DOMAIN="$DEFAULT_WWW"
    break
  fi

  if [[ "$www_input" == "-" ]]; then
    WWW_DOMAIN=""
    break
  fi

  if valid_domain "$www_input"; then
    WWW_DOMAIN="$www_input"
    break
  fi

  warn "Domain www không hợp lệ. Ví dụ đúng: ${DEFAULT_WWW}"
done

WEBROOT=""
while [[ -z "$WEBROOT" ]]; do
  read -r -p "Thư mục webroot (ví dụ ~/public_html): " webroot_input \
    || die "Không đọc được thư mục webroot."
  webroot_input="$(trim "$webroot_input")"

  case "$webroot_input" in
    "")
      warn "Bạn chưa nhập thư mục webroot."
      continue
      ;;
    "~")
      webroot_path="$HOME"
      ;;
    "~/"*)
      webroot_path="${HOME}/${webroot_input:2}"
      ;;
    /*)
      webroot_path="$webroot_input"
      ;;
    *)
      webroot_path="${PWD}/${webroot_input}"
      ;;
  esac

  if [[ ! -d "$webroot_path" ]]; then
    warn "Thư mục không tồn tại: ${webroot_path}"
    continue
  fi

  if [[ ! -r "$webroot_path" || ! -w "$webroot_path" || ! -x "$webroot_path" ]]; then
    warn "Bạn cần quyền đọc, ghi và truy cập thư mục: ${webroot_path}"
    continue
  fi

  WEBROOT="$(cd -- "$webroot_path" && pwd -P)"
done

DEFAULT_EMAIL="admin@${DOMAIN}"
while true; do
  read -r -p "Email đăng ký ZeroSSL [${DEFAULT_EMAIL}]: " email_input \
    || die "Không đọc được email."
  EMAIL="$(trim "${email_input:-$DEFAULT_EMAIL}")"

  if valid_email "$EMAIL"; then
    break
  fi

  warn "Email không hợp lệ."
done

info "Thông tin cài đặt"
printf '  Domain:  %s\n' "$DOMAIN"
if [[ -n "$WWW_DOMAIN" ]]; then
  printf '  WWW:     %s\n' "$WWW_DOMAIN"
else
  printf '  WWW:     không sử dụng\n'
fi
printf '  Webroot: %s\n' "$WEBROOT"
printf '  Email:   %s\n' "$EMAIL"

if [[ ! -x "$ACME_BIN" ]]; then
  command -v wget >/dev/null 2>&1 || die "Không tìm thấy lệnh wget."

  info "Đang cài acme.sh..."
  wget -qO- -- https://get.acme.sh | sh -s "email=${EMAIL}"
fi

[[ -x "$ACME_BIN" ]] || die "Không tìm thấy acme.sh sau khi cài: ${ACME_BIN}"

info "Đang đăng ký hoặc kiểm tra tài khoản ZeroSSL..."
"$ACME_BIN" \
  --register-account \
  --server zerossl \
  --email "$EMAIL"

domain_args=(--domain "$DOMAIN")
if [[ -n "$WWW_DOMAIN" && "$WWW_DOMAIN" != "$DOMAIN" ]]; then
  domain_args+=(--domain "$WWW_DOMAIN")
fi

info "Đang xác thực domain và cấp chứng chỉ ZeroSSL..."
"$ACME_BIN" \
  --issue \
  --server zerossl \
  --webroot "$WEBROOT" \
  "${domain_args[@]}" \
  --keylength 2048 \
  --force

info "Đang deploy chứng chỉ vào cPanel..."
DEPLOY_CPANEL_AUTO_ENABLED=false \
  "$ACME_BIN" \
  --deploy \
  --deploy-hook cpanel_uapi \
  "${domain_args[@]}"

self_delete "$SCRIPT_PATH"
