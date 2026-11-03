import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';

import 'package:flutter_hbb/features/common/aurora_surface.dart';
import 'package:flutter_hbb/features/workspace/settings_view_model.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';

/// Reads a server configuration from a QR code.
///
/// Ported from `ScanPage` in `flutter_legacy/lib/mobile/pages/scan_page.dart`.
/// A camera picks up every code in view, so a code that is not a RustDesk
/// configuration is reported rather than written over the working one.
class ScanConfigPage extends StatefulWidget {
  const ScanConfigPage({super.key, this.settings, this.onScanned});

  /// Injectable for tests.
  final SettingsViewModel? settings;

  /// Called with a scanned configuration instead of applying it. Tests use
  /// this; the page applies it itself otherwise.
  final ValueChanged<ServerConfig>? onScanned;

  @override
  State<ScanConfigPage> createState() => ScanConfigPageState();
}

class ScanConfigPageState extends State<ScanConfigPage> {
  final _qrKey = GlobalKey(debugLabel: 'qr');

  QRViewController? _controller;
  StreamSubscription<Barcode>? _scans;

  ServerConfig? _found;
  String? _error;
  var _saving = false;

  SettingsViewModel get _settings =>
      widget.settings ?? SettingsViewModel();

  @override
  void reassemble() {
    super.reassemble();
    // Android loses the camera surface across a hot reload; iOS keeps it and
    // needs a resume instead.
    if (isAndroid) {
      _controller?.pauseCamera();
    } else {
      _controller?.resumeCamera();
    }
  }

  @override
  void dispose() {
    _scans?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _onViewCreated(QRViewController controller) {
    _controller = controller;
    _scans = controller.scannedDataStream.listen((scan) {
      final code = scan.code;
      if (code == null) return;
      handleScan(code);
    });
  }

  /// Act on one scanned code. Exposed so a test can drive it without a camera.
  @visibleForTesting
  void handleScan(String code) {
    // Stop at the first configuration; leaving the stream running would fire
    // again on the same code every frame it stays in view.
    if (_found != null) return;

    final config = ServerConfig.fromQrCode(code);
    if (config == null) {
      setState(() => _error = 'That code is not a RustDesk configuration.');
      return;
    }
    unawaited(_controller?.pauseCamera());
    setState(() {
      _found = config;
      _error = null;
    });
  }

  Future<void> _apply() async {
    final config = _found;
    if (config == null) return;
    setState(() => _saving = true);
    if (widget.onScanned != null) {
      widget.onScanned!(config);
    } else {
      await _settings.setServerConfig(config);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop(config);
  }

  void _resume() {
    setState(() {
      _found = null;
      _error = null;
    });
    unawaited(_controller?.resumeCamera());
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(
            middle: Text('Scan a configuration')),
        child: SafeArea(
          child: Column(children: [
            Expanded(
              child: isMobile
                  ? QRView(key: _qrKey, onQRViewCreated: _onViewCreated)
                  // Without a camera there is nothing to show; saying so beats
                  // a black rectangle.
                  : const _NoCamera(),
            ),
            _ScanResult(
                config: _found,
                error: _error,
                saving: _saving,
                onApply: _apply,
                onScanAgain: _resume),
          ]),
        ),
      );
}

class _NoCamera extends StatelessWidget {
  const _NoCamera();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.cameraOff, size: 22),
          SizedBox(height: 9),
          Text('This device has no camera to scan with.',
              style: TextStyle(fontSize: 12)),
        ]),
      );
}

/// What was scanned, and what to do with it.
class _ScanResult extends StatelessWidget {
  const _ScanResult(
      {required this.config,
      required this.error,
      required this.saving,
      required this.onApply,
      required this.onScanAgain});

  final ServerConfig? config;
  final String? error;
  final bool saving;
  final VoidCallback onApply;
  final VoidCallback onScanAgain;

  @override
  Widget build(BuildContext context) {
    final scanned = config;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: panelDecoration(context),
      margin: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (scanned == null) ...[
          Text(
              error ??
                  'Point the camera at the configuration code from your '
                      'server.',
              style: TextStyle(
                  fontSize: 12,
                  color: error == null
                      ? null
                      : CupertinoColors.systemRed)),
        ] else ...[
          const Text('Configuration found',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          // Show what will change before it is written: a wrong server makes
          // this client unreachable, and it is not obvious afterwards.
          _Field(label: 'ID server', value: scanned.idServer),
          _Field(label: 'Relay server', value: scanned.relayServer),
          _Field(label: 'API server', value: scanned.apiServer),
          _Field(label: 'Key', value: scanned.key),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 10),
                onPressed: saving ? null : onScanAgain,
                child: const Text('Scan again',
                    style: TextStyle(fontSize: 13)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CupertinoButton.filled(
                padding: const EdgeInsets.symmetric(vertical: 10),
                borderRadius: BorderRadius.circular(9),
                onPressed: saving ? null : onApply,
                child: Text(saving ? 'Saving…' : 'Use this server',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
              width: 96,
              child: Text(label, style: const TextStyle(fontSize: 11))),
          Expanded(
              child: Text(value.isEmpty ? 'Not set' : value,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600))),
        ]),
      );
}
