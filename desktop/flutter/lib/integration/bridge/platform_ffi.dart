import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:external_path/external_path.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/platform/win32.dart';

typedef SessionID = UuidValue;
typedef HandleEvent = Future<void> Function(Map<String, dynamic> evt);
typedef StreamEventHandler = Future<void> Function(Map<String, dynamic>);
typedef FMethod = String Function(String, dynamic);

typedef _GetRgba = Pointer<Uint8> Function(Pointer<Utf8>, int);
typedef _GetRgbaNative = Pointer<Uint8> Function(Pointer<Utf8>, Int32);

final class RgbaFrame extends Struct {
  @Uint32()
  external int len;
  external Pointer<Uint8> data;
}

/// The Linux bundle keeps the core library at lib/librustdesk.so next to the
/// executable. Prefer that copy, mirroring linux/main.cc: the plain name relies
/// on the loader search path, which repackaged installs may not cover.
/// https://github.com/rustdesk/rustdesk/discussions/14407
DynamicLibrary _openLinuxCoreLib() {
  final bundled =
      '${File(Platform.resolvedExecutable).parent.path}/lib/librustdesk.so';
  try {
    if (File(bundled).existsSync()) {
      return DynamicLibrary.open(bundled);
    }
  } catch (e) {
    debugPrint("Failed to load '$bundled': $e");
  }
  return DynamicLibrary.open('librustdesk.so');
}

/// FFI wrapper around the native Rust core, hiding platform differences.
///
/// Ported from `flutter_legacy/lib/models/native_model.dart`. The call sequence
/// in [init] is load-bearing: the Rust side expects device id/name and home dir
/// before `mainInit`, and `cmInit` before either when running as the connection
/// manager.
class PlatformFFI {
  PlatformFFI._();

  static final PlatformFFI instance = PlatformFFI._();

  static get localeName => Platform.localeName;

  static Future<String> getVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  final _eventHandlers = <String, Map<String, HandleEvent>>{};
  final _toAndroidChannel = const MethodChannel('mChannel');

  late RustdeskImpl _ffiBind;
  String _appType = kAppTypeMain;
  DesktopType _desktopType = DesktopType.main;
  int? _windowId;
  String _dir = '';
  // _homeDir is only needed for Android and iOS.
  String _homeDir = '';
  bool _initialized = false;
  StreamEventHandler? _eventCallback;
  _GetRgba? _sessionGetRgba;

  RustdeskImpl get ffiBind => _ffiBind;

  /// True once [init] has completed. Adapters must not call [ffiBind] before
  /// this is true.
  bool get isInitialized => _initialized;

  String get appType => _appType;

  DesktopType get desktopType => _desktopType;

  int? get windowId => _windowId;

  bool get isMain => _appType == kAppTypeMain;

  String get appDir => _dir;

  String get homeDir => _homeDir;

  bool registerEventHandler(
    String eventName,
    String handlerName,
    HandleEvent handler, {
    bool replace = false,
  }) {
    debugPrint('registerEventHandler $eventName $handlerName');
    final handlers = _eventHandlers[eventName];
    if (handlers == null) {
      _eventHandlers[eventName] = {handlerName: handler};
      return true;
    }
    if (!replace && handlers.containsKey(handlerName)) {
      return false;
    }
    handlers[handlerName] = handler;
    return true;
  }

  void unregisterEventHandler(String eventName, String handlerName) {
    debugPrint('unregisterEventHandler $eventName $handlerName');
    _eventHandlers[eventName]?.remove(handlerName);
  }

  String translate(String name, String locale) =>
      _ffiBind.translate(name: name, locale: locale);

  Uint8List? getRgba(SessionID sessionId, int display, int bufSize) {
    if (_sessionGetRgba == null) return null;
    final sessionIdStr = sessionId.toString().toNativeUtf8();
    try {
      final buffer = _sessionGetRgba!(sessionIdStr, display);
      if (buffer == nullptr) return null;
      return buffer.asTypedList(bufSize);
    } finally {
      malloc.free(sessionIdStr);
    }
  }

  int getRgbaSize(SessionID sessionId, int display) =>
      _ffiBind.sessionGetRgbaSize(sessionId: sessionId, display: display);

  void nextRgba(SessionID sessionId, int display) =>
      _ffiBind.sessionNextRgba(sessionId: sessionId, display: display);

  void registerPixelbufferTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterPixelbufferTexture(
          sessionId: sessionId, display: display, ptr: ptr);

  void registerGpuTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterGpuTexture(
          sessionId: sessionId, display: display, ptr: ptr);

  /// Load the native Rust core and hand it the environment it expects.
  ///
  /// Throws if the library cannot be loaded or the core rejects
  /// initialization; the caller is responsible for surfacing that to the UI
  /// rather than starting with a half-initialized bridge.
  Future<void> init(
    String appType, {
    DesktopType desktopType = DesktopType.main,
    int? windowId,
  }) async {
    _appType = appType;
    _desktopType = desktopType;
    _windowId = windowId;

    final dylib = isAndroid
        ? DynamicLibrary.open('librustdesk.so')
        : isLinux
            ? _openLinuxCoreLib()
            : isWindows
                ? DynamicLibrary.open('librustdesk.dll')
                // Use the executable itself as the dynamic library on macOS.
                // Multiple dylib instances make some global Rust instances
                // (e.g. `lazy_static` objects) be created more than once.
                : DynamicLibrary.process();

    debugPrint('initializing FFI $_appType');
    _sessionGetRgba =
        dylib.lookupFunction<_GetRgbaNative, _GetRgba>('session_get_rgba');
    try {
      // Fails for the SYSTEM user.
      _dir = (await getApplicationDocumentsDirectory()).path;
    } catch (e) {
      debugPrint('Failed to get documents directory: $e');
    }
    _ffiBind = RustdeskImpl(dylib);

    if (isLinux) {
      if (isMain) {
        // Start a dbus service for uri links; no need to await.
        _ffiBind.mainStartDbusServer();
      }
    } else if (isMacOS && isMain) {
      // Start the ipc service for uri links.
      _ffiBind.mainStartIpcUrlServer();
    }
    _startListenEvent();

    try {
      if (isAndroid) {
        _homeDir = (await ExternalPath.getExternalStorageDirectories())[0];
      } else if (isIOS) {
        _homeDir = _ffiBind.mainGetDataDirIos(appDir: _dir);
      }
    } catch (e) {
      debugPrintStack(label: 'resolve home dir failed: $e');
    }

    final device = await _readDeviceIdentity();
    debugPrint('_appType:$_appType,id:${device.id},name:${device.name},'
        'dir:$_dir${isMobile ? ',homeDir:$_homeDir' : ''}');

    if (_desktopType == DesktopType.cm) {
      await _ffiBind.cmInit();
    }
    await _ffiBind.mainDeviceId(id: device.id);
    await _ffiBind.mainDeviceName(name: device.name);
    await _ffiBind.mainSetHomeDir(home: _homeDir);
    await _ffiBind.mainInit(appDir: _dir, customClientConfig: '');

    version = await getVersion();
    _initialized = true;
  }

  Future<_DeviceIdentity> _readDeviceIdentity() async {
    final deviceInfo = DeviceInfoPlugin();
    if (isAndroid) {
      final info = await deviceInfo.androidInfo;
      androidVersion = info.version.sdkInt;
      return _DeviceIdentity(
          info.id.hashCode.toString(), '${info.brand}-${info.model}');
    }
    if (isIOS) {
      final info = await deviceInfo.iosInfo;
      return _DeviceIdentity(
          info.identifierForVendor.hashCode.toString(), info.utsname.machine);
    }
    if (isLinux) {
      final info = await deviceInfo.linuxInfo;
      return _DeviceIdentity(info.machineId ?? info.id, info.name);
    }
    if (isWindows) {
      try {
        // Request the Windows build number first to fix overflow on Win7.
        windowsBuildNumber = getWindowsTargetBuildNumber();
        final info = await deviceInfo.windowsInfo;
        return _DeviceIdentity(info.computerName, info.computerName);
      } catch (e) {
        debugPrintStack(label: 'get windows device info failed: $e');
        return const _DeviceIdentity('unknown', 'unknown');
      }
    }
    if (isMacOS) {
      final info = await deviceInfo.macOsInfo;
      return _DeviceIdentity(info.systemGUID ?? '', info.computerName);
    }
    return const _DeviceIdentity('NA', 'Flutter');
  }

  Future<bool> tryHandle(Map<String, dynamic> evt) async {
    final name = evt['name'];
    if (name == null) return false;
    final handlers = _eventHandlers[name];
    if (handlers == null || handlers.isEmpty) return false;
    for (final handler in handlers.values.toList()) {
      await handler(evt);
    }
    return true;
  }

  /// Start listening to the Rust core's global event stream.
  void _startListenEvent() {
    final appType = _appType == kAppTypeDesktopRemote && _windowId != null
        ? '$_appType,$_windowId'
        : _appType;
    _ffiBind.startGlobalEventStream(appType: appType).listen((message) {
      () async {
        try {
          final Map<String, dynamic> event = json.decode(message);
          // tryHandle here may be more flexible than _eventCallback.
          if (!await tryHandle(event)) {
            await _eventCallback?.call(event);
          }
        } catch (e) {
          debugPrint('failed to handle global event: $e');
        }
      }();
    });
  }

  void setEventCallback(StreamEventHandler fun) {
    _eventCallback = fun;
  }

  void setMethodCallHandler(FMethod callback) {
    _toAndroidChannel.setMethodCallHandler((call) async {
      callback(call.method, call.arguments);
      return null;
    });
  }

  Future<dynamic> invokeMethod(String method, [dynamic arguments]) async {
    if (!isAndroid) return false;
    return await _toAndroidChannel.invokeMethod(method, arguments);
  }

  void syncAndroidServiceAppDirConfigPath() {
    invokeMethod(AndroidChannel.kSyncAppDirConfigPath, _dir);
  }
}

class _DeviceIdentity {
  const _DeviceIdentity(this.id, this.name);

  final String id;
  final String name;
}

final platformFFI = PlatformFFI.instance;

/// The generated bridge. Only valid after [PlatformFFI.init] completes.
RustdeskImpl get bind => platformFFI.ffiBind;

String get localeName => PlatformFFI.localeName;
