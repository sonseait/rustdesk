"""Source contract checks; does not replace compilation or Windows acceptance."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InstallerContract(unittest.TestCase):
    def test_native_setup_without_shell_scripts(self):
        source = (ROOT / 'desktop/res/managed-setup/managed-windows.iss').read_text()
        for retired in ['powershell.exe', 'Setup.ps1', 'cmd.exe']:
            self.assertNotIn(retired, source)
        for expected in ['--silent-install', 'enableidd 1', '2560,1440',
                         'SW_HIDE', 'ewWaitUntilTerminated', 'sc.exe',
                         'RegQueryDWordValue', 'LicenseFile=']:
            self.assertIn(expected, source)

    def test_release_does_not_ship_old_setup_scripts(self):
        source = (ROOT / '.github/scripts/package-managed-windows.py').read_text()
        self.assertNotIn("['Setup.cmd', 'Setup.ps1', 'SETUP.txt']", source)


if __name__ == '__main__':
    unittest.main()
