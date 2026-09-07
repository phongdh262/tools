#!/bin/bash
# Usage: ./import_user.sh user.csv
# CSV format: email,displayName,password
# Example:
# admin@soitheky.vn,Quản trị hệ thống,pass-word
# user1@soitheky.vn,Nguyễn Văn A,123456

file="$1"

# Kiểm tra file tồn tại
if [ ! -f "$file" ]; then
    echo "Error: File $file not found!"
    exit 1
fi

# Đọc CSV
while IFS=',' read -r Username DisplayName Password; do

    # Xóa ký tự CR cuối dòng
    Username=$(printf '%s' "$Username" | tr -d '\r')
    DisplayName=$(printf '%s' "$DisplayName" | tr -d '\r')
    Password=$(printf '%s' "$Password" | tr -d '\r')

    # Bỏ qua dòng trống hoặc header
    if [ -z "$Username" ] || [ "$Username" = "email" ] || [ "$Username" = "username" ]; then
        continue
    fi

    echo "----------------------------------------"
    echo "Processing: $Username"

    # Tạo account
    if zmprov ca "$Username" "$Password" displayName "$DisplayName"; then
        echo "OK: Created $Username - Display Name: $DisplayName"
    else
        echo "ERROR: Failed to create $Username"
    fi

done < "$file"

echo "----------------------------------------"
echo "Import completed!"