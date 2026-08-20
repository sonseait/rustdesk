import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as path;
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';

/// Installer surface for a process launched with `--install`.
class InstallerPage extends StatefulWidget {
  const InstallerPage({super.key});

  @override
  State<InstallerPage> createState() => _InstallerPageState();
}

class _InstallerPageState extends State<InstallerPage> {
  late final TextEditingController _path;
  var _startMenu = true;
  var _desktopIcon = true;
  var _printer = false;
  var _installing = false;
  late final bool _canRunWithoutInstall;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(text: bind.installInstallPath());
    final options = _options();
    _startMenu = options['STARTMENUSHORTCUTS'] != '0';
    _desktopIcon = options['DESKTOPSHORTCUTS'] != '0';
    _printer = options['PRINTER'] == '1';
    _canRunWithoutInstall = bind.installShowRunWithoutInstall();
  }

  Map<String, dynamic> _options() {
    try {
      return Map<String, dynamic>.from(
          jsonDecode(bind.installInstallOptions()) as Map);
    } catch (_) {
      return const {};
    }
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _choosePath() async {
    final selected =
        await FilePicker.getDirectoryPath(initialDirectory: _path.text);
    if (selected == null) return;
    final appName = await bind.mainGetAppName();
    _path.text = path.join(selected, appName);
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    final options = [
      if (_startMenu) 'startmenu',
      if (_desktopIcon) 'desktopicon',
      if (_printer) 'printer',
    ].join(' ');
    try {
      await bind.installInstallMe(
          options: options.isEmpty ? '' : ' $options', path: _path.text);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar:
            const CupertinoNavigationBar(middle: Text('Installation')),
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const Text('Install RustDesk on this device.'),
            const SizedBox(height: 18),
            CupertinoTextField(controller: _path, readOnly: true),
            const SizedBox(height: 8),
            CupertinoButton(
                onPressed: _installing ? null : _choosePath,
                child: const Text('Change path')),
            CupertinoListSection.insetGrouped(children: [
              CupertinoListTile(
                  title: const Text('Create start menu shortcuts'),
                  trailing: CupertinoSwitch(
                      value: _startMenu,
                      onChanged: _installing
                          ? null
                          : (value) => setState(() => _startMenu = value))),
              CupertinoListTile(
                  title: const Text('Create desktop icon'),
                  trailing: CupertinoSwitch(
                      value: _desktopIcon,
                      onChanged: _installing
                          ? null
                          : (value) => setState(() => _desktopIcon = value))),
              CupertinoListTile(
                  title: const Text('Install RustDesk Printer'),
                  trailing: CupertinoSwitch(
                      value: _printer,
                      onChanged: _installing
                          ? null
                          : (value) => setState(() => _printer = value))),
            ]),
            const SizedBox(height: 12),
            CupertinoButton.filled(
                onPressed: _installing ? null : _install,
                child:
                    Text(_installing ? 'Installing...' : 'Accept and install')),
            if (_canRunWithoutInstall)
              CupertinoButton(
                  onPressed: _installing ? null : bind.installRunWithoutInstall,
                  child: const Text('Run without install')),
            CupertinoButton(
                onPressed: _installing ? null : windowManager.close,
                child: const Text('Cancel')),
          ]),
        ),
      );
}
