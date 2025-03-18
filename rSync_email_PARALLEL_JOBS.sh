
#!/bin/bash

# Cấu hình số lượng job song song
PARALLEL_JOBS=7

# Định nghĩa file log chung
LOG_FILE="sync_log.txt"
> "$LOG_FILE"  # Xóa nội dung cũ khi chạy script mới

# Hàm để đọc file CSV và trả về danh sách người dùng và mật khẩu
read_credentials() {
    local file_path="$1"
    while IFS=',' read -r user1 pass1 user2 pass2; do
        user1=$(echo "$user1" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/"//g')
        pass1=$(echo "$pass1" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/"//g')
        user2=$(echo "$user2" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/"//g')
        pass2=$(echo "$pass2" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/"//g')

        echo "$user1,$pass1,$user2,$pass2"
    done < "$file_path"
}

# Hàm để thực hiện đồng bộ email
sync_email() {
    local source="$1"
    local dest="$2"
    local user1="$3"
    local pass1="$4"
    local user2="$5"
    local pass2="$6"

    echo "Syncing $user1 to $user2..." | tee -a "$LOG_FILE"
    echo "Debug: user1=$user1, pass1=$pass1, user2=$user2, pass2=$pass2" | tee -a "$LOG_FILE"

    eval imapsync --host1 "$source" --user1 "$user1" --password1 "$pass1" --ssl1 \
                  --host2 "$dest" --user2 "$user2" --password2 "$pass2" --ssl2 2>> "$LOG_FILE"
    if [ $? -eq 0 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Successfully synced $user1 to $user2" | tee -a "$LOG_FILE"
    else
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Error syncing $user1 to $user2" | tee -a "$LOG_FILE"
    fi
}

# Hàm chạy đồng bộ song song nếu có parallel
sync_emails() {
    local source="$1"
    local dest="$2"
    local credentials_file="$3"

    if command -v parallel > /dev/null; then
        export -f sync_email
        export source dest LOG_FILE
        echo "Chạy đồng bộ song song với $PARALLEL_JOBS jobs..." | tee -a "$LOG_FILE"
        read_credentials "$credentials_file" | parallel -j "$PARALLEL_JOBS" --colsep ',' sync_email "$source" "$dest" {1} {2} {3} {4}
    else
        echo "parallel không được tìm thấy, chạy tuần tự." | tee -a "$LOG_FILE"
        while IFS=',' read -r user1 pass1 user2 pass2; do
            sync_email "$source" "$dest" "$user1" "$pass1" "$user2" "$pass2"
        done < <(read_credentials "$credentials_file")
    fi
    echo "Tất cả tiến trình đã hoàn thành." | tee -a "$LOG_FILE"
}

# Main script
echo "Sử dụng máy chủ email của Google: imap.gmail.com"
read -p "Nhập hostname or IP máy chủ nguồn: " source
if [ "$source" == "imap" ]; then
    source="imap.gmail.com"
    echo "Sử dụng máy chủ email của Google: $source"
fi

while true; do
    read -p "Nhập hostname máy chủ đích (h01 for h01.azdigimail.com, h02 for h02.azdigimail.com): " dest
    case "$dest" in
        h01)
            dest="45.252.250.12"
            break
            ;;
        h02)
            dest="45.252.250.31"
            break
            ;;
        *)
            echo "Máy chủ đích không hợp lệ. Vui lòng nhập 'h01' hoặc 'h02'."
            ;;
    esac
done

read -p "Nhập đường dẫn file.csv hoặc tên file.csv: " credentials_file

sync_emails "$source" "$dest" "$credentials_file"
