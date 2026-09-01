#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '\n[zimbra-import-users] Không source script này. Hãy chạy trực tiếp bằng Bash.\n' >&2
  return 1
fi

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="zimbra-import-users.sh"
readonly ZIMBRA_USER="zimbra"
readonly ZMPROV="/opt/zimbra/bin/zmprov"
readonly CSV_SENTINEL="__ZIMBRA_IMPORT_END_7D25597__"

DRY_RUN=0
CSV_FILE=""
RUN_AS_ROOT=0

info() {
  printf '\n\033[1;34m[zimbra-import-users]\033[0m %s\n' "$*"
}

warn() {
  printf '\n\033[1;33m[zimbra-import-users]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\n\033[1;31m[zimbra-import-users]\033[0m %s\n' "$*" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

compact_error() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\t'/ }"
  printf '%.300s' "$value"
}

valid_email() {
  local email="$1"
  [[ "$email" =~ ^[^[:space:]@,]+@[^[:space:]@,]+\.[^[:space:]@,]+$ ]]
}

has_control_character() {
  [[ "$1" =~ [[:cntrl:]] ]]
}

usage() {
  cat << EOF
Cách dùng:
  sudo ./${SCRIPT_NAME} [--dry-run] users.csv
  su - zimbra -c '/đường/dẫn/${SCRIPT_NAME} [--dry-run] users.csv'

Định dạng CSV:
  email,password,firstname,lastname
  user@example.com,pass123,Nguyen,Van A

Lưu ý:
  - Dòng header email,... hoặc username,... sẽ được bỏ qua.
  - CSV phải có đúng 4 trường đơn giản; không hỗ trợ dấu phẩy bên trong trường.
  - Tài khoản đã tồn tại sẽ được bỏ qua và không bị cập nhật.
  - --dry-run chỉ kiểm tra, không tạo tài khoản.
EOF
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        (( $# == 1 )) || die "Sau -- phải có đúng một đường dẫn CSV."
        CSV_FILE="$1"
        return
        ;;
      -*)
        die "Tùy chọn không hợp lệ: $1"
        ;;
      *)
        [[ -z "$CSV_FILE" ]] || die "Chỉ được nhập một file CSV."
        CSV_FILE="$1"
        ;;
    esac
    shift
  done

  [[ -n "$CSV_FILE" ]] || die "Thiếu file CSV. Dùng --help để xem hướng dẫn."
}

check_csv_permissions() {
  local mode=""
  local mode_value

  if mode="$(stat -c '%a' "$CSV_FILE" 2>/dev/null)"; then
    :
  elif mode="$(stat -f '%Lp' "$CSV_FILE" 2>/dev/null)"; then
    :
  else
    return
  fi

  if [[ "$mode" =~ ^[0-7]+$ ]]; then
    mode_value=$((8#$mode))
    if (( (mode_value & 077) != 0 )); then
      warn "CSV có thể chứa mật khẩu và đang cho group/other truy cập (mode ${mode})."
      warn "Khuyến nghị chạy: chmod 600 -- $(printf '%q' "$CSV_FILE")"
    fi
  fi
}

prepare_zimbra() {
  local current_user
  local probe_output

  [[ -x "$ZMPROV" ]] || die "Không tìm thấy executable: ${ZMPROV}"
  id "$ZIMBRA_USER" >/dev/null 2>&1 || die "Không tìm thấy user zimbra."

  current_user="$(id -un)"
  if (( EUID == 0 )); then
    command -v runuser >/dev/null 2>&1 \
      || die "Không tìm thấy runuser để chạy zmprov bằng user zimbra."
    RUN_AS_ROOT=1
  elif [[ "$current_user" != "$ZIMBRA_USER" ]]; then
    die "Hãy chạy script bằng root/sudo hoặc user zimbra."
  fi

  if ! probe_output="$(run_zmprov gacf zimbraDefaultDomainName 2>&1)"; then
    die "Không kết nối được Zimbra/LDAP: $(compact_error "$probe_output")"
  fi
}

run_zmprov() {
  if (( RUN_AS_ROOT )); then
    runuser -u "$ZIMBRA_USER" -- "$ZMPROV" "$@"
  else
    "$ZMPROV" "$@"
  fi
}

import_users() {
  local raw_line
  local username
  local password
  local first_name
  local last_name
  local marker
  local header_key
  local display_name
  local account_output
  local line_number=0
  local total=0
  local created=0
  local planned=0
  local skipped=0
  local failed=0
  local -a create_args

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    ((line_number += 1))
    raw_line="${raw_line%$'\r'}"

    if [[ -z "$(trim "$raw_line")" || "$(trim "$raw_line")" == \#* ]]; then
      continue
    fi

    username=""
    password=""
    first_name=""
    last_name=""
    marker=""
    IFS=',' read -r username password first_name last_name marker \
      <<< "${raw_line},${CSV_SENTINEL}"

    username="$(trim "${username#$'\xEF\xBB\xBF'}")"
    first_name="$(trim "$first_name")"
    last_name="$(trim "$last_name")"
    header_key="$(printf '%s' "$username" | tr '[:upper:]' '[:lower:]')"

    if [[ "$header_key" == "email" || "$header_key" == "username" ]]; then
      continue
    fi

    ((total += 1))

    if [[ "$marker" != "$CSV_SENTINEL" ]]; then
      warn "Dòng ${line_number}: phải có đúng 4 trường, không dùng dấu phẩy bên trong trường."
      ((failed += 1))
      continue
    fi

    if ! valid_email "$username"; then
      warn "Dòng ${line_number}: email không hợp lệ."
      ((failed += 1))
      continue
    fi

    if [[ -z "$password" ]]; then
      warn "Dòng ${line_number} (${username}): mật khẩu đang trống."
      ((failed += 1))
      continue
    fi

    if has_control_character "$username" \
      || has_control_character "$password" \
      || has_control_character "$first_name" \
      || has_control_character "$last_name"; then
      warn "Dòng ${line_number} (${username}): chứa ký tự điều khiển không hợp lệ."
      ((failed += 1))
      continue
    fi

    account_output=""
    if account_output="$(run_zmprov ga "$username" zimbraId 2>&1)"; then
      printf '[SKIP] Dòng %d: tài khoản đã tồn tại: %s\n' "$line_number" "$username"
      ((skipped += 1))
      continue
    fi

    if [[ "$account_output" != *"account.NO_SUCH_ACCOUNT"* ]]; then
      warn "Dòng ${line_number} (${username}): không kiểm tra được tài khoản: $(compact_error "$account_output")"
      ((failed += 1))
      continue
    fi

    create_args=(ca "$username" "$password")
    if [[ -n "$first_name" ]]; then
      create_args+=(givenName "$first_name")
    fi
    if [[ -n "$last_name" ]]; then
      create_args+=(sn "$last_name")
    fi

    display_name="$(trim "${first_name} ${last_name}")"
    if [[ -n "$display_name" ]]; then
      create_args+=(displayName "$display_name")
    fi

    if (( DRY_RUN )); then
      printf '[DRY-RUN] Dòng %d: sẽ tạo %s' "$line_number" "$username"
      if [[ -n "$display_name" ]]; then
        printf ' - %s' "$display_name"
      fi
      printf '\n'
      ((planned += 1))
      continue
    fi

    if run_zmprov "${create_args[@]}" >/dev/null 2>&1; then
      printf '[OK] Dòng %d: đã tạo %s' "$line_number" "$username"
      if [[ -n "$display_name" ]]; then
        printf ' - %s' "$display_name"
      fi
      printf '\n'
      ((created += 1))
    else
      # Không in output của lệnh tạo để tránh nguy cơ lộ mật khẩu trong log lỗi.
      warn "Dòng ${line_number} (${username}): zmprov tạo tài khoản thất bại; kiểm tra domain, chính sách mật khẩu và log Zimbra."
      ((failed += 1))
    fi
  done < "$CSV_FILE"

  info "Kết quả import"
  printf '  Dữ liệu:       %d\n' "$total"
  printf '  Đã tạo:        %d\n' "$created"
  printf '  Sẽ tạo (dry):  %d\n' "$planned"
  printf '  Đã bỏ qua:     %d\n' "$skipped"
  printf '  Thất bại:      %d\n' "$failed"

  (( failed == 0 )) || return 1
}

main() {
  parse_arguments "$@"
  [[ -f "$CSV_FILE" ]] || die "Không tìm thấy file: ${CSV_FILE}"
  [[ -r "$CSV_FILE" ]] || die "Không có quyền đọc file: ${CSV_FILE}"

  check_csv_permissions
  prepare_zimbra

  if (( DRY_RUN )); then
    info "Đang kiểm tra CSV, không tạo tài khoản..."
  else
    info "Đang import tài khoản từ: ${CSV_FILE}"
  fi

  import_users
}

main "$@"
