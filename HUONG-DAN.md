# Hướng dẫn sử dụng các script

Kho script: [phongdh262/tools](https://github.com/phongdh262/tools), nhánh `Phondh`.

## Danh sách script

| Script | Chức năng | Chạy bằng |
|---|---|---|
| `install-zimbra.sh` | Cài tự động Zimbra 10.1.20 FOSS trên Ubuntu 22.04 | `root` |
| `zimbra-ssl.sh` | Cấp và tự động gia hạn SSL Let's Encrypt cho Zimbra | `root` |
| `zimbra-ssl-deploy.sh` | Kiểm tra/deploy certificate thương mại có sẵn vào Zimbra | `root` |
| `zimbra-import-users.sh` | Import tài khoản Zimbra từ CSV | `root` hoặc `zimbra` |
| `ssl-zero.sh` | Cấp ZeroSSL và deploy vào cPanel qua UAPI | User cPanel, không dùng `root` |
| `wordpress-core-update.sh` | Thay/cập nhật WordPress core an toàn | User sở hữu website hoặc `root` |

## Tải script

Thay `TEN-SCRIPT.sh` bằng tên file cần dùng:

```bash
wget --no-cache -O TEN-SCRIPT.sh \
  "https://raw.githubusercontent.com/phongdh262/tools/Phondh/TEN-SCRIPT.sh"
chmod +x TEN-SCRIPT.sh
```

Không dùng `source` hoặc `. script.sh`; hãy chạy script trực tiếp bằng Bash.

## 1. Cài Zimbra tự động

### Yêu cầu

- VPS mới, kiến trúc `x86_64`, chạy Ubuntu 22.04.
- Chạy bằng `root`.
- Tối thiểu khoảng 8 GB RAM và đủ dung lượng trống.
- FQDN mặc định là `mail.<domain>`.
- Không chạy trên máy đã có `/opt/zimbra` hoặc một Zimbra đang hoạt động.
- Nên cấu hình PTR/rDNS của IP VPS về FQDN mail tại nhà cung cấp VPS.

### Cài đặt cơ bản

```bash
wget --no-cache -O install-zimbra.sh \
  "https://raw.githubusercontent.com/phongdh262/tools/Phondh/install-zimbra.sh"
chmod +x install-zimbra.sh
sudo ./install-zimbra.sh --domain example.com
```

Script tự động:

- Phát hiện IPv4 công khai của VPS.
- Tạo mật khẩu admin mạnh.
- Đặt hostname `mail.example.com` và múi giờ `Asia/Ho_Chi_Minh`.
- Đồng bộ/kiểm tra đồng hồ hệ thống trước khi dùng APT.
- Tải và kiểm tra SHA-256 bộ cài Zimbra.
- Cài, cấu hình và hậu kiểm Zimbra.
- Tạo đúng tài khoản Spam, Ham và Virus Quarantine trên domain chính.
- Tạo DKIM và hiển thị bản ghi TXT cần cấu hình.
- Cấu hình UFW, bao gồm SSH, Admin `7071` và các cổng mail/web cần thiết.

Kết quả cuối hiển thị:

- URL, username và password đăng nhập Admin.
- Bản ghi DKIM.
- Các rule UFW thực tế đã allow.
- Trạng thái dịch vụ Zimbra.

Thông tin triển khai được lưu tại:

```text
/root/ZIMBRA-INSTALL-INFO.txt
```

Log đầy đủ:

```text
/root/zimbra-auto-install.log
```

Hai file trên chứa thông tin nhạy cảm và chỉ nên cho `root` đọc.

### Tùy chọn thường dùng

```bash
# Dùng hostname zimbra.example.com thay vì mail.example.com
sudo ./install-zimbra.sh --domain example.com --mail-host zimbra

# Chỉ định IP thay vì tự phát hiện
sudo ./install-zimbra.sh --domain example.com --ip 203.0.113.10

# Đọc mật khẩu admin từ file một dòng
chmod 600 /root/zimbra-admin-password
sudo ./install-zimbra.sh \
  --domain example.com \
  --password-file /root/zimbra-admin-password

# Không thay đổi UFW
sudo ./install-zimbra.sh --domain example.com --skip-firewall

# Xem toàn bộ tùy chọn
./install-zimbra.sh --help
```

Sau khi cài xong, đăng nhập Admin tại:

```text
https://mail.example.com:7071
```

## 2. Cài SSL Let's Encrypt tự động cho Zimbra

`zimbra-ssl.sh` dùng Certbot standalone, deploy certificate vào Zimbra và tạo lịch kiểm tra gia hạn lúc `03:17` và `15:17` mỗi ngày.

### Yêu cầu

- Zimbra đã cài và đang chạy.
- Bản ghi A của FQDN mail đã trỏ đúng IP VPS.
- Cổng TCP `80` truy cập được từ Internet và không bị cloud firewall chặn.
- Chạy bằng `root`.
- Zimbra sẽ tạm dừng trong lúc Certbot xác thực qua cổng 80.

### Chạy

```bash
wget --no-cache -O zimbra-ssl.sh \
  "https://raw.githubusercontent.com/phongdh262/tools/Phondh/zimbra-ssl.sh"
chmod +x zimbra-ssl.sh
sudo ./zimbra-ssl.sh mail.example.com admin@example.com
```

Có thể bỏ domain/email để script hỏi tương tác:

```bash
sudo ./zimbra-ssl.sh
```

Sau khi thành công, script được cài tại:

```text
/usr/local/sbin/zimbra-ssl
```

Các lệnh vận hành:

```bash
sudo /usr/local/sbin/zimbra-ssl --renew
sudo /usr/local/sbin/zimbra-ssl --stop
sudo /usr/local/sbin/zimbra-ssl --start
```

Cron tự động nằm tại `/etc/cron.d/zimbra-letsencrypt`.

## 3. Deploy certificate thương mại vào Zimbra

`zimbra-ssl-deploy.sh` không cấp certificate mới. Script chỉ kiểm tra và deploy bộ certificate/private key đã được CA cung cấp.

### Thứ tự file

```text
cert.crt       Certificate của mail server, chỉ chứa một certificate
ca_bundle.crt  Chuỗi CA, intermediate gần leaf nhất trước rồi đến root
private.key    Private key PEM không mã hóa
```

Nếu không truyền `private.key`, script dùng key hiện tại tại:

```text
/opt/zimbra/ssl/zimbra/commercial/commercial.key
```

### Kiểm tra trước khi deploy

```bash
sudo ./zimbra-ssl-deploy.sh \
  --verify-only \
  mail.example.com.crt \
  ca_bundle.crt \
  private.key
```

### Deploy và restart Zimbra

```bash
sudo ./zimbra-ssl-deploy.sh \
  mail.example.com.crt \
  ca_bundle.crt \
  private.key
```

Deploy nhưng chưa restart:

```bash
sudo ./zimbra-ssl-deploy.sh \
  --no-restart \
  mail.example.com.crt \
  ca_bundle.crt \
  private.key
```

Nên luôn chạy `--verify-only` trước. Không gửi hoặc commit private key lên Git.

## 4. Import user Zimbra từ CSV

### Định dạng CSV

```csv
email,password,firstname,lastname
user1@example.com,MatKhauManh01,Nguyen,Van A
user2@example.com,MatKhauManh02,Tran,Thi B
```

CSV phải có đúng bốn trường đơn giản và không hỗ trợ dấu phẩy nằm bên trong một trường. Tài khoản đã tồn tại sẽ được bỏ qua, không bị cập nhật.

Bảo vệ file vì CSV chứa mật khẩu:

```bash
chmod 600 users.csv
```

### Kiểm tra trước

```bash
sudo ./zimbra-import-users.sh --dry-run users.csv
```

### Import thật

```bash
sudo ./zimbra-import-users.sh users.csv
```

Hoặc chạy bằng user Zimbra:

```bash
sudo install -d -o zimbra -g zimbra -m 700 /opt/zimbra/import
sudo install -o zimbra -g zimbra -m 700 \
  zimbra-import-users.sh /opt/zimbra/import/
sudo install -o zimbra -g zimbra -m 600 \
  users.csv /opt/zimbra/import/
su - zimbra -c \
  '/opt/zimbra/import/zimbra-import-users.sh --dry-run /opt/zimbra/import/users.csv'
```

User `zimbra` phải có quyền đọc script và file CSV nếu dùng cách này.

## 5. Cài ZeroSSL cho cPanel

`ssl-zero.sh` phải chạy bằng đúng user sở hữu tài khoản cPanel, không chạy bằng `root`.

### Yêu cầu

- Máy chủ có cPanel UAPI.
- Domain đã trỏ về máy chủ.
- Webroot tồn tại và user cPanel có quyền đọc/ghi/truy cập.
- HTTP challenge truy cập được từ Internet.

### Chạy

```bash
bash ssl-zero.sh
```

Script sẽ hỏi:

1. Domain chính.
2. Domain `www` hoặc `-` nếu không dùng.
3. Đường dẫn webroot, ví dụ `~/public_html`.
4. Email đăng ký ZeroSSL.

Script tự cài `acme.sh` nếu thiếu, cấp certificate và deploy bằng hook `cpanel_uapi`. Sau khi thành công, `ssl-zero.sh` tự xóa chính nó.

## 6. Cập nhật WordPress core

Script chỉ thay WordPress core và không thay đổi:

- `wp-content`
- `wp-config.php`
- `.htaccess`
- Database
- File tùy chỉnh ngoài danh sách core chính thức

Vẫn nên backup file và database trước khi cập nhật.

### Chạy dry-run trước

```bash
./wordpress-core-update.sh \
  --path /var/www/example.com \
  --version latest \
  --dry-run
```

### Cập nhật thật

```bash
./wordpress-core-update.sh \
  --path /var/www/example.com \
  --version latest \
  --yes
```

Cài phiên bản cụ thể và giữ lại script sau khi thành công:

```bash
./wordpress-core-update.sh \
  --path /var/www/example.com \
  --version 7.1 \
  --yes \
  --keep-script
```

Nếu không có `--keep-script`, script tự xóa chính nó sau khi cập nhật thành công. Nên chạy bằng user sở hữu file WordPress để giữ đúng ownership.

## Kiểm tra nhanh

Xem hướng dẫn tích hợp trong các script hỗ trợ tham số:

```bash
./install-zimbra.sh --help
./wordpress-core-update.sh --help
./zimbra-import-users.sh --help
./zimbra-ssl-deploy.sh --help
./zimbra-ssl.sh --help
```

Kiểm tra cú pháp trước khi chạy:

```bash
bash -n TEN-SCRIPT.sh
```
