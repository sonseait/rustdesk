import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';
import 'package:flutter_hbb/integration/options/option_repository.dart';

/// What to do with a print job that arrives from a remote session.
///
/// The values are the strings the core already persists under
/// [kKeyPrinterIncomingJobAction]; renaming one would silently reset a user's
/// choice to the default.
enum IncomingJobAction {
  /// Throw the job away.
  dismiss(kValuePrinterIncomingJobDismiss),

  /// Send it to whichever printer the OS calls the default.
  useDefault(kValuePrinterIncomingJobDefault),

  /// Send it to a printer chosen here.
  useSelected(kValuePrinterIncomingJobSelected);

  const IncomingJobAction(this.value);

  final String value;

  static IncomingJobAction fromValue(String value) {
    for (final action in values) {
      if (action.value == value) return action;
    }
    // The legacy loader treats anything unrecognised as the default rather
    // than dropping jobs.
    return IncomingJobAction.useDefault;
  }
}

/// Why outgoing printing is or is not available on this device.
enum OutgoingPrinterState {
  /// The OS cannot host the printer driver at all.
  unsupportedOs,

  /// RustDesk is running portable; the driver needs an installed client.
  clientNotInstalled,

  /// The client is installed but the virtual printer is not.
  printerNotInstalled,

  /// The virtual printer is installed and usable.
  ready,
}

/// The incoming print job settings, read together.
///
/// Ported from `PrinterOptions` in `flutter_legacy/lib/models/printer_model
/// .dart`, including its repair step: a saved printer that no longer exists
/// falls back to the default printer rather than silently dropping jobs.
@immutable
class PrinterOptions {
  const PrinterOptions({
    required this.action,
    required this.printerNames,
    required this.printerName,
    required this.autoPrint,
  });

  final IncomingJobAction action;

  /// The printers the OS reports, excluding RustDesk's own virtual printer.
  final List<String> printerNames;

  /// The printer chosen for [IncomingJobAction.useSelected]. Empty when none
  /// is chosen.
  final String printerName;

  /// Whether a job prints without asking first.
  final bool autoPrint;

  /// Auto-print is meaningless when jobs are dismissed.
  bool get canAutoPrint => action != IncomingJobAction.dismiss;

  /// Only a selected-printer setup picks a printer.
  bool get canSelectPrinter => action == IncomingJobAction.useSelected;
}

/// Remote printing: the outgoing virtual printer, and what to do with incoming
/// jobs.
class PrinterAdapter extends ChangeNotifier {
  PrinterAdapter({OptionRepository? options})
      : _options = options ?? OptionRepository.instance;

  static final PrinterAdapter instance = PrinterAdapter();

  final OptionRepository _options;

  /// Core `common` keys. These are read through `mainGetCommonSync` rather
  /// than the option store, so they are not option keys.
  static const String _keySupportsDriver = 'is-support-printer-driver';
  static const String _keyPrinterInstalled = 'is-printer-installed';
  static const String _keyInstallPrinter = 'install-printer';

  /// The core's event for the result of installing the virtual printer.
  static const String installEvent = 'install-printer-res';
  static const String _handlerName = 'aurora printer install';

  bool _registered = false;

  /// The core's message when installing the printer failed, else empty.
  String _installError = '';

  String get installError => _installError;

  // ------------------------------------------------------------- outgoing

  /// Whether this OS can host the virtual printer driver at all.
  bool get supportsDriver {
    try {
      return bind.mainGetCommonSync(key: _keySupportsDriver) == 'true';
    } catch (e) {
      debugPrint('failed to read the printer driver support: $e');
      return false;
    }
  }

  /// Whether the virtual printer is installed.
  bool get isPrinterInstalled {
    try {
      return bind.mainGetCommonSync(key: _keyPrinterInstalled) == 'true';
    } catch (e) {
      debugPrint('failed to read the printer install state: $e');
      return false;
    }
  }

  /// Whether RustDesk itself is installed, which the driver requires.
  bool get isClientInstalled {
    try {
      return bind.mainIsInstalled();
    } catch (e) {
      debugPrint('failed to read the client install state: $e');
      return false;
    }
  }

  OutgoingPrinterState get outgoingState {
    if (!supportsDriver) return OutgoingPrinterState.unsupportedOs;
    if (!isClientInstalled) return OutgoingPrinterState.clientNotInstalled;
    if (!isPrinterInstalled) return OutgoingPrinterState.printerNotInstalled;
    return OutgoingPrinterState.ready;
  }

  /// The product name, used for the virtual printer's own name.
  String get appName {
    try {
      return bind.mainGetAppNameSync();
    } catch (e) {
      debugPrint('failed to read the app name: $e');
      return 'RustDesk';
    }
  }

  /// Ask the core to install the virtual printer.
  ///
  /// The core answers on [installEvent] rather than returning, so this
  /// subscribes first and reports the outcome through [installError] and a
  /// notification.
  Future<void> installPrinter() async {
    _installError = '';
    if (!_registered) {
      platformFFI.registerEventHandler(
        installEvent,
        _handlerName,
        (evt) async {
          _installError =
              evt['success'] == true ? '' : (evt['msg']?.toString() ?? '');
          notifyListeners();
        },
        replace: true,
      );
      _registered = true;
    }
    try {
      await bind.mainSetCommon(key: _keyInstallPrinter, value: '');
    } catch (e) {
      debugPrint('failed to install the printer: $e');
      _installError = e.toString();
    }
    notifyListeners();
  }

  // ------------------------------------------------------------- incoming

  /// Whether the deployment hides remote printing entirely.
  bool get isHidden => _options.isRemotePrinterSettingHidden;

  /// The printers the OS reports.
  ///
  /// RustDesk's own virtual printer is left out: routing an incoming job back
  /// into it would loop.
  List<String> printerNames() {
    try {
      final payload = bind.mainGetPrinterNames();
      if (payload.isEmpty) return const [];
      final decoded = jsonDecode(payload);
      if (decoded is! List) return const [];
      final ownPrinter = '$appName Printer';
      return [
        for (final name in decoded)
          if (name.toString() != ownPrinter) name.toString()
      ];
    } catch (e) {
      debugPrint('failed to read the printer names: $e');
      return const [];
    }
  }

  /// The current settings, repairing a stale printer choice.
  ///
  /// When the chosen printer is gone, the legacy loader writes the default
  /// action back rather than leaving a setup that points at nothing.
  Future<PrinterOptions> options() async {
    final action = IncomingJobAction.fromValue(
        _options.getLocalString(kKeyPrinterIncomingJobAction));
    final names = printerNames();
    var selected = _options.getLocalString(kKeyPrinterSelected);
    var effective = action;

    if (!names.contains(selected) &&
        action == IncomingJobAction.useSelected) {
      effective = IncomingJobAction.useDefault;
      selected = names.isEmpty ? '' : names.first;
      await _options.setLocalString(
          kKeyPrinterIncomingJobAction, effective.value);
      await _options.setLocalString(kKeyPrinterSelected, selected);
    }

    return PrinterOptions(
      action: effective,
      printerNames: names,
      printerName: selected,
      autoPrint: _options.getLocalBool(kKeyPrinterAllowAutoPrint),
    );
  }

  Future<void> setAction(IncomingJobAction action) async {
    await _options.setLocalString(
        kKeyPrinterIncomingJobAction, action.value);
    notifyListeners();
  }

  Future<void> setPrinterName(String name) async {
    await _options.setLocalString(kKeyPrinterSelected, name);
    notifyListeners();
  }

  Future<void> setAutoPrint(bool enabled) async {
    await _options.setLocalBool(kKeyPrinterAllowAutoPrint, enabled);
    notifyListeners();
  }
}
