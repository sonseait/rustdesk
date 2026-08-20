import 'package:flutter/cupertino.dart';
import 'package:flutter_hbb/features/workspace/settings_view_model.dart';
import 'package:flutter_hbb/features/workspace/workspace_page.dart';
import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/routing/window_frame_keeper.dart';

class AuroraApp extends StatefulWidget {
  const AuroraApp({
    super.key,
    this.home,
    this.onReady,
    this.initialSettingsTab,
  });

  /// The surface to show. Defaults to the workspace; a session window passes
  /// its own.
  final Widget? home;

  /// Run once after the first frame, for window setup that must wait until
  /// the surface exists.
  final Future<void> Function()? onReady;

  /// Open straight to a settings page instead of the workspace.
  final SettingsTab? initialSettingsTab;

  @override
  State<AuroraApp> createState() => _AuroraAppState();
}

class _AuroraAppState extends State<AuroraApp> {
  Brightness _brightness = Brightness.light;

  @override
  void initState() {
    super.initState();
    final onReady = widget.onReady;
    if (onReady != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onReady());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _brightness == Brightness.dark;
    return CupertinoApp(
      title: 'Aurora Remote',
      debugShowCheckedModeBanner: false,
      theme: CupertinoThemeData(
        brightness: _brightness,
        primaryColor:
            isDark ? const Color(0xFFFFB294) : const Color(0xFFA24C31),
        scaffoldBackgroundColor:
            isDark ? const Color(0xFF181210) : const Color(0xFFFFF9F5),
        textTheme: CupertinoTextThemeData(
          textStyle: TextStyle(
            color: isDark ? const Color(0xFFF6E9E2) : const Color(0xFF2A1A15),
            fontSize: 14,
          ),
          navTitleTextStyle: TextStyle(
            color: isDark ? const Color(0xFFF6E9E2) : const Color(0xFF2A1A15),
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      home: widget.home ??
          // The main window keeps its own frame; a session window wraps its
          // own surface, because only it knows which peer it serves.
          WindowFrameKeeper(
            type: WindowType.Main,
            child: WorkspacePage(
              brightness: _brightness,
              onBrightnessChanged: (brightness) =>
                  setState(() => _brightness = brightness),
              initialSettingsTab: widget.initialSettingsTab,
            ),
          ),
    );
  }
}
