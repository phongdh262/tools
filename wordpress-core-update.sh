#!/usr/bin/env bash
#
# Thay thế/cập nhật WordPress core mà không đụng tới wp-content, wp-config.php,
# .htaccess, file tùy chỉnh hoặc database.

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '[wordpress-core-update] Không source script này. Hãy chạy trực tiếp.\n' >&2
  return 1
fi

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION_API="https://api.wordpress.org/core/version-check/1.7/"
readonly CHECKSUM_API="https://api.wordpress.org/core/checksums/1.0/"

SELF_PATH=""
WP_ROOT="."
REQUESTED_VERSION=""
BACKUP_BASE=""
DOWNLOAD_URL=""
TARGET_VERSION=""
CURRENT_VERSION="unknown"
TEMP_DIR=""
PACKAGE_ROOT=""
STAGE_DIR=""
OLD_CORE_DIR=""
BACKUP_ARCHIVE=""
MAINTENANCE_FILE=""
LOCK_DIR=""
LOCK_ACQUIRED=0
MAINTENANCE_CREATED=0
UPDATE_STARTED=0
DRY_RUN=0
ASSUME_YES=0
KEEP_SCRIPT=0

ROOT_FILES=()
ROOT_BACKUP_ITEMS=()
CREATED_ROOT_FILES=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly BLUE=$'\033[1;34m'
  readonly YELLOW=$'\033[1;33m'
  readonly RED=$'\033[1;31m'
  readonly GREEN=$'\033[1;32m'
  readonly RESET=$'\033[0m'
else
  readonly BLUE=""
  readonly YELLOW=""
  readonly RED=""
  readonly GREEN=""
  readonly RESET=""
fi

info() {
  printf '\n%s[wordpress-core-update]%s %s\n' "$BLUE" "$RESET" "$*"
}

success() {
  printf '\n%s[wordpress-core-update]%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
  printf '\n%s[wordpress-core-update] CẢNH BÁO:%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
  printf '\n%s[wordpress-core-update] LỖI:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  ./${SCRIPT_NAME} [options]

Options:
  --path DIR          Thư mục gốc WordPress. Mặc định: thư mục hiện tại.
  --version VERSION   Phiên bản cần cài, hoặc "latest". Nếu bỏ qua sẽ hỏi.
  --backup-dir DIR    Nơi lưu backup core. Mặc định nằm ngoài web root.
  --dry-run           Tải và kiểm tra package, không thay đổi website.
  --keep-script       Không tự xóa script sau khi cập nhật thành công.
  -y, --yes           Không hỏi xác nhận trước khi cập nhật.
  -h, --help          Hiển thị hướng dẫn.

Ví dụ:
  ./${SCRIPT_NAME} --path /var/www/example.com --version latest --dry-run
  sudo ./${SCRIPT_NAME} --path /var/www/example.com --version 7.1
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Không tìm thấy lệnh bắt buộc: $1"
}

require_commands() {
  local command_name
  for command_name in awk chmod chown cksum cp curl date dirname find install mkdir mktemp mv php rm rmdir sort stat tar unzip; do
    require_command "$command_name"
  done
}

parse_options() {
  while (( $# > 0 )); do
    case "$1" in
      --path)
        (( $# >= 2 )) || die "--path cần một thư mục."
        WP_ROOT="$2"
        shift 2
        ;;
      --version)
        (( $# >= 2 )) || die "--version cần một giá trị."
        REQUESTED_VERSION="$2"
        shift 2
        ;;
      --backup-dir)
        (( $# >= 2 )) || die "--backup-dir cần một thư mục."
        BACKUP_BASE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --keep-script)
        KEEP_SCRIPT=1
        shift
        ;;
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        (( $# == 0 )) || die "Script không nhận positional argument."
        ;;
      -*)
        die "Tùy chọn không hợp lệ: $1"
        ;;
      *)
        die "Tham số không hợp lệ: $1"
        ;;
    esac
  done
}

resolve_directory() {
  local directory="$1"
  [[ -d "$directory" ]] || die "Không tìm thấy thư mục: ${directory}"
  (cd -- "$directory" && pwd -P)
}

resolve_self_path() {
  local source_path="${BASH_SOURCE[0]}"

  if [[ "$source_path" != /* ]]; then
    source_path="$(pwd -P)/${source_path}"
  fi
  if [[ -f "$source_path" || -L "$source_path" ]]; then
    SELF_PATH="$(cd -- "$(dirname -- "$source_path")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$source_path")")"
  fi
}

validate_wordpress_root() {
  WP_ROOT="$(resolve_directory "$WP_ROOT")"

  [[ -f "${WP_ROOT}/wp-load.php" ]] \
    || die "Không tìm thấy wp-load.php tại: ${WP_ROOT}"
  [[ -f "${WP_ROOT}/wp-includes/version.php" ]] \
    || die "Không tìm thấy wp-includes/version.php."
  [[ -d "${WP_ROOT}/wp-admin" && ! -L "${WP_ROOT}/wp-admin" ]] \
    || die "wp-admin phải là thư mục thật, không phải symlink."
  [[ -d "${WP_ROOT}/wp-includes" && ! -L "${WP_ROOT}/wp-includes" ]] \
    || die "wp-includes phải là thư mục thật, không phải symlink."
  [[ -d "${WP_ROOT}/wp-content" ]] \
    || die "Không tìm thấy wp-content; dừng để tránh cập nhật nhầm thư mục."
  [[ -w "$WP_ROOT" ]] \
    || die "Không có quyền ghi vào ${WP_ROOT}. Hãy dùng đúng user hoặc sudo."

  CURRENT_VERSION="$(
    awk -F"'" '/^[[:space:]]*\$wp_version[[:space:]]*=/ { print $2; exit }' \
      "${WP_ROOT}/wp-includes/version.php"
  )"
  [[ -n "$CURRENT_VERSION" ]] || CURRENT_VERSION="unknown"

  MAINTENANCE_FILE="${WP_ROOT}/.maintenance"
  LOCK_DIR="${TMPDIR:-/tmp}/wordpress-core-update.$(printf '%s' "$WP_ROOT" | cksum | awk '{ print $1 }').lock"
  [[ ! -e "$MAINTENANCE_FILE" ]] \
    || die "Đang tồn tại ${MAINTENANCE_FILE}. Kiểm tra một tiến trình cập nhật khác trước."
}

acquire_lock() {
  if mkdir -- "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
  else
    die "Một tiến trình cập nhật khác đang chạy hoặc còn lock cũ: ${LOCK_DIR}"
  fi
}

make_temp_dir() {
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wordpress-core-update.XXXXXX")"
  chmod 700 "$TEMP_DIR"
}

fetch_version_data() {
  info "Đang lấy danh sách phiên bản từ WordPress.org..."
  curl --fail --silent --show-error --location \
    --retry 3 --connect-timeout 15 --max-time 60 \
    "$VERSION_API" -o "${TEMP_DIR}/versions.json"

  php -r '
    $data = json_decode(file_get_contents($argv[1]), true);
    if (!is_array($data) || !isset($data["offers"])) { exit(2); }
    $seen = [];
    foreach ($data["offers"] as $offer) {
      $version = $offer["version"] ?? "";
      if ($version !== "" && !isset($seen[$version])) {
        echo $version, PHP_EOL;
        $seen[$version] = true;
      }
    }
  ' "${TEMP_DIR}/versions.json" > "${TEMP_DIR}/versions.txt" \
    || die "Phản hồi version API không hợp lệ."

  [[ -s "${TEMP_DIR}/versions.txt" ]] \
    || die "WordPress version API không trả về phiên bản nào."
}

show_available_versions() {
  printf '\n10 phiên bản WordPress mới nhất API đang cung cấp:\n'
  sort -Vr "${TEMP_DIR}/versions.txt" | awk '!seen[$0]++ { print "  - " $0; if (++count == 10) exit }'
}

choose_version() {
  local answer latest_version

  latest_version="$(
    awk '/^[0-9]+\.[0-9]+([.][0-9]+)?$/ { print }' "${TEMP_DIR}/versions.txt" \
      | sort -Vr \
      | awk 'NF { print; exit }'
  )"
  [[ -n "$latest_version" ]] || die "Version API không trả về phiên bản stable nào."

  if [[ -z "$REQUESTED_VERSION" ]]; then
    show_available_versions
    if [[ -t 0 ]]; then
      read -r -p "Phiên bản cần cài [latest = ${latest_version}]: " answer
      REQUESTED_VERSION="${answer:-latest}"
    else
      REQUESTED_VERSION="latest"
    fi
  fi

  if [[ "$REQUESTED_VERSION" == "latest" ]]; then
    TARGET_VERSION="$latest_version"
  else
    TARGET_VERSION="$REQUESTED_VERSION"
  fi

  [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?([_-]?(alpha|beta|RC)[0-9]*)?$ ]] \
    || die "Phiên bản không hợp lệ: ${TARGET_VERSION}"
}

warn_if_downgrade() {
  local oldest

  [[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]] || return 0
  [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]] || return 0
  [[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]] || return 0

  oldest="$(printf '%s\n%s\n' "$CURRENT_VERSION" "$TARGET_VERSION" | sort -V | awk 'NR == 1 { print; exit }')"
  if [[ "$oldest" == "$TARGET_VERSION" ]]; then
    warn "Bạn đang downgrade WordPress từ ${CURRENT_VERSION} xuống ${TARGET_VERSION}. Hãy chắc chắn plugin/theme và database tương thích với phiên bản cũ."
  fi
}

url_exists() {
  curl --fail --silent --show-error --location --head \
    --retry 2 --connect-timeout 15 --max-time 45 "$1" >/dev/null
}

select_download_url() {
  local no_content_url full_url
  no_content_url="https://downloads.wordpress.org/release/wordpress-${TARGET_VERSION}-no-content.zip"
  full_url="https://downloads.wordpress.org/release/wordpress-${TARGET_VERSION}.zip"

  if url_exists "$no_content_url"; then
    DOWNLOAD_URL="$no_content_url"
  elif url_exists "$full_url"; then
    DOWNLOAD_URL="$full_url"
    warn "Không có package no-content; dùng package đầy đủ làm nguồn nhưng vẫn loại trừ wp-content khi cài."
  else
    die "Không tìm thấy package WordPress ${TARGET_VERSION} trên WordPress.org."
  fi
}

download_package() {
  info "Đang tải WordPress ${TARGET_VERSION}: ${DOWNLOAD_URL}"
  curl --fail --silent --show-error --location \
    --retry 3 --connect-timeout 15 --max-time 600 \
    "$DOWNLOAD_URL" -o "${TEMP_DIR}/wordpress.zip"
  [[ -s "${TEMP_DIR}/wordpress.zip" ]] || die "Package tải về bị rỗng."
}

validate_zip_entries() {
  if ! unzip -Z1 "${TEMP_DIR}/wordpress.zip" \
    | awk '
        index($0, "\\") || $0 !~ /^wordpress\// || $0 ~ /(^|\/)\.\.($|\/)/ { bad=1 }
        END { exit bad }
      '; then
    die "Package chứa đường dẫn không an toàn hoặc không đúng cấu trúc WordPress."
  fi
}

extract_and_validate_package() {
  validate_zip_entries
  unzip -q "${TEMP_DIR}/wordpress.zip" -d "${TEMP_DIR}/extracted"
  PACKAGE_ROOT="${TEMP_DIR}/extracted/wordpress"

  [[ -d "${PACKAGE_ROOT}/wp-admin" ]] || die "Package thiếu wp-admin."
  [[ -d "${PACKAGE_ROOT}/wp-includes" ]] || die "Package thiếu wp-includes."
  [[ -f "${PACKAGE_ROOT}/wp-load.php" ]] || die "Package thiếu wp-load.php."
  [[ -f "${PACKAGE_ROOT}/wp-includes/version.php" ]] \
    || die "Package thiếu wp-includes/version.php."

  local packaged_version
  packaged_version="$(
    awk -F"'" '/^[[:space:]]*\$wp_version[[:space:]]*=/ { print $2; exit }' \
      "${PACKAGE_ROOT}/wp-includes/version.php"
  )"
  [[ "$packaged_version" == "$TARGET_VERSION" ]] \
    || die "Version trong package (${packaged_version:-unknown}) khác version yêu cầu (${TARGET_VERSION})."
}

verify_official_checksums() {
  local checksum_url
  checksum_url="${CHECKSUM_API}?version=${TARGET_VERSION}&locale=en_US"

  info "Đang xác minh checksum các file core..."
  if ! curl --fail --silent --show-error --location \
    --retry 2 --connect-timeout 15 --max-time 60 \
    "$checksum_url" -o "${TEMP_DIR}/checksums.json"; then
    warn "Không lấy được checksum API; package vẫn được kiểm tra cấu trúc và tải qua HTTPS."
    return 0
  fi

  if ! php -r '
    $data = json_decode(file_get_contents($argv[1]), true);
    $root = rtrim($argv[2], DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR;
    if (!is_array($data) || empty($data["checksums"])) { exit(2); }
    foreach ($data["checksums"] as $path => $expected) {
      if (strpos($path, "wp-content/") === 0) { continue; }
      $file = $root . $path;
      if (!is_file($file) || !hash_equals(strtolower($expected), md5_file($file))) {
        fwrite(STDERR, "Checksum sai hoặc thiếu file: {$path}\n");
        exit(3);
      }
    }
  ' "${TEMP_DIR}/checksums.json" "$PACKAGE_ROOT"; then
    die "Package không vượt qua kiểm tra checksum chính thức."
  fi
}

collect_root_files() {
  local source_file base_name manifest
  manifest="${TEMP_DIR}/root-files.list"

  # Một số shared hosting không mount /dev/fd, nên không dùng process
  # substitution (`< <(...)`) tại đây.
  find "$PACKAGE_ROOT" -maxdepth 1 -type f -print > "$manifest"

  while IFS= read -r source_file; do
    [[ -n "$source_file" ]] || continue
    base_name="${source_file##*/}"
    case "$base_name" in
      wp-config.php|.htaccess)
        continue
        ;;
    esac
    ROOT_FILES+=("$base_name")
  done < "$manifest"

  (( ${#ROOT_FILES[@]} > 0 )) || die "Không tìm thấy file core ở thư mục gốc package."
}

prepare_backup() {
  local item timestamp site_name

  if [[ -z "$BACKUP_BASE" ]]; then
    BACKUP_BASE="$(dirname -- "$WP_ROOT")/.wordpress-core-backups"
  fi

  install -d -m 700 "$BACKUP_BASE"
  BACKUP_BASE="$(resolve_directory "$BACKUP_BASE")"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  site_name="${WP_ROOT##*/}"
  BACKUP_ARCHIVE="${BACKUP_BASE}/${site_name}-core-${CURRENT_VERSION}-${timestamp}.tar.gz"

  ROOT_BACKUP_ITEMS=("wp-admin" "wp-includes")
  for item in "${ROOT_FILES[@]}"; do
    if [[ -e "${WP_ROOT}/${item}" || -L "${WP_ROOT}/${item}" ]]; then
      ROOT_BACKUP_ITEMS+=("$item")
    else
      CREATED_ROOT_FILES+=("$item")
    fi
  done

  info "Đang backup WordPress core hiện tại..."
  tar -czf "$BACKUP_ARCHIVE" -C "$WP_ROOT" -- "${ROOT_BACKUP_ITEMS[@]}"
  chmod 600 "$BACKUP_ARCHIVE"
  success "Đã tạo backup: ${BACKUP_ARCHIVE}"
}

normalize_new_core_permissions() {
  local owner_uid owner_gid
  owner_uid="$(file_owner_uid "${WP_ROOT}/wp-load.php")"
  owner_gid="$(file_owner_gid "${WP_ROOT}/wp-load.php")"

  find "$STAGE_DIR" -type d -exec chmod 755 {} +
  find "$STAGE_DIR" -type f -exec chmod 644 {} +

  if (( EUID == 0 )); then
    chown -R "${owner_uid}:${owner_gid}" "$STAGE_DIR"
  fi
}

stage_new_core() {
  STAGE_DIR="$(mktemp -d "${WP_ROOT}/.wordpress-core-stage.XXXXXX")"
  OLD_CORE_DIR="$(mktemp -d "${WP_ROOT}/.wordpress-core-old.XXXXXX")"

  cp -a -- "${PACKAGE_ROOT}/wp-admin" "${STAGE_DIR}/wp-admin"
  cp -a -- "${PACKAGE_ROOT}/wp-includes" "${STAGE_DIR}/wp-includes"
  normalize_new_core_permissions
}

create_maintenance_file() {
  printf '<?php $upgrading = %s; ?>\n' "$(date +%s)" > "$MAINTENANCE_FILE"
  MAINTENANCE_CREATED=1
  chmod 644 "$MAINTENANCE_FILE"
}

file_owner_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"
}

file_owner_gid() {
  stat -c '%g' "$1" 2>/dev/null || stat -f '%g' "$1"
}

install_root_files() {
  local base_name source_file target_file temporary_file
  local owner_uid owner_gid
  owner_uid="$(file_owner_uid "${WP_ROOT}/wp-load.php")"
  owner_gid="$(file_owner_gid "${WP_ROOT}/wp-load.php")"

  for base_name in "${ROOT_FILES[@]}"; do
    source_file="${PACKAGE_ROOT}/${base_name}"
    target_file="${WP_ROOT}/${base_name}"
    temporary_file="${WP_ROOT}/.${base_name}.wordpress-new.$$"

    install -m 644 "$source_file" "$temporary_file"
    if (( EUID == 0 )); then
      chown "${owner_uid}:${owner_gid}" "$temporary_file"
    fi
    mv -f -- "$temporary_file" "$target_file"
  done
}

swap_core_directories() {
  mv -- "${WP_ROOT}/wp-admin" "${OLD_CORE_DIR}/wp-admin"
  mv -- "${WP_ROOT}/wp-includes" "${OLD_CORE_DIR}/wp-includes"
  mv -- "${STAGE_DIR}/wp-admin" "${WP_ROOT}/wp-admin"
  mv -- "${STAGE_DIR}/wp-includes" "${WP_ROOT}/wp-includes"
}

rollback_update() {
  local item
  set +e
  warn "Có lỗi trong lúc thay core; đang tự động khôi phục phiên bản cũ..."

  if [[ -d "${OLD_CORE_DIR}/wp-admin" ]]; then
    [[ -e "${WP_ROOT}/wp-admin" ]] && mv -- "${WP_ROOT}/wp-admin" "${STAGE_DIR}/failed-wp-admin"
    mv -- "${OLD_CORE_DIR}/wp-admin" "${WP_ROOT}/wp-admin"
  fi
  if [[ -d "${OLD_CORE_DIR}/wp-includes" ]]; then
    [[ -e "${WP_ROOT}/wp-includes" ]] && mv -- "${WP_ROOT}/wp-includes" "${STAGE_DIR}/failed-wp-includes"
    mv -- "${OLD_CORE_DIR}/wp-includes" "${WP_ROOT}/wp-includes"
  fi

  if [[ -s "$BACKUP_ARCHIVE" ]] && (( ${#ROOT_BACKUP_ITEMS[@]} > 2 )); then
    tar -xzf "$BACKUP_ARCHIVE" -C "$WP_ROOT" -- "${ROOT_BACKUP_ITEMS[@]:2}"
  fi
  for item in "${CREATED_ROOT_FILES[@]}"; do
    rm -f -- "${WP_ROOT}/${item}"
  done

  warn "Đã thử khôi phục core cũ. Backup vẫn còn tại: ${BACKUP_ARCHIVE}"
}

safe_remove_work_dir() {
  local directory="$1"
  case "$directory" in
    "${WP_ROOT}"/.wordpress-core-stage.*|"${WP_ROOT}"/.wordpress-core-old.*)
      rm -rf -- "$directory"
      ;;
  esac
}

cleanup() {
  local exit_code="$?"
  trap - EXIT INT TERM

  if (( exit_code != 0 && UPDATE_STARTED == 1 )); then
    rollback_update
  fi

  if (( MAINTENANCE_CREATED == 1 )); then
    rm -f -- "$MAINTENANCE_FILE"
  fi

  [[ -z "$STAGE_DIR" ]] || safe_remove_work_dir "$STAGE_DIR"
  [[ -z "$OLD_CORE_DIR" ]] || safe_remove_work_dir "$OLD_CORE_DIR"

  case "$TEMP_DIR" in
    "${TMPDIR:-/tmp}"/wordpress-core-update.*)
      rm -rf -- "$TEMP_DIR"
      ;;
  esac

  if (( LOCK_ACQUIRED == 1 )); then
    rmdir -- "$LOCK_DIR" 2>/dev/null || true
  fi

  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

confirm_update() {
  local answer
  info "Website: ${WP_ROOT}"
  printf 'Phiên bản hiện tại: %s\n' "$CURRENT_VERSION"
  printf 'Phiên bản sẽ cài: %s\n' "$TARGET_VERSION"
  printf 'Không thay đổi: wp-content, wp-config.php, .htaccess, database và file tùy chỉnh.\n'

  if (( DRY_RUN == 1 || ASSUME_YES == 1 )); then
    return 0
  fi
  [[ -t 0 ]] || die "Chế độ non-interactive cần --yes hoặc --dry-run."

  read -r -p "Tiếp tục thay WordPress core? [y/N]: " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Đã hủy theo yêu cầu."
}

perform_update() {
  prepare_backup
  stage_new_core
  create_maintenance_file
  UPDATE_STARTED=1

  swap_core_directories
  install_root_files

  UPDATE_STARTED=0
  rm -f -- "$MAINTENANCE_FILE"
  MAINTENANCE_CREATED=0

  safe_remove_work_dir "$OLD_CORE_DIR"
  OLD_CORE_DIR=""
  safe_remove_work_dir "$STAGE_DIR"
  STAGE_DIR=""
}

delete_self_after_success() {
  (( KEEP_SCRIPT == 0 )) || return 0

  if [[ -n "$SELF_PATH" && ( -f "$SELF_PATH" || -L "$SELF_PATH" ) ]]; then
    if rm -f -- "$SELF_PATH"; then
      success "Đã tự xóa script sau khi cập nhật thành công: ${SELF_PATH}"
    else
      warn "Cập nhật đã thành công nhưng không thể tự xóa script: ${SELF_PATH}"
    fi
  else
    warn "Cập nhật đã thành công nhưng không xác định được file script để tự xóa."
  fi
}

main() {
  resolve_self_path
  parse_options "$@"
  require_commands
  validate_wordpress_root
  acquire_lock
  make_temp_dir
  fetch_version_data
  choose_version
  warn_if_downgrade
  select_download_url
  download_package
  extract_and_validate_package
  verify_official_checksums
  collect_root_files
  confirm_update

  if (( DRY_RUN == 1 )); then
    success "Dry-run thành công. Package hợp lệ; website chưa bị thay đổi."
    exit 0
  fi

  perform_update
  success "Đã cập nhật WordPress core từ ${CURRENT_VERSION} lên ${TARGET_VERSION}."
  info "wp-content, wp-config.php, .htaccess, database và file tùy chỉnh không bị thay đổi."
  info "Backup core cũ: ${BACKUP_ARCHIVE}"
  warn "Nếu WordPress yêu cầu nâng cấp database, hãy backup database trước khi thực hiện trong wp-admin."
  delete_self_after_success
}

main "$@"
