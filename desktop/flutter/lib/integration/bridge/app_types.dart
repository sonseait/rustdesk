/// App type and window contract constants.
///
/// These strings cross the Rust/Flutter boundary and the multi-window channel.
/// They are copied verbatim from `flutter_legacy/lib/consts.dart` and must not
/// be renamed as part of UI work. `WindowType`'s members are serialized by
/// index and named by the existing contract, so the naming lint is disabled
/// for this file rather than renaming them.
// ignore_for_file: constant_identifier_names
library;

/// Used by 'Desktop Main Page', 'Mobile (Client and Server)', 'Install Page'.
const String kAppTypeMain = 'main';

/// Only for the 'Desktop CM Page'.
const String kAppTypeConnectionManager = 'cm';

const String kAppTypeDesktopRemote = 'remote';
const String kAppTypeDesktopFileTransfer = 'file transfer';
const String kAppTypeDesktopViewCamera = 'view camera';
const String kAppTypeDesktopPortForward = 'port forward';
const String kAppTypeDesktopTerminal = 'terminal';

const int kInvalidWindowId = -1;
const int kMainWindowId = 0;
const int kWindowMainId = 0;
const String kWindowPrefix = 'wm_';

/// Multi-window method names.
const String kWindowMainWindowOnTop = 'main_window_on_top';
const String kWindowRefreshCurrentUser = 'refresh_current_user';
const String kWindowGetWindowInfo = 'get_window_info';
const String kWindowGetScreenList = 'get_screen_list';
const String kWindowDisableGrabKeyboard = 'disable_grab_keyboard';
const String kWindowActionRebuild = 'rebuild';
const String kWindowEventHide = 'hide';
const String kWindowEventShow = 'show';
const String kWindowConnect = 'connect';
const String kWindowBumpMouse = 'bump_mouse';

const String kWindowEventNewRemoteDesktop = 'new_remote_desktop';
const String kWindowEventNewFileTransfer = 'new_file_transfer';
const String kWindowEventNewViewCamera = 'new_view_camera';
const String kWindowEventNewPortForward = 'new_port_forward';
const String kWindowEventNewTerminal = 'new_terminal';
const String kWindowEventRestoreTerminalSessions = 'restore_terminal_sessions';
const String kWindowEventActiveSession = 'active_session';
const String kWindowEventActiveDisplaySession = 'active_display_session';
const String kWindowEventGetRemoteList = 'get_remote_list';
const String kWindowEventGetSessionIdList = 'get_session_id_list';
const String kWindowEventRemoteWindowCoords = 'remote_window_coords';
const String kWindowEventSetFullscreen = 'set_fullscreen';
const String kWindowEventMoveTabToNewWindow = 'move_tab_to_new_window';
const String kWindowEventGetCachedSessionData = 'get_cached_session_data';
const String kWindowEventOpenMonitorSession = 'open_monitor_session';

/// Emitted by the core after an automatic software-update check finishes.
const String kCheckSoftwareUpdateFinish = 'check_software_update_finish';

/// Config keys shared between Flutter and the other UIs.
const String kCommConfKeyTheme = 'theme';
const String kCommConfKeyLang = 'lang';

/// Android channel invoke keys.
class AndroidChannel {
  static const kStartAction = 'start_action';
  static const kGetStartOnBootOpt = 'get_start_on_boot_opt';
  static const kSetStartOnBootOpt = 'set_start_on_boot_opt';
  static const kSyncAppDirConfigPath = 'sync_app_dir';

  /// Ask the host whether a permission is granted, and to request one.
  static const kCheckPermission = 'check_permission';
  static const kRequestPermission = 'request_permission';
}

/// Android permission names, as the native side spells them.
///
/// These reach `XXPermissions` unchanged, so they must stay exactly as the
/// Android framework names them.
const String kRecordAudio = 'android.permission.RECORD_AUDIO';
const String kManageExternalStorage =
    'android.permission.MANAGE_EXTERNAL_STORAGE';
const String kRequestIgnoreBatteryOptimizations =
    'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS';
const String kSystemAlertWindow = 'android.permission.SYSTEM_ALERT_WINDOW';
const String kAndroid13Notification = 'android.permission.POST_NOTIFICATIONS';

/// Android settings screens the app can send the user to when a permission
/// cannot be requested in-app.
const String kActionApplicationDetailsSettings =
    'android.settings.APPLICATION_DETAILS_SETTINGS';
const String kActionAccessibilitySettings =
    'android.settings.ACCESSIBILITY_SETTINGS';

/// Which surface this process/window is rendering. Preserved from legacy
/// `common.dart` so window bootstrap decisions stay identical.
enum DesktopType {
  main,
  cm,
  remote,
  fileTransfer,
  viewCamera,
  portForward,
  terminal,
}

/// Must keep the order: the index is serialized across the window channel.
enum WindowType {
  Main,
  RemoteDesktop,
  FileTransfer,
  ViewCamera,
  PortForward,
  Terminal,
  Unknown,
}

extension WindowTypeIndex on int {
  WindowType get windowType {
    switch (this) {
      case 0:
        return WindowType.Main;
      case 1:
        return WindowType.RemoteDesktop;
      case 2:
        return WindowType.FileTransfer;
      case 3:
        return WindowType.ViewCamera;
      case 4:
        return WindowType.PortForward;
      case 5:
        return WindowType.Terminal;
      default:
        return WindowType.Unknown;
    }
  }
}

/// The app type string the Rust event stream expects for a window type.
String appTypeOf(WindowType type) {
  switch (type) {
    case WindowType.RemoteDesktop:
      return kAppTypeDesktopRemote;
    case WindowType.FileTransfer:
      return kAppTypeDesktopFileTransfer;
    case WindowType.ViewCamera:
      return kAppTypeDesktopViewCamera;
    case WindowType.PortForward:
      return kAppTypeDesktopPortForward;
    case WindowType.Terminal:
      return kAppTypeDesktopTerminal;
    case WindowType.Main:
    case WindowType.Unknown:
      return kAppTypeMain;
  }
}

/// The desktop surface a window type renders.
DesktopType desktopTypeOf(WindowType type) {
  switch (type) {
    case WindowType.RemoteDesktop:
      return DesktopType.remote;
    case WindowType.FileTransfer:
      return DesktopType.fileTransfer;
    case WindowType.ViewCamera:
      return DesktopType.viewCamera;
    case WindowType.PortForward:
      return DesktopType.portForward;
    case WindowType.Terminal:
      return DesktopType.terminal;
    case WindowType.Main:
    case WindowType.Unknown:
      return DesktopType.main;
  }
}
