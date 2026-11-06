"""Generate desktop launcher icons. Requires Pillow (build-time only)."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SIZE = 2048
image = Image.new('RGBA', (SIZE, SIZE))
draw = ImageDraw.Draw(image)
# Leave transparent margins so the macOS icon matches neighboring app sizes.
draw.rounded_rectangle((112, 112, 1936, 1936), radius=410, fill='#1264D8')
# A remote monitor, with two opposing arrows denoting the connection.
draw.rounded_rectangle((420, 470, 1628, 1370), radius=120, fill='#F2F8FF')
draw.rounded_rectangle((490, 540, 1558, 1250), radius=55, fill='#123B73')
draw.rounded_rectangle((934, 1330, 1114, 1550), radius=24, fill='#F2F8FF')
draw.rounded_rectangle((740, 1510, 1308, 1590), radius=40, fill='#F2F8FF')
draw.line((720, 790, 1310, 790), fill='#FFFFFF', width=76)
draw.polygon([(1310, 665), (1440, 790), (1310, 915)], fill='#FFFFFF')
draw.line((738, 1030, 1328, 1030), fill='#5BCEFF', width=76)
draw.polygon([(738, 905), (608, 1030), (738, 1155)], fill='#5BCEFF')
image = image.resize((1024, 1024), Image.Resampling.LANCZOS)
image.save(ROOT / 'res' / 'managed-app-icon.png')
image.save(ROOT / 'flutter/windows/runner/resources/app_icon.ico',
           sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
image.save(ROOT / 'flutter/macos/Runner/AppIcon.icns')
print('Generated PNG master, Windows ICO and macOS ICNS')
