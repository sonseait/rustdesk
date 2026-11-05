# Minimal RustDesk Host — kế hoạch triển khai

## Goal

Tạo biến thể desktop có cửa sổ nhỏ chỉ hiển thị ID và mật khẩu tạm thời thực của máy khách, để một máy khác kết nối điều khiển bằng lõi RustDesk hiện có.

## Current context / assumptions

- Workspace: `/Users/eric/Codes/rustdesk`; nhánh `main`, working tree sạch tại thời điểm khảo sát.
- Mã desktop ở `desktop/`, Flutter đang dùng ở `desktop/flutter/` (không phải thư mục legacy).
- `desktop/flutter/lib/main.dart` gọi `AppBootstrap.instance.start(args)` trước khi chọn surface; có nhánh riêng cho subwindow, `--cm`, `--install`.
- `desktop/flutter/lib/app/aurora_app.dart` đã nhận `home`; mặc định mở `WorkspacePage`. Có thể dùng lại app shell mà không thay giao diện đầy đủ.
- `desktop/flutter/lib/integration/adapters/service_status_adapter.dart` cung cấp `ServiceStatus`, `ServiceStatusAdapter`, polling 500ms, ID từ `bind.mainGetMyId()` và mật khẩu từ `bind.mainGetTemporaryPassword()`.
- Không dùng `WorkspaceViewModel` cho màn hình mới: `start()` của nó tải account, address book, nhóm và peer list không cần thiết.
- Workflow `.github/workflows/managed-client-release.yml` build Rust với `flutter,managed-only`, Flutter 3.44.8, rồi đóng gói nguyên release directory. Không sửa workflow này trong MVP.
- `desktop/src/server/connection.rs:2824` kiểm tra managed capability trước xác thực. Một mật khẩu đúng không thay thế enrollment/policy hợp lệ.
- Giả định MVP là một biến thể UI của ứng dụng hiện có, không phải remote engine mới. “Nhỏ” ở đây là cửa sổ và tính năng hiển thị; không hứa executable nhỏ hơn đáng kể.
- Không tự cài service, không tự bật unattended access, không đổi server, password mode, approval mode, whitelist, 2FA hay policy quản trị. Các cấu hình này được giữ nguyên.
- Bản Host được bật bằng build-time define `HOST_ONLY=true`; bản đầy đủ không đổi. Đây là giao diện chỉ nhận kết nối, không phải ranh giới bảo mật cấm mọi kết nối đi ở native layer.
- Chưa có yêu cầu OS cụ thể: thiết kế dùng chung desktop, xác minh native trên macOS hiện có; Windows cần build/test trên Windows trước khi phát hành cho máy khách Windows.

## Architecture / proposed approach

Dùng chung binary/native engine, bootstrap và cơ chế quản lý kết nối vào, thêm một `HostPage` Cupertino gọn sử dụng trực tiếp `ServiceStatusAdapter`. Chọn `HostPage` ở nhánh main khi build có `HOST_ONLY=true`, sau các nhánh installer/connection-manager/session để không phá các process phụ. UI mặc định có hai giá trị ID/Password và một dòng trạng thái; lỗi, service stopped hoặc password disabled không được trình bày như đã sẵn sàng.

Không thêm dependency, không sinh mật khẩu trong Dart, không lưu hoặc log mật khẩu, không làm lại signaling/NAT traversal/capture/input/encryption.

## Execution rules

Chỉ kế hoạch được ghi ở lượt này; các lệnh bên dưới dành cho lượt triển khai sau. Mỗi mục RED/GREEN là một lát cắt dọc: viết test, chạy và quan sát fail do hành vi thiếu, rồi mới thêm phần implementation tương ứng. Mục 2–8 là các bước 2–5 phút; build native/E2E là release gate riêng có thể lâu hơn. Commit sau GREEN là checkpoint đề xuất, chỉ chạy khi người dùng cho phép commit; không commit test đang đỏ, không dùng `git add .`.

Tất cả lệnh Flutter bên dưới chạy tại `/Users/eric/Codes/rustdesk/desktop/flutter` trừ khi ghi khác.

## Step-by-step tasks

### 1. Kiểm tra môi trường và baseline (2–5 phút)

Đọc lại `desktop/flutter/lib/main.dart`, `desktop/flutter/lib/integration/adapters/service_status_adapter.dart`, `desktop/flutter/test/integration/boot_config_test.dart`, và `desktop/flutter/test/aurora_app_test.dart` trước khi sửa. Kiểm tra trạng thái repo và SDK:

```sh
# repository root
git status --short
git branch --show-current
# desktop/flutter
flutter --version
flutter test test/integration/boot_config_test.dart test/integration/adapters_test.dart
```

Kỳ vọng: biết rõ file bẩn có sẵn, SDK hợp lệ, tests kết thúc `All tests passed!`. Nếu thiếu packages, dùng `flutter pub get` trong lượt triển khai và không tự ý update dependency. Không chạy setup/build ở lượt plan.

### 2. RED: test ID thật và không có UI remote đi (2–5 phút)

Tạo `desktop/flutter/test/host_page_test.dart` với nội dung dưới. Test double chỉ thay nguồn trạng thái native, không thay widget đang kiểm tra.

```dart
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/features/host/host_page.dart';
import 'package:flutter_hbb/integration/adapters/service_status_adapter.dart';

class TestServiceStatusAdapter extends ServiceStatusAdapter {
  ServiceStatus current = const ServiceStatus.initial();
  int starts = 0;
  int stops = 0;

  @override
  ServiceStatus get status => current;

  @override
  void start() { starts++; }

  @override
  void stop() { stops++; }

  void publish(ServiceStatus next) {
    current = next;
    notifyListeners();
  }
}

void main() {
  testWidgets('shows native ID and password without outbound workspace',
      (tester) async {
    final service = TestServiceStatusAdapter();
    service.current = const ServiceStatus.initial().copyWith(
      isLoaded: true,
      deviceId: '847293160',
      temporaryPassword: 'test-only-password',
      connectStatus: ConnectStatus.connected,
      isServiceRunning: true,
    );
    await tester.pumpWidget(CupertinoApp(
      home: HostPage(service: service),
    ));
    expect(find.text('847293160'), findsOneWidget);
    expect(find.text('test-only-password'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(find.text('Address book'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });
}
```

Chạy `flutter test test/host_page_test.dart`. RED ban đầu: import/class `HostPage` chưa tồn tại. Sau khi thêm scaffold, tiếp tục yêu cầu test fail vì chưa render dữ liệu, không chấp nhận lỗi cú pháp làm bằng chứng RED.

### 3. GREEN: thêm màn hình tối thiểu (2–5 phút)

Tạo `desktop/flutter/lib/features/host/host_page.dart` theo code đầy đủ dưới, nhưng thêm lần lượt các nhánh lỗi/lifecycle ở bước kế tiếp sau test tương ứng. Code này là trạng thái đích, không phải lý do để bỏ qua RED.

```dart
import 'package:flutter/cupertino.dart';
import 'package:flutter_hbb/integration/adapters/service_status_adapter.dart';

class HostPage extends StatefulWidget {
  const HostPage({super.key, this.service, this.bridgeError});

  final ServiceStatusAdapter? service;
  final Object? bridgeError;

  @override
  State<HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<HostPage> {
  late final ServiceStatusAdapter _service;
  late final bool _ownsService;

  @override
  void initState() {
    super.initState();
    _ownsService = widget.service == null;
    _service = widget.service ?? ServiceStatusAdapter();
    if (widget.bridgeError == null) _service.start();
  }

  @override
  void dispose() {
    _service.stop();
    if (_ownsService) _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: SafeArea(
        child: AnimatedBuilder(
          animation: _service,
          builder: (context, _) {
            final s = _service.status;
            final unavailable = widget.bridgeError != null || s.hasError;
            final passwordEnabled =
                s.verificationMethod != kUsePermanentPassword;
            final ready = !unavailable && s.isLoaded &&
                s.deviceId.isNotEmpty && s.isServiceRunning &&
                s.connectStatus == ConnectStatus.connected &&
                passwordEnabled && s.temporaryPassword.isNotEmpty;
            final status = unavailable
                ? 'Connection unavailable'
                : !s.isLoaded
                    ? 'Starting…'
                    : !s.isServiceRunning
                        ? 'Service stopped'
                        : !passwordEnabled
                            ? 'Temporary password disabled'
                            : ready
                                ? 'Ready'
                                : 'Not ready';
            return Padding(
              padding: const EdgeInsets.all(20),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('ID'),
                    SelectableText(
                      unavailable || !s.isLoaded || s.deviceId.isEmpty
                          ? '—' : s.deviceId,
                      style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 24,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Password'),
                    SelectableText(
                      unavailable || !s.isLoaded || !passwordEnabled ||
                              s.temporaryPassword.isEmpty
                          ? '—' : s.temporaryPassword,
                      style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(status),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
```

Chạy `flutter test test/host_page_test.dart`. Kỳ vọng GREEN `All tests passed!`; chỉ có dữ liệu từ adapter được hiển thị, không ID/password hardcode trong production.

### 4. RED→GREEN: cập nhật mật khẩu và che dữ liệu stale (mỗi case 2–5 phút)

Thêm từng `testWidgets` vào `desktop/flutter/test/host_page_test.dart`, dùng cùng `TestServiceStatusAdapter`, dựng `CupertinoApp(home: HostPage(service: service))` như bước 2, rồi `service.publish(...)` và `await tester.pump()`:

- Snapshot initial: `Starting…`, hai dấu `—`, không `Ready`.
- Từ snapshot online bước 2, đổi `temporaryPassword` sang `rotated-test-password`: giá trị cũ biến mất và giá trị mới xuất hiện.
- Publish `service.current.copyWith(error: StateError('test failure'))`: `Connection unavailable`, ID/password cũ không còn hiển thị.
- Publish `service.current.copyWith(clearError: true)`: các giá trị trở lại từ adapter, không cần restart app.
- `verificationMethod: kUsePermanentPassword` dù snapshot có temporary password: `Temporary password disabled`, không hiện secret tạm thời và không hiện `Ready`.
- `isServiceRunning: false`: `Service stopped`, không `Ready`.
- `connectStatus: ConnectStatus.disconnected`: `Not ready`, không `Ready`.
- Online nhưng ID/password rỗng: `Not ready`, không `Ready`.

Ví dụ test cập nhật đầy đủ để chép và điều chỉnh các case còn lại:

```dart
testWidgets('updates the password when the native snapshot changes',
    (tester) async {
  final service = TestServiceStatusAdapter();
  service.current = const ServiceStatus.initial().copyWith(
    isLoaded: true,
    deviceId: '847293160',
    temporaryPassword: 'before-rotation',
    connectStatus: ConnectStatus.connected,
    isServiceRunning: true,
  );
  await tester.pumpWidget(CupertinoApp(home: HostPage(service: service)));
  service.publish(service.current.copyWith(
    temporaryPassword: 'after-rotation',
  ));
  await tester.pump();
  expect(find.text('before-rotation'), findsNothing);
  expect(find.text('after-rotation'), findsOneWidget);
  await tester.pumpWidget(const SizedBox.shrink());
  service.dispose();
});
```

Mỗi case: `flutter test test/host_page_test.dart --plain-name '<tên test>'`; thấy RED trước nhánh triển khai tương ứng, sau đó GREEN. Không dùng `pumpAndSettle` với periodic poll thật.

### 5. RED→GREEN: lifecycle và bridge failure (2–5 phút/case)

Cùng file test, thêm case mount→unmount kiểm tra `starts == 1`, `stops == 1`; widget không dispose adapter được inject. Thêm case truyền `bridgeError: StateError('test')`: `starts == 0`, `Connection unavailable`, không lộ raw exception/secret. Hoàn tất lifecycle theo code đích bước 3.

Chạy `flutter test test/host_page_test.dart`; kỳ vọng GREEN và không timer pending/exception sau dispose. Chạy thêm ở viewport `Size(360, 240)` và text scale 1.5 bằng API Flutter test hiện có; `tester.takeException()` phải null. Không thêm cơ chế auto-restart service.

### 6. RED→GREEN: chọn Host mà không phá các process phụ (2–5 phút)

Tạo `desktop/flutter/lib/app/main_home.dart` với selector nhỏ, không IO:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/features/host/host_page.dart';

const hostOnlyBuild = bool.fromEnvironment('HOST_ONLY');

Widget? mainHome({
  bool hostOnly = hostOnlyBuild,
  Object? bridgeError,
}) => hostOnly ? HostPage(bridgeError: bridgeError) : null;
```

Trước đó tạo `desktop/flutter/test/main_home_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/app/main_home.dart';
import 'package:flutter_hbb/features/host/host_page.dart';

void main() {
  test('full build retains the default workspace', () {
    expect(mainHome(hostOnly: false), isNull);
  });
  test('host build selects the minimal page', () {
    expect(mainHome(hostOnly: true), isA<HostPage>());
  });
  test('host page receives native bootstrap failure', () {
    final error = StateError('test');
    final page = mainHome(hostOnly: true, bridgeError: error) as HostPage;
    expect(page.bridgeError, same(error));
  });
  test('build define is applied', () {
    expect(hostOnlyBuild, const bool.fromEnvironment('HOST_ONLY'));
  });
}
```

RED trước selector, GREEN sau selector:

```sh
flutter test test/main_home_test.dart
flutter test --dart-define=HOST_ONLY=true test/main_home_test.dart
```

Cả hai `All tests passed!`.

Trong `desktop/flutter/lib/main.dart`, thêm import `package:flutter_hbb/app/main_home.dart`; chỉ thay dòng cuối của nhánh main `runApp(const AuroraApp());` bằng:

```dart
runApp(AuroraApp(
  home: mainHome(bridgeError: AppBootstrap.instance.error),
));
```

Không thay các nhánh `subWindow`, `connectionManager`, `install`, không thay `_installWindowMethodHandler()`. `flutter test test/integration/boot_config_test.dart test/main_home_test.dart` phải pass. Kiểm tra diff để bảo đảm chỉ fallback main đổi; unit selector không tự chứng minh integration startup, phải làm native gate bên dưới.

### 7. Cửa sổ gọn, không ghi đè frame bản đầy đủ (2–5 phút)

Trong `desktop/flutter/lib/main.dart`, cho `_restoreMainWindow` nhận `bool hostOnly = false` và truyền `hostOnly: hostOnlyBuild` từ call site nhánh main. Ngay sau `await windowManager.ensureInitialized();`, thêm nhánh sau rồi return, trước khi đọc `WindowFrameStore`:

```dart
if (hostOnly) {
  await windowManager.setMinimumSize(const Size(320, 220));
  await windowManager.setSize(const Size(360, 260));
  await windowManager.center();
  if (hide) await windowManager.hide();
  return;
}
```

`Size` đã có từ `flutter/widgets.dart`. Không wrap Host trong `WindowFrameKeeper` dùng chung workspace; không overwrite kích thước đã lưu của bản đầy đủ. Không thêm resize/titlebar tùy biến hoặc dependency UI mới. Gate kiểm tra kích thước bằng native launch ở bước 9; widget overflow được kiểm tra ở bước 5. Nếu cần test method-channel tự động, đọc API mock của phiên bản `window_manager` đang cài trước, không đoán method name.

### 8. Regression, format và checkpoint (2–5 phút chạy khởi đầu; chờ suite xong)

```sh
dart format lib/features/host/host_page.dart lib/app/main_home.dart lib/main.dart test/host_page_test.dart test/main_home_test.dart
flutter analyze
flutter test
flutter test --dart-define=HOST_ONLY=true test/host_page_test.dart test/main_home_test.dart test/integration/boot_config_test.dart
# repository root
git diff --check
git diff --stat
```

Kỳ vọng: formatter sạch, analyze không có issue mới, toàn bộ tests pass, diff check exit 0. Nếu baseline lỗi có sẵn, báo riêng và không sửa lan ra ngoài scope. Không coi unit/widget pass là E2E remote pass.

Nếu được cho phép commit, checkpoint nhỏ sau từng nhóm GREEN:

```sh
# repository root; chỉ khi đã được cho phép commit
git add desktop/flutter/lib/features/host/host_page.dart desktop/flutter/test/host_page_test.dart
git commit -m "feat: add minimal host identity surface"
git add desktop/flutter/lib/app/main_home.dart desktop/flutter/lib/main.dart desktop/flutter/test/main_home_test.dart
git commit -m "feat: select compact host surface at build time"
```

Không push, không chạy workflow release/publish trong scope này.

### 9. Native build và hai máy thật (release gate, không phải việc 5 phút)

Dùng native dependency/toolchain và provisioning hiện có; không đọc/ghi secrets để minh họa. Build Rust và Flutter phải đồng bộ managed mode. Với bản managed macOS trên môi trường đã cấu hình:

```sh
# desktop
cargo build --release --lib --features flutter,managed-only
# desktop/flutter
flutter build macos --release --no-pub --dart-define=HOST_ONLY=true
```

Trên Windows runner/dev máy đã cài dependencies theo `.github/workflows/managed-client-release.yml`:

```powershell
# desktop
cargo build --locked --release --lib --features flutter,managed-only
# desktop/flutter
flutter build windows --release --no-pub --dart-define=HOST_ONLY=true
```

Không chạy build managed thiếu provisioning rồi thay bằng unmanaged để tuyên bố pass. Nếu cần bản không quản lý, phải được xác nhận như lựa chọn sản phẩm riêng và build `--features flutter` thay vì `managed-only` một cách có chủ đích.

Deliverable Windows là toàn bộ `desktop/flutter/build/windows/x64/runner/Release/`, không chỉ EXE; macOS là `desktop/flutter/build/macos/Build/Products/Release/RustDesk.app` theo workflow hiện tại. Đóng gói trong lượt triển khai chỉ khi user yêu cầu artifact. Không hứa single EXE.

Checklist native trên máy A (Host) và B (controller full), ghi PASS/FAIL/BLOCKED không ghi mật khẩu:

1. A mở từ executable đã build, cửa sổ gọn, không peer list/settings/outgoing entry; ID/password khớp native thực.
2. B nhập ID và password đang hiển thị trên A: thấy màn hình A và điều khiển được chuột/bàn phím sau các approval/OS permissions/policy hiện hữu. `Ready` chỉ là status local, không chứng nhận mọi network/OS permission.
3. B nhập sai password: không có truy cập; không đổi auth để làm test pass.
4. Ngắt phiên rồi tạo phiên mới với password hiện thời. Nếu lõi rotate password, UI cập nhật trong polling kế tiếp.
5. Ngắt mạng A: trạng thái không `Ready`; nối lại: trạng thái phục hồi từ native.
6. Thử native bridge thiếu/hỏng trong môi trường thử nghiệm an toàn: không hiện credential giả hoặc trạng thái ready.
7. Connection-manager/approval vẫn hoạt động; không bỏ `--cm` vì mong muốn “chỉ ID/password”.
8. Đóng Host: ghi chính xác remote/service còn chạy hay dừng theo hành vi lõi hiện có. Không quảng cáo “đóng cửa sổ là dừng truy cập” nếu service vẫn chạy.
9. Managed deployment không enrollment hợp lệ hoặc policy cấm: truy cập bị từ chối. Không bypass capability gate.
10. Bản full không define vẫn mở workspace, mở được session và installer như trước.

Nếu không có máy B/Windows runner, báo BLOCKED cho đúng gate, không ghi E2E PASS từ widget tests.

## Tests / validation summary

- TDD theo hành vi nhỏ: render dữ liệu → rotation → failure/stale → auth-mode visibility → lifecycle → build selector.
- Regression: boot config, toàn bộ Flutter suite, analyze, format, git diff check.
- Native: đúng artifact + ID/password thật, incoming remote success/failure, OS approval, reconnect, full-client regression.
- Không mở rộng thành audit production toàn hệ thống, thay CP protocol, cài unattended service, migration credential store hay release signing.

## Risks, tradeoffs, and open questions

1. OS máy khách chưa được chỉ định. Trước khi giao artifact, xác nhận Windows/macOS/Linux và kiến trúc CPU; implementation UI không cần chờ câu trả lời.
2. Portable hay installed/unattended chưa được yêu cầu. MVP giữ cách khởi chạy hiện có; UAC, màn hình đăng nhập và chạy trước login không nằm trong cam kết.
3. Managed-only có thể từ chối remote dù ID/password hợp lệ khi enrollment/policy chưa ready. Không đổi auth/enrollment để làm UI đơn giản hơn.
4. Máy đã cấu hình permanent-only/click approval không thể luôn remote chỉ bằng temporary password; UI giải thích không khả dụng thay vì sửa cấu hình âm thầm. Nếu cần password-only unattended, phải phê duyệt thay đổi bảo mật riêng.
5. `HOST_ONLY` là lựa chọn surface, không cắt bỏ native/client capability. Nếu yêu cầu cấm tuyệt đối outbound kể cả deep link/IPC/CLI, cần kế hoạch native enforcement riêng và test tất cả entrypoints; không gắn nhãn đã bảo đảm ở MVP.
6. Flutter và native codec vẫn đi kèm, nên kích thước tải không giảm nhiều. Nếu “ứng dụng nhỏ” nghĩa là vài MB/single EXE, cần xác nhận constraint trước khi chọn kiến trúc khác.
7. ID/password hiển thị công khai trên màn hình đúng theo yêu cầu, có rủi ro người đứng gần/chụp màn hình. Không thêm logging, telemetry hoặc persistent plaintext; chỉ share với người được phép.
8. Status adapter giữ snapshot cũ khi lỗi, nên UI mới phải che credential stale trên lỗi. Đây là sửa presentation cục bộ, không thay semantics adapter cho workspace.

## Completion definition

Chỉ hoàn thành feature khi code + test mới + regression thực sự pass. Chỉ ghi “remote được” sau khi bước 9 thành công giữa hai máy; nếu thiếu môi trường, báo rõ UI đã triển khai và native/E2E còn BLOCKED. Không thực hiện code, build, commit, publish hay triển khai trong lượt lập kế hoạch này.
