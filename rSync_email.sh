#!/bin/bash

pwdd=`pwd`
cat << "EOF"

 █████╗ ███████╗██████╗ ██╗ ██████╗ ██╗
██╔══██╗╚══███╔╝██╔══██╗██║██╔════╝ ██║
███████║  ███╔╝ ██║  ██║██║██║  ███╗██║
██╔══██║ ███╔╝  ██║  ██║██║██║   ██║██║
██║  ██║███████╗██████╔╝██║╚██████╔╝██║
╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝ ╚═════╝ ╚═╝

EOF

# Hàm để đọc file CSV và trả về danh sách người dùng và mật khẩu
read_credentials() {
    local file_path="$1"
    while IFS=';,' read -r user1 pass1 user2 pass2; do
        echo "$user1,$pass1,$user2,$pass2"
    done < "$file_path"
}

# Hàm để thực hiện đồng bộ email
sync_emails() {
    local source="$1"
    local dest="$2"
    local credentials_file="$3"
    local log_file="error_log.txt"

    # Xóa file log cũ nếu có
    [ -e "$log_file" ] && rm "$log_file"

    # Đọc từng dòng từ file credentials và thực hiện đồng bộ
    while IFS=';,' read -r user1 pass1 user2 pass2; do
        echo "$user1,$pass1,$user2,$pass2"
    done < "$file_path"
}

# Hàm để thực hiện đồng bộ email
sync_emails() {
    local source="$1"
    local dest="$2"
    local credentials_file="$3"
    local log_file="error_log.txt"

    # Xóa file log cũ nếu có
    [ -e "$log_file" ] && rm "$log_file"

    # Đọc từng dòng từ file credentials và thực hiện đồng bộ
    while IFS=, read -r user1 pass1 user2 pass2; do
        echo "Syncing $user1 to $user2..."

        # Thực hiện lệnh imapsync
        imapsync --host1 "$source" --user1 "$user1" --password1 "$pass1" --ssl1 \
                 --host2 "$dest" --user2 "$user2" --password2 "$pass2" --ssl2
        if [ $? -ne 0 ]; then
            echo "Error syncing $user1 to $user2" >> "$log_file"
        else
            echo "Successfully synced $user1 to $user2"
        fi
    done < <(read_credentials "$credentials_file")
}

# Main script
read -p "Nhập hostname or IP máy chủ nguồn: " source
#read -p "Nhập hostname máy chủ đích (h01 for h01.azdigimail.com, h02 for h02.azdigimail.com): " dest
# Loop để yêu cầu người dùng nhập lại nếu giá trị không hợp lệ
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
            echo "Máy chủ đích không hợp lệ. Vui lòng nhập 'h01' hoặc 'h02."
            ;;
    esac
done

read -p "Nhập đường dẫn file.csv or tên file.csv: " credentials_file

sync_emails "$source" "$dest" "$credentials_file"
