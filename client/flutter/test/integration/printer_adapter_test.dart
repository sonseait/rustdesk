import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/adapters/printer_adapter.dart';
import 'package:flutter_hbb/integration/options/option_keys.dart';

void main() {
  group('IncomingJobAction', () {
    // These are the strings the core already persists. Renaming one silently
    // resets a user's choice, which for 'dismiss' means jobs start printing.
    test('uses the values the core stores', () {
      expect(IncomingJobAction.dismiss.value, kValuePrinterIncomingJobDismiss);
      expect(IncomingJobAction.useDefault.value, kValuePrinterIncomingJobDefault);
      expect(
          IncomingJobAction.useSelected.value, kValuePrinterIncomingJobSelected);
    });

    test('round-trips every stored value', () {
      for (final action in IncomingJobAction.values) {
        expect(IncomingJobAction.fromValue(action.value), action);
      }
    });

    test('an unknown value falls back to the default printer', () {
      // The legacy loader treats anything unrecognised as the default rather
      // than dropping the job.
      expect(IncomingJobAction.fromValue('something-else'),
          IncomingJobAction.useDefault);
    });
  });

  group('PrinterOptions', () {
    PrinterOptions optionsFor(IncomingJobAction action) => PrinterOptions(
          action: action,
          printerNames: const ['Office laser'],
          printerName: 'Office laser',
          autoPrint: false,
        );

    test('auto-print is meaningless when jobs are dismissed', () {
      expect(optionsFor(IncomingJobAction.dismiss).canAutoPrint, isFalse);
      expect(optionsFor(IncomingJobAction.useDefault).canAutoPrint, isTrue);
      expect(optionsFor(IncomingJobAction.useSelected).canAutoPrint, isTrue);
    });

    test('only a selected-printer setup picks a printer', () {
      expect(optionsFor(IncomingJobAction.useSelected).canSelectPrinter, isTrue);
      expect(optionsFor(IncomingJobAction.useDefault).canSelectPrinter, isFalse);
      expect(optionsFor(IncomingJobAction.dismiss).canSelectPrinter, isFalse);
    });
  });

  group('option keys', () {
    // The printer settings are per-install local options; these are the names
    // the core reads them back under.
    test('are the names the core stores', () {
      expect(kKeyPrinterIncomingJobAction, 'printer-incomming-job-action');
      expect(kKeyPrinterSelected, 'printer-selected-name');
      expect(kKeyPrinterAllowAutoPrint, 'allow-printer-auto-print');
      expect(kOptionEnableRemotePrinter, 'enable-remote-printer');
    });
  });
}
