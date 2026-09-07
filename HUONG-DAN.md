# Hướng dẫn sử dụng các script

Kho script: [phongdh262/tools](https://github.com/phongdh262/tools), nhánh `main` (script cài Zimbra tự nhận diện OS).

## Danh sách script

| Script | Chức năng | Chạy bằng |
|---|---|---|
| `install-zimbra10.sh` | Cài tự động Zimbra 10 FOSS trên Ubuntu 22.04 / 24.04 (Auto OS + CSF Firewall) | `root` |
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

## 1. Cài Zimbra tự động trên Ubuntu 22.04 / 24.04

Dùng `install-zimbra10.sh` cho cài mới. Script tự nhận diện Ubuntu, chọn đúng archive Zimbra **10.1.20** và xác minh SHA-256 trước khi giải nén.

| Ubuntu | Build | Release |
|---|---|---|
| 22.04 x86_64 | `0326.UBUNTU22_64.20260821115118` | `zimbra-10.1.20` |
| 24.04 x86_64 | `0326.UBUNTU24_64.20260821120929` | `zimbra-10.1.20-u24` |

### Yêu cầu

- VPS mới, dành riêng cho Zimbra, có systemd và quyền root.
- Tối thiểu khoảng 8 GB RAM, 20 GB trống; cần thêm dung lượng cho mailbox và backup thực tế.
- Kết nối tới Ubuntu APT, Zimbra repository và GitHub Releases.
- Không có một Zimbra đang hoạt động trong `/opt/zimbra`; script không nâng cấp hoặc xóa dữ liệu mail đang có.
- Nếu có Nginx/Apache/Postfix/Exim đang chạy, script dừng để tránh làm hỏng dịch vụ khác.

### Cài đặt cơ bản

```bash
wget --no-cache -O install-zimbra10.sh \
  "https://raw.githubusercontent.com/phongdh262/tools/main/install-zimbra10.sh"
chmod +x install-zimbra10.sh
sudo ./install-zimbra10.sh --domain example.com
```

Đặt file `csf.conf` có sẵn cạnh `install-zimbra10.sh`. Sau khi cài CSF, script kiểm tra rồi dùng toàn bộ file này thay thế `/etc/csf/csf.conf`. Có thể chọn một file ở đường dẫn khác bằng `--csf-conf /duong-dan/csf.conf`. Nếu không có file cục bộ, script tải bản mẫu đã cố định theo commit và SHA-256 từ repository.

Archive lớn được lưu trong **GitHub Releases**, còn checksum được lưu cả trong git và release. Kiểm tra bộ Ubuntu 24.04 tải thủ công:

```bash
sha256sum -c zcs-10.1.20_GA_0326.UBUNTU24_64.20260821120929.tgz.sha256
```

### Quyền truy cập firewall

Script cài CSF **15.10** từ Aetherinox khi máy chưa có CSF, xác minh SHA-256 và kiểm tra tương thích trước khi chuyển từ UFW. Nếu CSF đã có sẵn, script giữ bản cài hiện tại; quản trị viên vẫn cần theo dõi bản vá của CSF đang sử dụng. Tự cập nhật CSF qua mạng được tắt trong mẫu để tránh thay đổi phiên bản ngoài kiểm soát.

- Mở công khai TCP `25,80,443,465,587,993,995,7071` và các cổng SSH phát hiện được.
- Cả SSH và trang Admin `7071` đều mở tự do theo mặc định (không giới hạn theo IP của kỹ thuật viên khi cài đặt), giúp khách hàng truy cập trang quản trị bình thường từ bất kỳ mạng nào. LFD (`zimbra-auth.pm`) tự động theo dõi và khóa IP tạm thời nếu có hành vi brute force mật khẩu trên cổng 7071.
- Nếu muốn giới hạn riêng cổng 7071 cho một IP quản trị cố định, có thể tùy chọn truyền `--admin-ip IP` (hoặc `--admin-cidr CIDR`).
- Không mở công khai backend `8443`, FTP, DNS hay cổng giám sát trong danh sách cổng mặc định.
- Giữ lại các rule `csf.allow` và `csf.deny` hiện có ngoài rule quản trị 7071 do script cập nhật.
- IPv6 được cấu hình tương ứng khi IPv6 đang bật trên máy.
- Cấu hình và rules cũ được sao lưu tại `/root/zimbra-firewall-backup.*`. Khi lỗi, script khôi phục; watchdog độc lập cũng thực hiện khôi phục nếu giao dịch không hoàn tất trong 10 phút. Các kiểm tra tự động xác minh rules và DNS, không thay thế kiểm tra SSH từ máy bên ngoài.

Ví dụ chỉ định file cấu hình CSF đã upload hoặc giới hạn IP quản trị tùy chọn:

```bash
# Cài đặt thông thường (cổng 7071 mở cho khách hàng truy cập)
sudo ./install-zimbra10.sh --domain example.com --csf-conf /root/csf.conf

# Tùy chọn nếu muốn giới hạn riêng cổng 7071 cho IP cố định của khách hàng
sudo ./install-zimbra10.sh --domain example.com --admin-ip 203.0.113.25 --csf-conf /root/csf.conf
```

### VPS có NAT và DNS

```bash
sudo ./install-zimbra10.sh \
  --domain example.com \
  --ip 203.0.113.10 \
  --local-ip 10.0.0.10
```

`--ip` là IP công khai; `--local-ip` phải có trên interface của VPS và được dùng cho hostname/DNS nội bộ. Nếu không truyền, script tự phát hiện từng địa chỉ.

DNS nội bộ chỉ khai báo hostname mail và MX cục bộ, tiếp tục phân giải SPF/DKIM/DMARC và các tên miền con từ DNS công khai. Bạn vẫn phải tạo A/MX/SPF/DKIM/DMARC tại DNS provider, đặt PTR/rDNS tại nhà cung cấp VPS và cấu hình port forwarding/cloud firewall nếu có NAT. Bộ cài hiển thị bản ghi DKIM sau khi hoàn thành.

Resolver được kiểm tra trước APT, sao lưu trước khi thay đổi, kiểm tra cấu hình dnsmasq trước khi chuyển, và khôi phục nếu chuyển resolver thất bại. Bản sao nằm tại `/root/zimbra-resolver-backup.*`.

### Các tùy chọn khác

```bash
# Mật khẩu tự sinh nếu không truyền file; tránh truyền mật khẩu qua command line.
chmod 600 /root/zimbra-admin-password
sudo ./install-zimbra10.sh --domain example.com \
  --password-file /root/zimbra-admin-password

# Chỉ sửa firewall trên máy đã cài Zimbra; không đổi hostname/múi giờ.
sudo ./install-zimbra10.sh --only-firewall --admin-ip 203.0.113.25 --csf-conf /root/csf.conf

# Không cấu hình CSF
sudo ./install-zimbra10.sh --domain example.com --skip-firewall

# Archive tùy chọn phải có checksum chỉ định rõ
sudo ./install-zimbra10.sh --domain example.com \
  --installer /root/zimbra.tgz --sha256 EXPECTED_SHA256

./install-zimbra10.sh --help
```

LFD theo dõi SMTP AUTH tại `/var/log/zimbra.log` và các đăng nhập Zimbra thất bại có IP hợp lệ tại `/opt/zimbra/log/audit.log`. Quy tắc Zimbra chặn tạm 300 giây sau 5 lần thất bại; không tin địa chỉ forwarded do client cung cấp và không chặn loopback. Với proxy bên ngoài, cần kiểm tra địa chỉ ghi trong log và cấu hình trust riêng trước khi dựa vào LFD. Kiểm tra thực tế đăng nhập sai, log `/var/log/lfd.log`, và cơ chế mở khóa từ console của VPS.

### Kết quả và xử lý lỗi

- Mật khẩu được lưu trong `/root/ZIMBRA-INSTALL-INFO.txt`, quyền `600`; phần tổng kết thông thường không in mật khẩu vào log.
- `/root/zimbra-setup.conf` cũng chứa thông tin nhạy cảm, quyền `600`; bảo vệ cả hai file và backup của chúng.
- Log cài đặt: `/root/zimbra-auto-install.log`. Không chia sẻ file cấu hình/mật khẩu cùng log hỗ trợ.
- SNMP notifications mặc định tắt. Kiểm tra phiên bản dịch vụ sau khi cài; không báo thành công nếu dịch vụ dừng hoặc phiên bản khác archive đã chọn.
- Hai lần chạy đồng thời bị chặn bằng khóa tiến trình.
- Nếu chỉ bước firewall lỗi, dùng `--only-firewall` để chạy lại. Nếu Zimbra đã cài package nhưng setup thất bại, giữ nguyên dữ liệu và xem log; script không tự xóa `/opt/zimbra` hay chạy lại setup trên một hệ thống chưa xác định trạng thái.
- TLS công khai và việc gia hạn certificate vẫn dùng script SSL ở phần tiếp theo; bộ cài này không tự cấp certificate.

Kiểm tra hồi quy trước khi sửa script:

```bash
bash -n install-zimbra10.sh
shellcheck install-zimbra10.sh
python3 -m unittest discover -s tests -v
```

Các bài kiểm tra này mô phỏng thành phần độc lập và không cài phần mềm hay thay firewall của máy chạy kiểm tra. Trước production, kiểm thử cài mới trên VPS Ubuntu 22.04 và 24.04, gửi/nhận mail, TLS, SSH và reboot thực tế.

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
