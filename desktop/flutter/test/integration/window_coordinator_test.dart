import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/integration/bridge/app_types.dart';
import 'package:flutter_hbb/integration/routing/window_coordinator.dart';

class TestCoordinator extends WindowCoordinator {
  @override
  Future<List<int>> getAllSubWindowIds() async => [2];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reconciliation removes destroyed windows but retains live windows', () async {
    final coordinator = TestCoordinator();
    coordinator.windowsOf(WindowType.RemoteDesktop).addAll([1, 2]);
    await coordinator.registerActiveWindow(1);
    await coordinator.registerActiveWindow(2);
    await coordinator.reconcileWindows();
    expect(coordinator.windowsOf(WindowType.RemoteDesktop), [2]);
    expect(coordinator.activeWindows, contains(2));
    expect(coordinator.activeWindows, isNot(contains(1)));
  });
}
