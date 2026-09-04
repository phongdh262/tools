#!/usr/bin/env bash
#
# Deploy một commercial TLS certificate đã được CA cấp vào Zimbra.
# Không cấp mới/gia hạn certificate và không sử dụng Certbot/ACME.

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '[zimbra-ssl-deploy] Không source script này. Hãy chạy bằng sudo.\n' >&2
  return 1
fi

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly ZMCERTMGR="/opt/zimbra/bin/zmcertmgr"
readonly ZMCONTROL="/opt/zimbra/bin/zmcontrol"
readonly COMMERCIAL_DIR="/opt/zimbra/ssl/zimbra/commercial"
readonly DEFAULT_KEY="${COMMERCIAL_DIR}/commercial.key"
readonly BACKUP_ROOT="/opt/zimbra/ssl/zimbra/ssl-deploy-backups"
readonly LOCK_FILE="/run/lock/zimbra-ssl-deploy.lock"

TEMP_DIR=""
BACKUP_PATH=""
DEPLOY_STARTED=0
VERIFY_ONLY=0
RESTART_ZIMBRA=1
POSITIONAL_ARGS=()

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  readonly BLUE=$'\033[1;34m'
  readonly YELLOW=$'\033[1;33m'
  readonly RED=$'\033[1;31m'
  readonly RESET=$'\033[0m'
else
  readonly BLUE=""
  readonly YELLOW=""
  readonly RED=""
  readonly RESET=""
fi

info() {
  printf '\n%s[zimbra-ssl-deploy]%s %s\n' "$BLUE" "$RESET" "$*"
}

warn() {
  printf '\n%s[zimbra-ssl-deploy]%s CẢNH BÁO: %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
  printf '\n%s[zimbra-ssl-deploy]%s LỖI: %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

cleanup() {
  local exit_code="$?"
  trap - EXIT

  if (( exit_code != 0 && DEPLOY_STARTED == 1 )) && [[ -n "$BACKUP_PATH" ]]; then
    warn "Deploy không hoàn tất. Bản sao lưu certificate cũ nằm tại: ${BACKUP_PATH}"
    warn "Không restart Zimbra cho đến khi đã kiểm tra/khôi phục certificate nếu cần."
  fi

  case "$TEMP_DIR" in
    /var/tmp/zimbra-ssl-deploy.*)
      rm -rf -- "$TEMP_DIR"
      ;;
  esac

  exit "$exit_code"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  sudo ./${SCRIPT_NAME} [options] <cert.crt> <ca_bundle.crt> [private.key]

Arguments:
  cert.crt       Server/leaf certificate (PEM, chỉ chứa 1 certificate).
  ca_bundle.crt  CA chain (PEM), thứ tự intermediate gần leaf nhất -> root.
  private.key    Private key không mã hóa. Nếu bỏ qua, dùng:
                 ${DEFAULT_KEY}

Options:
  --verify-only  Chỉ kiểm tra, không backup/deploy/restart.
  --no-restart   Deploy nhưng không restart Zimbra.
  -h, --help     Hiển thị hướng dẫn.

Examples:
  sudo ./${SCRIPT_NAME} mail.example.com.crt ca_bundle.crt
  sudo ./${SCRIPT_NAME} --verify-only cert.pem chain.pem private.key
  sudo ./${SCRIPT_NAME} --no-restart cert.pem chain.pem private.key
EOF
}

require_root() {
  (( EUID == 0 )) || die "Hãy chạy script bằng root hoặc sudo."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Không tìm thấy lệnh bắt buộc: $1"
}

require_zimbra() {
  id zimbra >/dev/null 2>&1 || die "Không tìm thấy user zimbra."
  [[ -x "$ZMCERTMGR" ]] || die "Không tìm thấy hoặc không thể chạy: ${ZMCERTMGR}"
  [[ -x "$ZMCONTROL" ]] || die "Không tìm thấy hoặc không thể chạy: ${ZMCONTROL}"

  require_command awk
  require_command chown
  require_command chmod
  require_command cmp
  require_command cp
  require_command date
  require_command flock
  require_command grep
  require_command install
  require_command mktemp
  require_command mv
  require_command openssl
  require_command rm
  require_command sed
  require_command su
}

acquire_lock() {
  install -d -o root -g root -m 755 "${LOCK_FILE%/*}"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Một tiến trình deploy SSL khác đang chạy."
}

run_as_zimbra() {
  local command_string=""
  printf -v command_string '%q ' "$@"
  su - zimbra -c "$command_string"
}

zimbra_control() {
  run_as_zimbra "$ZMCONTROL" "$1"
}

zimbra_has_running_services() {
  local status_output
  status_output="$(zimbra_control status 2>/dev/null || true)"
  grep -qE '^[[:space:]]*[[:alnum:]_.-]+[[:space:]]+Running[[:space:]]*$' <<<"$status_output"
}

resolve_abs_path() {
  local path="$1"
  [[ -f "$path" ]] || die "Không tìm thấy file: ${path}"
  (cd -- "$(dirname -- "$path")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$path")")
}

pem_certificate_count() {
  awk '{ sub(/\r$/, "", $0) } $0 == "-----BEGIN CERTIFICATE-----" { count++ } END { print count + 0 }' "$1"
}

make_temp_dir() {
  TEMP_DIR="$(mktemp -d /var/tmp/zimbra-ssl-deploy.XXXXXX)"
  chmod 700 "$TEMP_DIR"
}

stage_inputs() {
  local cert_path="$1"
  local chain_path="$2"
  local key_path="$3"

  install -m 644 "$cert_path" "${TEMP_DIR}/commercial.crt"
  install -m 644 "$chain_path" "${TEMP_DIR}/commercial_ca.crt"
  install -m 600 "$key_path" "${TEMP_DIR}/commercial.key"
}

try_fix_chain() {
  local cert="${TEMP_DIR}/commercial.crt"
  local chain="${TEMP_DIR}/commercial_ca.crt"
  local max_depth=5
  local depth=0
  local fixed_any=0

  while (( depth < max_depth )); do
    # Nếu chain đã hợp lệ thì dừng
    if openssl verify -purpose sslserver -CAfile "$chain" "$cert" >/dev/null 2>&1; then
      if (( fixed_any )); then
        info "Đã tự động bổ sung CA thiếu vào chain. Xác minh thành công."
      fi
      return 0
    fi

    # Lấy certificate cuối cùng trong chain
    awk '
      /-----BEGIN CERTIFICATE-----/ { cert = "" }
      { cert = cert $0 "\n" }
      /-----END CERTIFICATE-----/ { last = cert }
      END { printf "%s", last }
    ' "$chain" > "${TEMP_DIR}/last_in_chain.pem"

    local issuer_hash subject_hash
    issuer_hash=$(openssl x509 -in "${TEMP_DIR}/last_in_chain.pem" -noout -issuer_hash 2>/dev/null || true)
    subject_hash=$(openssl x509 -in "${TEMP_DIR}/last_in_chain.pem" -noout -subject_hash 2>/dev/null || true)

    # Nếu đã là self-signed (root) thì không thể đi thêm
    if [[ "$issuer_hash" == "$subject_hash" ]]; then
      break
    fi

    local found=0

    # === Phương pháp 1: Tải CA thiếu qua AIA (Authority Information Access) ===
    local aia_url
    aia_url=$(
      openssl x509 -in "${TEMP_DIR}/last_in_chain.pem" -noout -text 2>/dev/null \
        | sed -n '/CA Issuers/s/.*URI:\(http[^ ]*\).*/\1/p' | head -1
    )

    if [[ -n "$aia_url" ]] && command -v curl >/dev/null 2>&1; then
      info "Đang tải CA thiếu từ AIA: ${aia_url}"
      if curl -fsSL --max-time 30 -o "${TEMP_DIR}/aia_ca.tmp" "$aia_url" 2>/dev/null; then
        # Thử DER trước, rồi PEM
        if openssl x509 -inform DER -in "${TEMP_DIR}/aia_ca.tmp" -outform PEM \
             >> "$chain" 2>/dev/null; then
          found=1
        elif openssl x509 -in "${TEMP_DIR}/aia_ca.tmp" -outform PEM \
               >> "$chain" 2>/dev/null; then
          found=1
        fi
      fi
    fi

    # === Phương pháp 2: Tìm trong system CA store bằng issuer hash ===
    if (( !found )); then
      local sys_cert_dir="/etc/ssl/certs"
      if [[ -d "$sys_cert_dir" ]]; then
        local hash_link="${sys_cert_dir}/${issuer_hash}.0"
        if [[ -f "$hash_link" ]]; then
          info "Tìm thấy CA thiếu trong system store: ${hash_link}"
          if openssl x509 -in "$hash_link" -outform PEM >> "$chain" 2>/dev/null; then
            found=1
          fi
        fi
      fi
    fi

    # === Phương pháp 3: Tìm bằng tên CN (SecureTrust_CA, v.v.) ===
    if (( !found )); then
      local issuer_cn
      issuer_cn=$(
        openssl x509 -in "${TEMP_DIR}/last_in_chain.pem" -noout -issuer 2>/dev/null \
          | sed -n 's/.*CN *= *\([^,\/]*\).*/\1/p'
      )

      if [[ -n "$issuer_cn" ]]; then
        # Chuẩn hóa tên để tìm file: "SecureTrust CA" -> "SecureTrust_CA"
        local search_name
        search_name=$(printf '%s' "$issuer_cn" | tr ' ' '_' | sed 's/[^a-zA-Z0-9_.-]//g')

        local sys_cert
        for sys_cert in \
          "/etc/ssl/certs/${search_name}.pem" \
          "/usr/share/ca-certificates/mozilla/${search_name}.crt" \
          "/etc/pki/tls/certs/${search_name}.pem" \
          "/usr/local/share/ca-certificates/${search_name}.crt"; do
          if [[ -f "$sys_cert" ]]; then
            info "Tìm thấy CA thiếu: ${sys_cert}"
            if openssl x509 -in "$sys_cert" -outform PEM >> "$chain" 2>/dev/null; then
              found=1
              break
            fi
          fi
        done
      fi
    fi

    if (( !found )); then
      break
    fi

    fixed_any=1
    (( depth++ ))
  done

  return 1
}

validate_inputs() {
  local cert="${TEMP_DIR}/commercial.crt"
  local chain="${TEMP_DIR}/commercial_ca.crt"
  local key="${TEMP_DIR}/commercial.key"
  local cert_count chain_count

  cert_count="$(pem_certificate_count "$cert")"
  chain_count="$(pem_certificate_count "$chain")"

  (( cert_count == 1 )) \
    || die "cert.crt phải là PEM và chỉ chứa 1 server certificate (hiện có ${cert_count})."
  (( chain_count >= 1 )) \
    || die "ca_bundle.crt không chứa certificate PEM nào."

  openssl x509 -in "$cert" -noout >/dev/null 2>&1 \
    || die "Không đọc được server certificate PEM."
  openssl crl2pkcs7 -nocrl -certfile "$chain" -outform DER \
    -out "${TEMP_DIR}/chain.p7b" >/dev/null 2>&1 \
    || die "CA bundle có certificate lỗi hoặc không đúng định dạng PEM."

  openssl pkey -in "$key" -passin pass: -noout >/dev/null 2>&1 \
    || die "Private key không hợp lệ hoặc đang được mã hóa. Zimbra cần key không có passphrase."

  openssl x509 -in "$cert" -pubkey -noout \
    | openssl pkey -pubin -outform DER -out "${TEMP_DIR}/cert-public.der" 2>/dev/null \
    || die "Không trích xuất được public key từ certificate."
  openssl pkey -in "$key" -passin pass: -pubout -outform DER \
    -out "${TEMP_DIR}/key-public.der" >/dev/null 2>&1 \
    || die "Không trích xuất được public key từ private key."

  cmp -s "${TEMP_DIR}/cert-public.der" "${TEMP_DIR}/key-public.der" \
    || die "Private key KHÔNG khớp với server certificate."

  if ! openssl verify -purpose sslserver -CAfile "$chain" "$cert" >/dev/null 2>&1; then
    warn "Xác minh chain thất bại. Đang thử tự động bổ sung CA thiếu..."
    if ! try_fix_chain; then
      die "Không xác minh được server certificate bằng CA bundle. Kiểm tra lại chain và thứ tự intermediate -> root."
    fi
  fi
}

show_certificate_summary() {
  local cert="${TEMP_DIR}/commercial.crt"
  local fingerprint

  fingerprint="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | sed 's/^[^=]*=//')"

  info "Thông tin certificate sẽ deploy:"
  openssl x509 -in "$cert" -noout -subject -issuer -serial -dates
  printf 'sha256 Fingerprint=%s\n' "$fingerprint"
}

verify_with_zimbra() {
  chown -R zimbra:zimbra "$TEMP_DIR"
  chmod 700 "$TEMP_DIR"
  chmod 600 "${TEMP_DIR}/commercial.key"

  info "Đang kiểm tra certificate/key/CA chain bằng zmcertmgr..."
  run_as_zimbra \
    "$ZMCERTMGR" verifycrt comm \
    "${TEMP_DIR}/commercial.key" \
    "${TEMP_DIR}/commercial.crt" \
    "${TEMP_DIR}/commercial_ca.crt"
}

backup_current_certificate() {
  BACKUP_PATH="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -o root -g root -m 700 "$BACKUP_ROOT"
  install -d -o root -g root -m 700 "$BACKUP_PATH"

  if [[ -d "$COMMERCIAL_DIR" ]]; then
    cp -a -- "${COMMERCIAL_DIR}/." "${BACKUP_PATH}/"
  fi

  info "Đã sao lưu certificate hiện tại tại: ${BACKUP_PATH}"
}

install_commercial_key() {
  local temporary_key="${COMMERCIAL_DIR}/.commercial.key.$$"

  install -d -o zimbra -g zimbra -m 750 "$COMMERCIAL_DIR"
  install -o zimbra -g zimbra -m 640 \
    "${TEMP_DIR}/commercial.key" "$temporary_key"
  mv -f -- "$temporary_key" "${COMMERCIAL_DIR}/commercial.key"
}

deploy_certificate() {
  local was_running=0

  if zimbra_has_running_services; then
    was_running=1
  fi

  backup_current_certificate
  install_commercial_key
  DEPLOY_STARTED=1

  info "Đang deploy commercial certificate vào Zimbra..."
  run_as_zimbra \
    "$ZMCERTMGR" deploycrt comm \
    "${TEMP_DIR}/commercial.crt" \
    "${TEMP_DIR}/commercial_ca.crt"

  DEPLOY_STARTED=0

  if (( RESTART_ZIMBRA == 0 )); then
    warn "Đã deploy nhưng chưa restart. Certificate mới chỉ có hiệu lực sau khi các dịch vụ liên quan được restart."
  elif (( was_running == 1 )); then
    info "Đang restart Zimbra để nạp certificate mới..."
    zimbra_control restart
  else
    warn "Zimbra đã dừng từ trước, nên script không tự khởi động. Hãy start khi sẵn sàng: su - zimbra -c 'zmcontrol start'"
  fi

  info "Đang đọc lại certificate đã deploy..."
  if ! run_as_zimbra "$ZMCERTMGR" viewdeployedcrt; then
    warn "Deploy đã hoàn tất nhưng không đọc lại được certificate bằng viewdeployedcrt."
  fi
}

parse_options() {
  while (( $# > 0 )); do
    case "$1" in
      --verify-only)
        VERIFY_ONLY=1
        ;;
      --no-restart)
        RESTART_ZIMBRA=0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage >&2
        die "Tùy chọn không hợp lệ: $1"
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  POSITIONAL_ARGS=("$@")
}

main() {
  local cert_arg chain_arg key_arg
  local cert_path chain_path key_path

  parse_options "$@"
  set -- "${POSITIONAL_ARGS[@]}"

  (( $# == 2 || $# == 3 )) || { usage >&2; die "Cần 2 hoặc 3 file đầu vào."; }

  require_root
  require_zimbra
  acquire_lock

  cert_arg="$1"
  chain_arg="$2"
  key_arg="${3:-$DEFAULT_KEY}"

  cert_path="$(resolve_abs_path "$cert_arg")"
  chain_path="$(resolve_abs_path "$chain_arg")"
  key_path="$(resolve_abs_path "$key_arg")"

  [[ -s "$cert_path" ]] || die "Server certificate rỗng: ${cert_path}"
  [[ -s "$chain_path" ]] || die "CA bundle rỗng: ${chain_path}"
  [[ -s "$key_path" ]] || die "Private key rỗng: ${key_path}"

  make_temp_dir
  stage_inputs "$cert_path" "$chain_path" "$key_path"
  validate_inputs
  show_certificate_summary
  verify_with_zimbra

  if (( VERIFY_ONLY == 1 )); then
    info "Kiểm tra thành công. Không có thay đổi nào được thực hiện."
    exit 0
  fi

  deploy_certificate
  info "Hoàn tất. Commercial certificate mới đã được deploy vào Zimbra."
}

main "$@"
