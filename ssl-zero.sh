#!/usr/bin/env bash
#
# ssl-zero.sh — Cài chứng chỉ SSL ZeroSSL cho cPanel (quyền user) qua acme.sh
#
# Sử dụng:
#   bash ssl-zero.sh                                              # chế độ tương tác
#   bash ssl-zero.sh -d example.com                               # chỉ định domain
#   bash ssl-zero.sh -d example.com -w ~/public_html -e admin@example.com
#   bash ssl-zero.sh -d example.com --no-www --keep               # không dùng www, giữ script
#
# Tùy chọn:
#   -d, --domain DOMAIN     Domain chính (bắt buộc nếu chạy non-interactive)
#   -w, --webroot PATH      Thư mục webroot (mặc định: ~/public_html)
#   -e, --email EMAIL       Email đăng ký ZeroSSL (mặc định: admin@DOMAIN)
#       --www DOMAIN        Domain www tùy chỉnh (mặc định: www.DOMAIN)
#       --no-www            Không cấp cho subdomain www
#       --no-delete         Không tự xóa script sau khi hoàn tất
#       --rsa               Dùng RSA 2048 thay vì ECDSA P-256
#       --force             Ép cấp lại chứng chỉ dù còn hạn
#   -h, --help              Hiển thị trợ giúp
#

# ── Không cho phép source ────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '\n[ssl-zero] Không source script này. Hãy chạy: bash ssl-zero.sh\n' >&2
  return 1
fi

set -Eeuo pipefail

readonly SCRIPT_NAME="ssl-zero.sh"
readonly ACME_BIN="${HOME}/.acme.sh/acme.sh"

# ── Logging ──────────────────────────────────────────────────────
_supports_color() {
  [[ -t 2 ]] && [[ "${TERM:-}" != dumb ]] && command -v tput &>/dev/null
}

if _supports_color; then
  _C_INFO='\033[1;34m'  _C_WARN='\033[1;33m'  _C_ERR='\033[1;31m'
  _C_OK='\033[1;32m'    _C_RST='\033[0m'
else
  _C_INFO='' _C_WARN='' _C_ERR='' _C_OK='' _C_RST=''
fi

info()  { printf "\n${_C_INFO}[ssl-zero]${_C_RST} %s\n" "$*"; }
ok()    { printf "\n${_C_OK}[ssl-zero ✔]${_C_RST} %s\n" "$*"; }
warn()  { printf "\n${_C_WARN}[ssl-zero]${_C_RST} %s\n" "$*" >&2; }
die()   { printf "\n${_C_ERR}[ssl-zero ✖]${_C_RST} %s\n" "$*" >&2; exit 1; }

# ── Tiện ích ─────────────────────────────────────────────────────
trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

normalize_domain() {
  local v
  v="$(trim "$1")"
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  v="${v%.}"       # bỏ trailing dot
  printf '%s' "$v"
}

valid_domain() {
  local d="$1"
  [[ ${#d} -le 253 ]]            || return 1
  [[ "$d" == *.* ]]              || return 1
  [[ "$d" != *..* ]]             || return 1
  [[ "$d" != -* && "$d" != *- ]] || return 1
  [[ "$d" =~ ^[a-z0-9.-]+$ ]]   || return 1

  local IFS='.' label
  local -a labels
  read -r -a labels <<< "$d"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

resolve_webroot() {
  local input="$1"
  case "$input" in
    "~")    input="$HOME" ;;
    "~/"*)  input="${HOME}/${input:2}" ;;
    /*)     : ;;
    *)      input="${PWD}/${input}" ;;
  esac
  printf '%s' "$input"
}

# ── HTTP downloader (curl ưu tiên, fallback wget) ───────────────
http_get() {
  local url="$1"
  if command -v curl &>/dev/null; then
    curl -fsSL -- "$url"
  elif command -v wget &>/dev/null; then
    wget -qO- -- "$url"
  else
    die "Cần curl hoặc wget để tải acme.sh."
  fi
}

# ── Tìm đường dẫn script (cho self-delete) ──────────────────────
resolve_script_path() {
  local src="${BASH_SOURCE[0]}"
  [[ "$src" == */* ]] || src="$(command -v -- "$src" 2>/dev/null || printf '%s' "$src")"
  [[ "$src" == /* ]]  || src="${PWD}/${src}"
  local dir
  dir="$(cd -P -- "$(dirname -- "$src")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s' "$dir" "$(basename -- "$src")"
}

self_delete() {
  local path="$1"
  if [[ -z "$path" || ! -f "$path" || "$(basename -- "$path")" != "$SCRIPT_NAME" ]]; then
    warn "Không thể tự xóa script. Xóa thủ công:"
    printf '  rm -- %q\n' "$path" >&2
    return
  fi
  if rm -- "$path" 2>/dev/null; then
    ok "Đã xóa script: ${path}"
  else
    warn "Không thể tự xóa script. Xóa thủ công:"
    printf '  rm -- %q\n' "$path" >&2
  fi
}

# ── Help ─────────────────────────────────────────────────────────
usage() {
  sed -n '2,/^$/{ s/^# \?//; p }' "$0"
  exit 0
}

# ── Kiểm tra môi trường ─────────────────────────────────────────
(( EUID != 0 )) || die "Hãy chạy bằng tài khoản user cPanel, không chạy bằng root."

if ! command -v uapi &>/dev/null && [[ -x /usr/local/cpanel/bin/uapi ]]; then
  export PATH="/usr/local/cpanel/bin:${PATH}"
fi
command -v uapi &>/dev/null \
  || die "Không tìm thấy lệnh uapi. Script này cần chạy trong cPanel có UAPI."

# ── Parse arguments ──────────────────────────────────────────────
ARG_DOMAIN=""
ARG_WWW=""
ARG_NO_WWW=false
ARG_WEBROOT=""
ARG_EMAIL=""
ARG_KEY_TYPE="ec-256"
ARG_NO_DELETE=false
ARG_FORCE=false

while (( $# > 0 )); do
  case "$1" in
    -h|--help)      usage ;;
    -d|--domain)    ARG_DOMAIN="$2";  shift ;;
    -w|--webroot)   ARG_WEBROOT="$2"; shift ;;
    -e|--email)     ARG_EMAIL="$2";   shift ;;
    --www)          ARG_WWW="$2";     shift ;;
    --no-www)       ARG_NO_WWW=true ;;
    --no-delete)    ARG_NO_DELETE=true ;;
    --rsa)          ARG_KEY_TYPE="2048" ;;
    --force)        ARG_FORCE=true ;;
    -*)             die "Tùy chọn không hợp lệ: $1  (chạy --help để xem trợ giúp)" ;;
    *)              die "Tham số không mong đợi: $1" ;;
  esac
  shift
done

# ── Tìm đường dẫn script ────────────────────────────────────────
SCRIPT_PATH=""
if resolved="$(resolve_script_path)"; then
  SCRIPT_PATH="$resolved"
fi

# ── Thu thập thông tin ───────────────────────────────────────────
printf '\nCÀI SSL ZEROSSL CHO CPANEL (QUYỀN USER)\n'
printf '%s\n' '──────────────────────────────────────────'

# Domain chính
DOMAIN=""
if [[ -n "$ARG_DOMAIN" ]]; then
  DOMAIN="$(normalize_domain "$ARG_DOMAIN")"
  valid_domain "$DOMAIN" || die "Domain không hợp lệ: $ARG_DOMAIN"
else
  while [[ -z "$DOMAIN" ]]; do
    read -r -p "Domain chính (ví dụ example.com): " input || die "Không đọc được domain."
    input="$(normalize_domain "$input")"
    if valid_domain "$input"; then
      DOMAIN="$input"
    else
      warn "Domain không hợp lệ. Ví dụ đúng: example.com"
    fi
  done
fi

# Domain www
WWW_DOMAIN=""
if $ARG_NO_WWW; then
  WWW_DOMAIN=""
elif [[ -n "$ARG_WWW" ]]; then
  WWW_DOMAIN="$(normalize_domain "$ARG_WWW")"
  valid_domain "$WWW_DOMAIN" || die "Domain www không hợp lệ: $ARG_WWW"
elif [[ -n "$ARG_DOMAIN" ]]; then
  # Non-interactive: mặc định thêm www
  WWW_DOMAIN="www.${DOMAIN}"
else
  local_default="www.${DOMAIN}"
  while true; do
    read -r -p "Domain www [${local_default}] (nhập - nếu không dùng): " input \
      || die "Không đọc được domain www."
    input="$(normalize_domain "$input")"

    if [[ -z "$input" ]]; then
      WWW_DOMAIN="$local_default"; break
    elif [[ "$input" == "-" ]]; then
      WWW_DOMAIN=""; break
    elif valid_domain "$input"; then
      WWW_DOMAIN="$input"; break
    fi
    warn "Domain www không hợp lệ."
  done
fi

# Webroot
WEBROOT=""
if [[ -n "$ARG_WEBROOT" ]]; then
  webroot_path="$(resolve_webroot "$ARG_WEBROOT")"
  [[ -d "$webroot_path" ]] || die "Thư mục webroot không tồn tại: $webroot_path"
  WEBROOT="$(cd -- "$webroot_path" && pwd -P)"
else
  default_webroot="${HOME}/public_html"
  while [[ -z "$WEBROOT" ]]; do
    read -r -p "Thư mục webroot [${default_webroot}]: " input \
      || die "Không đọc được webroot."
    input="$(trim "${input:-$default_webroot}")"
    webroot_path="$(resolve_webroot "$input")"

    if [[ ! -d "$webroot_path" ]]; then
      warn "Thư mục không tồn tại: ${webroot_path}"; continue
    fi
    if [[ ! -r "$webroot_path" || ! -w "$webroot_path" || ! -x "$webroot_path" ]]; then
      warn "Thiếu quyền đọc/ghi trên: ${webroot_path}"; continue
    fi
    WEBROOT="$(cd -- "$webroot_path" && pwd -P)"
  done
fi

# Email
EMAIL=""
default_email="admin@${DOMAIN}"
if [[ -n "$ARG_EMAIL" ]]; then
  EMAIL="$(trim "$ARG_EMAIL")"
  valid_email "$EMAIL" || die "Email không hợp lệ: $ARG_EMAIL"
else
  while true; do
    read -r -p "Email ZeroSSL [${default_email}]: " input \
      || die "Không đọc được email."
    EMAIL="$(trim "${input:-$default_email}")"
    valid_email "$EMAIL" && break
    warn "Email không hợp lệ."
  done
fi

# ── Hiển thị tóm tắt ────────────────────────────────────────────
key_label="ECDSA P-256"
[[ "$ARG_KEY_TYPE" != "2048" ]] || key_label="RSA 2048"

info "Thông tin cài đặt"
printf '  Domain:   %s\n' "$DOMAIN"
if [[ -n "$WWW_DOMAIN" ]]; then
  printf '  WWW:      %s\n' "$WWW_DOMAIN"
else
  printf '  WWW:      (không sử dụng)\n'
fi
printf '  Webroot:  %s\n' "$WEBROOT"
printf '  Email:    %s\n' "$EMAIL"
printf '  Key:      %s\n' "$key_label"

# ── Cài acme.sh nếu chưa có ─────────────────────────────────────
if [[ ! -x "$ACME_BIN" ]]; then
  info "Đang cài acme.sh..."
  http_get https://get.acme.sh | sh -s "email=${EMAIL}"
fi
[[ -x "$ACME_BIN" ]] || die "Không tìm thấy acme.sh sau khi cài: ${ACME_BIN}"

# ── Đăng ký tài khoản ZeroSSL ───────────────────────────────────
info "Đang đăng ký / kiểm tra tài khoản ZeroSSL..."
"$ACME_BIN" \
  --register-account \
  --server zerossl \
  --email "$EMAIL" \
  || die "Không thể đăng ký tài khoản ZeroSSL."

# ── Build domain args ───────────────────────────────────────────
domain_args=(--domain "$DOMAIN")
if [[ -n "$WWW_DOMAIN" && "$WWW_DOMAIN" != "$DOMAIN" ]]; then
  domain_args+=(--domain "$WWW_DOMAIN")
fi

# ── Key type args ────────────────────────────────────────────────
key_args=()
if [[ "$ARG_KEY_TYPE" == "ec-256" ]]; then
  key_args=(--keylength ec-256)
else
  key_args=(--keylength 2048)
fi

# ── Force flag ───────────────────────────────────────────────────
force_args=()
if $ARG_FORCE; then
  force_args=(--force)
fi

# ── Cấp chứng chỉ ───────────────────────────────────────────────
info "Đang xác thực domain và cấp chứng chỉ ZeroSSL..."
"$ACME_BIN" \
  --issue \
  --server zerossl \
  --webroot "$WEBROOT" \
  "${domain_args[@]}" \
  "${key_args[@]}" \
  "${force_args[@]}" \
  || die "Không thể cấp chứng chỉ. Kiểm tra domain trỏ đúng IP và webroot có thể truy cập."

# ── Deploy vào cPanel ────────────────────────────────────────────
info "Đang deploy chứng chỉ vào cPanel..."
DEPLOY_CPANEL_AUTO_ENABLED=false \
  "$ACME_BIN" \
  --deploy \
  --deploy-hook cpanel_uapi \
  "${domain_args[@]}" \
  || die "Deploy chứng chỉ vào cPanel thất bại."

# ── Thành công ───────────────────────────────────────────────────
ok "SSL ZeroSSL đã được cài thành công cho ${DOMAIN}!"
printf '\n  ℹ  acme.sh sẽ tự động gia hạn qua cron mỗi 60 ngày.\n'
printf '     Kiểm tra cron:  crontab -l | grep acme\n'
printf '     Gia hạn thủ công: %s --renew %s --server zerossl\n\n' \
  "$ACME_BIN" "${domain_args[*]}"

# ── Tự xóa script (mặc định, trừ khi có --no-delete) ────────────
if ! $ARG_NO_DELETE; then
  self_delete "$SCRIPT_PATH"
fi
