"""Packaging regression tests; real vendor ZIP is supplied explicitly."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('packager', Path(__file__).with_name('package-managed-windows.py'))
assert spec is not None and spec.loader is not None
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class DriverPackagingTests(unittest.TestCase):
    def test_rejects_changed_archive_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                packager.stage_driver(b'not a trusted driver', target)
            self.assertEqual(list(target.iterdir()), [])

    def test_real_vendor_archive_preserved(self):
        data = Path(os.environ['AMYUNI_TEST_ARCHIVE']).read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            packager.stage_driver(data, target)
            import io
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for item in archive.infolist():
                    if not item.is_dir():
                        self.assertEqual((target / item.filename).read_bytes(), archive.read(item))


if __name__ == '__main__':
    unittest.main()
