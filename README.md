# Flydigi Apex 5 & Direwolf Mapper cho Play Together VNG (Cài qua ESign)

Bộ project này đóng gói sẵn **2 thành phần** dành riêng cho tựa game **Play Together VNG** (`com.vng.playtogether`) và hai dòng tay cầm **Flydigi Apex 5** / **Flydigi Direwolf**:

1. **`FlydigiPlayTogetherMapper.ipa` (Ứng dụng `.ipa` độc lập cài qua ESign)**:
   - Nhận diện trực tiếp tay cầm **Flydigi Apex 5** và **Flydigi Direwolf** qua giao thức Bluetooth iOS (`GCExtendedGamepad`).
   - Thiết lập sẵn sơ đồ 14 nút chuẩn theo màn hình ngang của **Play Together VNG**:
     - **L-Stick (Joystick Trái)**: Di chuyển nhân vật 360° (`X: 16%, Y: 72%`).
     - **R-Stick (Joystick Phải)**: Xoay góc nhìn Camera (`X: 62%, Y: 45%`).
     - **Nút A**: Nhảy (`Jump`).
     - **Nút B**: Tương tác / Câu cá / Nhặt đồ (`Action / Fish`).
     - **Nút X**: Dùng công cụ cầm tay (`Use Tool`).
     - **Nút Y**: Mở Balo (`Backpack`).
     - **RT (R2)**: Giật cần câu nhanh (`Fast Reel`).
     - **LT (L2)**: Gọi Xe / Ván trượt (`Vehicle`).
     - **LB / RB**: Mở Bản đồ (`Map`) / Đổi nhanh vật phẩm.
     - **D-Pad (↑ / ← / → / ↓)**: Mở Điện thoại, Biểu cảm (Emote), Chat nhanh, Ngồi/Nằm.
   - Cho phép kéo thả vị trí nút trực tiếp trên màn hình, chỉnh vùng chết (Deadzone) chống trôi cần và đồng bộ cấu hình sang game.

2. **`FlydigiPTInject.dylib` (Thư viện nhúng vào IPA Play Together VNG trong ESign)**:
   - Do cơ chế Sandbox của iOS không cho phép một ứng dụng độc lập tự bấm sang ứng dụng khác nếu không can thiệp vào tiến trình game, bạn có thể dùng thêm file `FlydigiPTInject.dylib` đi kèm này để nhúng vào IPA của Play Together VNG ngay trên ESign.

## Hướng dẫn lấy file `.ipa` và cài đặt bằng ESign (Không cần máy Mac)

### Bước 1: Biên dịch tự động ra file `.ipa` trên GitHub
1. Tạo một Repository mới trên GitHub và tải toàn bộ các file trong gói zip này lên (giữ nguyên thư mục `.github/workflows/build-ipa.yml`, `project.yml`, và `Sources/`).
2. Chuyển sang tab **Actions** trên GitHub -> chọn workflow **Build Flydigi PlayTogether IPA & Dylib for ESign** -> bấm **Run workflow**.
3. Sau khoảng 1–2 phút, tải file nén **`Flydigi-PlayTogether-ESign-Package`** ở mục **Artifacts** về điện thoại. Bên trong sẽ có sẵn:
   - `FlydigiPlayTogetherMapper.ipa`
   - `FlydigiPTInject.dylib`

### Bước 2: Kí và cài đặt qua ESign
* **Cài ứng dụng `.ipa` riêng (`FlydigiPlayTogetherMapper.ipa`)**:
  1. Mở **ESign**, nhập file `FlydigiPlayTogetherMapper.ipa` vào danh sách ứng dụng.
  2. Bấm vào ứng dụng -> chọn **Kí (Signature)** bằng chứng chỉ của bạn -> chọn **Cài đặt (Install)**.
* **Nhúng bộ điều khiển vào trực tiếp Play Together VNG (Tùy chọn để điều khiển trực tiếp trong game)**:
  1. Trong **ESign**, chọn file IPA (đã giải mã) của **Play Together VNG** -> chọn **Kí (Signature)** -> bấm **Tùy chọn thêm (More Settings)** -> **Thêm thư viện (Add Library / Inject Dylib)**.
  2. Chọn file `FlydigiPTInject.dylib` rồi bấm **Kí (Sign)** và cài đặt.
