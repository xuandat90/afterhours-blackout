# Afterhours BlackOut

[🇬🇧 English version](README.md)

Ứng dụng ở menu bar cho macOS, **tắt thật** màn hình tích hợp của MacBook
(giống lúc rút cáp) khi bạn làm việc trên màn hình ngoài — và tự bật lại khi
rút cáp.

Lấy cảm hứng từ tính năng BlackOut của [Lunar](https://github.com/alin23/Lunar).

## Tính năng

- **Ngắt thật** — gỡ màn hình tích hợp (hoặc bất kỳ màn hình nào) khỏi danh sách
  màn hình bằng API riêng tư `CGSConfigureDisplayEnabled`: mất tín hiệu, tắt đèn
  nền, GPU ngắn kéo. Không phải lớp phủ đen.
- **Luật tự động** — "Giữ màn hình tích hợp tắt khi có màn ngoài": rút cáp thì
  tự bật lại, cắm lại thì tự tắt như lúc rút.
- **Watchdog** — quét trạng thái màn hình thật mỗi 2 giây, nên màn hình tích hợp
  luôn bật lại kể cả khi macOS không gửi thông báo
  `didChangeScreenParametersNotification` (thường gặp khi rút cáp thật), và
  không bao giờ để máy không còn màn hình nào đang hoạt động.
- **Độ sáng theo từng màn hình** — chỉnh độ sáng phần cứng
  (`DisplayServicesSetBrightness`) trên màn tích hợp; màn ngoài dùng hạ gamma
  (software dim) nếu không nhận độ sáng qua DisplayServices.
- **Nhận diện ổn định** — màn hình được theo dõi bằng
  `CGDisplayCreateUUIDFromDisplayID`, vì `CGDirectDisplayID` bị đánh lại sau mỗi
  lần bật lại (quan sát được trên macOS 27: 1 → 11 → 12 → 13).
- **An toàn khi crash** — màn hình đang tắt được ghi vào `UserDefaults` và tự bật
  lại ở lần mở kế tiếp, cùng cơ chế khôi phục khi thoát app.

## Yêu cầu

- macOS 13+ (phát triển và kiểm thử trên macOS 27.0.1, Apple Silicon)
- Apple Silicon để dùng đường ngắt màn hình
- Xcode / bộ công cụ Swift 6 để build

## Build

```bash
./build-app.sh          # swift build + đóng gói "Afterhours BlackOut.app" + ký ad-hoc
open "Afterhours BlackOut.app"
```

Script build luôn ký lại bundle mỗi lần chạy — thay binary trong bundle mà không
ký lại sẽ bị launchd kill trên macOS mới.

## Sử dụng

| Thao tác | Cách làm |
|---|---|
| Bật/tắt một màn hình | Công tắc trong popover, hoặc bấm vào hàng |
| Tắt/bật màn hình tích hợp | Nút "Built-in" |
| Bật lại tất cả | "Restore All", `⌃⌘6` (hotkey toàn cục), hoặc `Esc` |
| Luật tự động | Công tắc ở cuối popover |

Màn hình tích hợp không bao giờ bị tắt nếu nó là màn hình đang hoạt động cuối
cùng; nếu mất màn hình cuối, watchdog tự bật lại màn tích hợp.

Cờ chẩn đoán:

```bash
"Afterhours BlackOut.app/Contents/MacOS/AfterhoursBlackOut" --self-test   # kiểm tra độ sáng + ngắt/bật
"Afterhours BlackOut.app/Contents/MacOS/AfterhoursBlackOut" --snapshot    # chụp panel ra /tmp
```

Log khi chạy: `/tmp/afterhours-blackout.log`.

## Lưu ý

- `CGSConfigureDisplayEnabled` là API riêng tư, không có tài liệu. Vẫn hoạt động
  trên macOS 27.0.1 nhưng Apple có thể gỡ bỏ ở bất kỳ bản nào; app sẽ báo lỗi
  thay vì treo khi symbol biến mất.
- Độ sáng màn ngoài đi qua bảng gamma (`software dim`) trên máy này:
  `IOAVServiceCreateWithService` trả nil trên macOS 27 với app chưa ký nên
  DDC/CI bị chặn. Chế độ này được ghi rõ trên giao diện và được đặt lại khi
  thoát/khởi động app.
- Sau khi bật lại, màn hình nhận `CGDirectDisplayID` mới sau vài giây; menu có
  thể trễ một lúc trong khi `NSScreen` cập nhật.

## Cấu trúc dự án

```
Package.swift                          manifest SwiftPM (macOS 13+, Swift 6)
Sources/AfterhoursBlackOut/main.swift  app, engine điều khiển màn hình, watchdog, UI
Info.plist                             thông tin bundle (LSUIElement)
build-app.sh                           build + đóng gói + ký ad-hoc
index.html                             prototype HTML đầu tiên (để tham khảo)
```
