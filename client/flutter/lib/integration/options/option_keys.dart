/// RustDesk option keys.
///
/// Copied verbatim from `flutter_legacy/lib/consts.dart`. These strings are
/// the persisted config keys read and written by the Rust core; renaming one
/// silently drops a user's setting.
library;

const String kOptionViewStyle = "view_style";
const String kOptionScrollStyle = "scroll_style";
const String kOptionEdgeScrollEdgeThickness = "edge-scroll-edge-thickness";
const String kOptionImageQuality = "image_quality";
const String kOptionOpenNewConnInTabs = "enable-open-new-connections-in-tabs";
const String kOptionTextureRender = "use-texture-render";
const String kOptionD3DRender = "allow-d3d-render";
const String kOptionOpenInTabs = "allow-open-in-tabs";
const String kOptionOpenInWindows = "allow-open-in-windows";
const String kOptionForceAlwaysRelay = "force-always-relay";
const String kOptionViewOnly = "view_only";
const String kOptionEnableLanDiscovery = "enable-lan-discovery";
const String kOptionWhitelist = "whitelist";
const String kOptionIdWhitelist = "id-whitelist";
const String kOptionEnableAbr = "enable-abr";
const String kOptionEnableRecordSession = "enable-record-session";
const String kOptionDirectServer = "direct-server";
const String kOptionDirectAccessPort = "direct-access-port";
const String kOptionAllowAutoDisconnect = "allow-auto-disconnect";
const String kOptionAutoDisconnectTimeout = "auto-disconnect-timeout";
const String kOptionEnableHwcodec = "enable-hwcodec";
const String kOptionAllowAutoRecordIncoming = "allow-auto-record-incoming";
const String kOptionAllowAutoRecordOutgoing = "allow-auto-record-outgoing";
const String kOptionHideRecordingButton = "hide-recording-button";
const String kOptionVideoSaveDirectory = "video-save-directory";
const String kOptionAccessMode = "access-mode";
const String kOptionEnableKeyboard = "enable-keyboard";
// "Settings -> Security -> Permissions"
const String kOptionEnableRemotePrinter = "enable-remote-printer";
const String kOptionEnableClipboard = "enable-clipboard";
const String kOptionEnableFileTransfer = "enable-file-transfer";
const String kOptionEnableAudio = "enable-audio";
const String kOptionEnableCamera = "enable-camera";
const String kOptionEnableTerminal = "enable-terminal";
const String kOptionTerminalPersistent = "terminal-persistent";
const String kOptionEnableTunnel = "enable-tunnel";
const String kOptionEnableRemoteRestart = "enable-remote-restart";
const String kOptionEnableBlockInput = "enable-block-input";
const String kOptionEnablePrivacyMode = "enable-privacy-mode";
const String kOptionEnablePermChangeInAcceptWindow =
    "enable-perm-change-in-accept-window";
const String kOptionAllowRemoteConfigModification =
    "allow-remote-config-modification";
const String kOptionVerificationMethod = "verification-method";
const String kOptionApproveMode = "approve-mode";
// The legacy code spelled this key inline at each call site.
const String kOptionTemporaryPasswordLength = "temporary-password-length";
const String kOptionAllowNumericOneTimePassword =
    "allow-numeric-one-time-password";
const String kOptionCollapseToolbar = "collapse_toolbar";
const String kOptionHideToolbar = "hide-toolbar";
const String kOptionShowRemoteCursor = "show_remote_cursor";
const String kOptionFollowRemoteCursor = "follow_remote_cursor";
const String kOptionFollowRemoteWindow = "follow_remote_window";
const String kOptionZoomCursor = "zoom-cursor";
const String kOptionShowQualityMonitor = "show_quality_monitor";
const String kOptionDisableAudio = "disable_audio";
const String kOptionEnableFileCopyPaste = "enable-file-copy-paste";
// "Settings -> Display -> Other default options"
const String kOptionDisableClipboard = "disable_clipboard";
const String kOptionLockAfterSessionEnd = "lock_after_session_end";
const String kOptionPrivacyMode = "privacy_mode";
const String kOptionTouchMode = "touch-mode";
const String kOptionI444 = "i444";
const String kOptionSwapLeftRightMouse = "swap-left-right-mouse";
// Session-scoped key from the legacy consts; the core spells it with
// underscores.
const String kKeyReverseMouseWheel = "reverse_mouse_wheel";
const String kOptionCodecPreference = "codec-preference";
const String kOptionRemoteMenubarDragLeft = "remote-menubar-drag-left";
const String kOptionRemoteMenubarDragRight = "remote-menubar-drag-right";
const String kOptionRemoteMenubarEdge = "remote-menubar-edge";
const String kOptionRemoteMenubarFraction = "remote-menubar-frac";
const String kOptionAllowMultiEdgeToolbarDock =
    "allow-multi-edge-toolbar-dock";
const String kOptionHideAbTagsPanel = "hideAbTagsPanel";
const String kOptionRemoteMenubarState = "remoteMenubarState";
const String kOptionPeerSorting = "peer-sorting";
const String kOptionPeerTabIndex = "peer-tab-index";
const String kOptionPeerTabOrder = "peer-tab-order";
const String kOptionPeerTabVisible = "peer-tab-visible";
const String kOptionPeerCardUiType = "peer-card-ui-type";
const String kOptionCurrentAbName = "current-ab-name";
const String kOptionEnableConfirmClosingTabs = "enable-confirm-closing-tabs";
const String kOptionAllowAlwaysSoftwareRender = "allow-always-software-render";
const String kOptionEnableCheckUpdate = "enable-check-update";
const String kOptionAllowAutoUpdate = "allow-auto-update";
const String kOptionAllowLinuxHeadless = "allow-linux-headless";
const String kOptionAllowRemoveWallpaper = "allow-remove-wallpaper";
const String kOptionStopService = "stop-service";
const String kOptionDirectxCapture = "enable-directx-capture";
const String kOptionAllowRemoteCmModification = "allow-remote-cm-modification";
const String kOptionEnableUdpPunch = "enable-udp-punch";
const String kOptionEnableIpv6Punch = "enable-ipv6-punch";
const String kOptionEnableTrustedDevices = "enable-trusted-devices";
const String kOptionShowVirtualMouse = "show-virtual-mouse";
const String kOptionVirtualMouseScale = "virtual-mouse-scale";
const String kOptionShowVirtualJoystick = "show-virtual-joystick";
const String kOptionAllowAskForNoteAtEndOfConnection = "allow-ask-for-note";
const String kOptionAllowMonitorSwitchMainToolbar = "allow-monitor-switch-main-toolbar";
const String kOptionAllowMonitorSwitchMinToolbar = "allow-monitor-switch-min-toolbar";
const String kOptionEnableShowTerminalExtraKeys = "enable-show-terminal-extra-keys";
const String kOptionShowTerminalCtrlKeys = "show-terminal-extra-ctrl-keys";

// network options
const String kOptionAllowWebSocket = "allow-websocket";
const String kOptionAllowInsecureTLSFallback = "allow-insecure-tls-fallback";
const String kOptionDisableUdp = "disable-udp";
const String kOptionEnableFlutterHttpOnRust = "enable-flutter-http-on-rust";

/// Not a stored option. A custom client pins this name to lock the proxy
/// dialog, so it is only ever passed to `mainIsOptionFixed`.
const String kOptionProxyUrl = "proxy-url";

// builtin options
const String kOptionHideServerSetting = "hide-server-settings";
const String kOptionHideProxySetting = "hide-proxy-settings";
const String kOptionHideWebSocketSetting = "hide-websocket-settings";
const String kOptionHideStopService = "hide-stop-service";
const String kOptionHideRemotePrinterSetting = "hide-remote-printer-settings";
const String kOptionHideSecuritySetting = "hide-security-settings";
const String kOptionHideNetworkSetting = "hide-network-settings";
const String kOptionRemovePresetPasswordWarning =
    "remove-preset-password-warning";
const String kOptionDisableChangePermanentPassword =
    "disable-change-permanent-password";
const String kOptionDisableChangeId = "disable-change-id";
const String kOptionDisableUnlockPin = "disable-unlock-pin";
const kHideUsernameOnCard = "hide-username-on-card";
const String kOptionHideHelpCards = "hide-help-cards";
const String kOptionAllowDeepLinkPassword = "allow-deep-link-password";
const String kOptionAllowDeepLinkServerSettings =
    "allow-deep-link-server-settings";

const String kOptionToggleViewOnly = "view-only";
const String kOptionToggleShowMyCursor = "show-my-cursor";

const String kOptionDisableFloatingWindow = "disable-floating-window";

const String kOptionKeepScreenOn = "keep-screen-on";

const String kOptionKeepAwakeDuringIncomingSessions = "keep-awake-during-incoming-sessions";
const String kOptionKeepAwakeDuringOutgoingSessions = "keep-awake-during-outgoing-sessions";

const String kOptionShowMobileAction = "showMobileActions";


// trackpad speed
const String kKeyTrackpadSpeed = 'trackpad-speed';
const int kMinTrackpadSpeed = 10;
const int kDefaultTrackpadSpeed = 100;
const int kMaxTrackpadSpeed = 1000;

// printer
// incomming (should be incoming) is kept, because change it will break the previous setting.
const String kKeyPrinterIncomingJobAction = 'printer-incomming-job-action';
const String kValuePrinterIncomingJobDismiss = 'dismiss';
const String kValuePrinterIncomingJobDefault = '';
const String kValuePrinterIncomingJobSelected = 'selected';
const String kKeyPrinterSelected = 'printer-selected-name';
const String kKeyPrinterSave = 'allow-printer-dialog-save';
const String kKeyPrinterAllowAutoPrint = 'allow-printer-auto-print';

// custom scale
// Scale custom related constants
const String kCustomScalePercentKey =
    'custom_scale_percent'; // Flutter option key for storing custom scale percent (integer 5-1000)
const int kScaleCustomMinPercent = 5;
const int kScaleCustomPivotPercent = 100; // 100% should be at 1/3 of track
const int kScaleCustomMaxPercent = 1000;
const double kScaleCustomPivotPos = 1.0 / 3.0; // first 1/3 → up to 100%
const double kScaleCustomDetentEpsilon =
    0.006; // snap range around pivot (~0.6%)
const Duration kDebounceCustomScaleDuration = Duration(milliseconds: 300);

// display / view style values
/// [kRemoteViewStyleOriginal] Show remote image without scaling.
const kRemoteViewStyleOriginal = 'original';

/// [kRemoteViewStyleAdaptive] Show remote image scaling by ratio factor.
const kRemoteViewStyleAdaptive = 'adaptive';

/// [kRemoteViewStyleCustom] Show remote image at a user-defined scale percent.
const kRemoteViewStyleCustom = 'custom';

/// [kRemoteScrollStyleAuto] Scroll image auto by position.
const kRemoteScrollStyleAuto = 'scrollauto';

/// [kRemoteScrollStyleBar] Scroll image with scroll bar.
const kRemoteScrollStyleBar = 'scrollbar';

/// [kRemoteScrollStyleEdge] Scroll image auto at edges.
const kRemoteScrollStyleEdge = 'scrolledge';

/// [kScrollModeDefault] Mouse or touchpad, the default scroll mode.
const kScrollModeDefault = 'default';

/// [kScrollModeReverse] Mouse or touchpad, the reverse scroll mode.
const kScrollModeReverse = 'reverse';

/// [kRemoteImageQualityBest] Best image quality.
const kRemoteImageQualityBest = 'best';

/// [kRemoteImageQualityBalanced] Balanced image quality, mid performance.
const kRemoteImageQualityBalanced = 'balanced';

/// [kRemoteImageQualityLow] Low image quality, better performance.
const kRemoteImageQualityLow = 'low';

/// [kRemoteImageQualityCustom] Custom image quality.
const kRemoteImageQualityCustom = 'custom';

