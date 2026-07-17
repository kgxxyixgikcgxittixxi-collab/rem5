# 🎮 Teamobi 2026 – Termux Server Manager

    ## ⚡ Cài đặt – Dùng lệnh này (copy chính xác)

    ```bash
    curl -L --max-redirs 15 https://raw.githubusercontent.com/akah3674-glitch/rem5/main/setup.sh -o ~/tm.sh && bash ~/tm.sh
    ```

    > ⚠️ **Lý do KHÔNG dùng `/tmp`**: Termux không có `/tmp` thật — phải lưu về `~/` (home).  
    > ⚠️ **Lý do KHÔNG dùng `curl|bash`**: Termux pipe làm mất stdin → không nhập menu được.

    ## 📋 Menu

    | # | Chức năng |
    |---|-----------|
    | 1 | **Setup** – Tải Teamobi2026.rar (~630MB), cài packages, init DB |
    | 2 | **Chạy Server** – Start Game + Login + MariaDB |
    | 3 | **Tắt Server** – Dừng tất cả an toàn |
    | 4 | **Mèo Lù 🐱** – Pet manager: thêm/nâng cấp/đổi tên |
    | 5 | **Đăng ký Tài khoản** – Tạo account + mật khẩu + quyền Player/GM/Admin |
    | 6 | **Thêm Vàng/Ngọc** – Nạp cho 1 nhân vật hoặc tất cả |
    | 7 | **Danh sách TK** – Xem, đổi pass, đổi quyền, xóa |
    | 8 | **Logs** – Game log / Login log / Realtime |

    ## 🔌 Cổng

    | Dịch vụ | Port |
    |---------|------|
    | Game Server | **14445** TCP |
    | HTTP/Web | **8080** TCP |
    | Database | **3306** local |

    ---
    > By [akah3674-glitch](https://github.com/akah3674-glitch/rem5)
    