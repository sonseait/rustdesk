"""Stage the verified, unmodified Amyuni driver and managed setup files."""
import argparse
import hashlib
from pathlib import Path
import shutil
import urllib.request
import zipfile
import io

URL = 'https://www.amyuni.com/downloads/usbmmidd_v2.zip'
SHA256 = '629b51e9944762bae73948171c65d09a79595cf4c771a82ebc003fbba5b24f51'


def stage_driver(data, destination):
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError('Amyuni archive SHA-256 mismatch')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for item in archive.infolist():
            path = Path(item.filename)
            if path.is_absolute() or '..' in path.parts or path.parts[0] != 'usbmmidd_v2':
                raise ValueError('Unsafe driver archive path')
        archive.extractall(destination)
    for name in ['License.txt', 'usbmmIdd.inf', 'usbmmidd.cat', 'deviceinstaller64.exe', 'x64/usbmmIdd.dll']:
        if not (destination / 'usbmmidd_v2' / name).is_file():
            raise ValueError('Incomplete driver package: ' + name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('release', type=Path)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    if not (args.release / 'rustdesk.exe').is_file():
        raise ValueError('Expected Flutter release directory containing rustdesk.exe')
    if args.archive:
        data = args.archive.read_bytes()
    else:
        with urllib.request.urlopen(URL, timeout=60) as response:
            data = response.read(16 * 1024 * 1024)
    stage_driver(data, args.release)
    source = Path(__file__).resolve().parents[2] / 'desktop' / 'res' / 'managed-setup'
    for name in ['Setup.cmd', 'Setup.ps1', 'SETUP.txt']:
        shutil.copy2(source / name, args.release / name)


if __name__ == '__main__':
    main()
