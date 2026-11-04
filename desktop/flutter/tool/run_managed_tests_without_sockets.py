#!/usr/bin/env python3
"""Run the real managed Flutter tests with cached tooling and no VM-service socket.

Fallback for environments denying loopback bind; prefer `flutter test` normally.
Requires the project's existing package_config and Flutter SDK cache. No downloads,
SDK writes, native bridge, user Keychain, or credential configuration are used.
"""
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urljoin

project = Path(__file__).resolve().parents[1]
flutter = shutil.which("flutter")
if not flutter:
    sys.exit("flutter is not on PATH")
sdk = Path(flutter).resolve().parents[1]
cache = sdk / "bin/cache"
arch = "arm64" if platform.machine() in ("arm64", "aarch64") else "x64"
engine = cache / "artifacts/engine" / ("darwin-" + arch if sys.platform == "darwin" else "linux-" + arch)
if not (engine / "flutter_tester").exists():
    # A cached Intel SDK can run under Rosetta on an Apple Silicon host.
    prefix = "darwin-" if sys.platform == "darwin" else "linux-"
    candidates = list((cache / "artifacts/engine").glob(prefix + "*/flutter_tester"))
    if len(candidates) != 1:
        sys.exit("No unambiguous cached flutter_tester; run flutter precache outside this restricted environment")
    engine = candidates[0].parent
tests = ["managed_status_card_test.dart", "integration/managed_client_adapter_test.dart", "integration/workspace_view_model_test.dart"]
with tempfile.TemporaryDirectory(prefix="managed-flutter-") as temp:
    work = Path(temp)
    packages = {}
    for source in [sdk / "packages/flutter_tools/.dart_tool/package_config.json", project / ".dart_tool/package_config.json"]:
        for package in json.loads(source.read_text())["packages"]:
            package["rootUri"] = urljoin(source.as_uri(), package["rootUri"])
            packages[package["name"]] = package
    config = work / "package_config.json"
    config.write_text(json.dumps({"configVersion": 2, "packages": list(packages.values())}))
    runner = work / "runner.dart"
    runner.write_text("\n".join([
        "import 'dart:io';",
        "import 'package:flutter_test/flutter_test.dart';",
        "import 'package:test_core/src/direct_run.dart';",
        *[f"import '{(project / 'test' / test).as_uri()}' as test{i};" for i, test in enumerate(tests)],
        "Future<void> main() async {",
        "  AutomatedTestWidgetsFlutterBinding.ensureInitialized();",
        "  final ok = await directRunTests(() { " + " ".join(f"test{i}.main();" for i in range(len(tests))) + " });",
        "  if (ok) print('MANAGED_FLUTTER_TESTS_PASS');",
        "  exit(ok ? 0 : 1);",
        "}",
    ]))
    kernel = work / "runner.dill"
    compile_result = subprocess.run([
        str(cache / "dart-sdk/bin/dartaotruntime"),
        str(cache / "dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot"),
        "--sdk-root", str(cache / "artifacts/engine/common/flutter_patched_sdk"),
        "--target=flutter", "--packages", str(config), "--output-dill", str(kernel), str(runner),
    ], cwd=project, text=True, capture_output=True)
    output = compile_result.stdout + compile_result.stderr
    if compile_result.returncode or not kernel.exists() or not re.search(r"runner\.dill 0\s*$", compile_result.stdout):
        print(output)
        sys.exit(1)
    result = subprocess.run([
        str(engine / "flutter_tester"), "--disable-vm-service", "--non-interactive",
        "--icu-data-file-path=" + str(engine / "icudtl.dat"), str(kernel),
    ], cwd=project, env={**os.environ, "FLUTTER_TEST": "true"}, text=True, capture_output=True)
    output = result.stdout + result.stderr
    print(output, end="")
    sys.exit(0 if result.returncode == 0 and "MANAGED_FLUTTER_TESTS_PASS" in output else 1)
