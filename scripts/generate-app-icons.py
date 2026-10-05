#!/usr/bin/env python3
"""미러의 개발용 AppIcon을 표준 Python만으로 재생성한다.

이 아이콘은 MirrorPalette의 accent/surface와 앱의 sun.max 표시를 참고한
임시 개발 자산이다. 사용자가 최종 브랜드나 출시 디자인을 승인한 결과가 아니다.
SF Symbols 원본을 복제하지 않고 원과 선분을 직접 그린다.

실행: python3 scripts/generate-app-icons.py
앱 빌드나 테스트를 실행하지 않는다. 색상 변경은 이 source와 MirrorPalette를 함께 검토한다.
"""
from pathlib import Path
import json
import math
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'Resources/AppAssets.xcassets'
ICONSET = CATALOG / 'AppIcon.appiconset'
ACCENT = (0x28, 0x66, 0x3C)
SURFACE = (0xF3, 0xF2, 0xEE)
INVERSE_SQRT_TWO = 1 / math.sqrt(2)


def coverage(distance, pixel_size):
    """원·선분의 signed distance를 한 pixel 폭으로 부드럽게 덮는다."""
    return min(1.0, max(0.0, 0.5 - distance / pixel_size))


def symbol_distance(x, y):
    circle = abs(math.hypot(x, y) - 148) - 24
    x, y = abs(x), abs(y)
    along, perpendicular = max(x, y), min(x, y)
    axis = math.hypot(perpendicular, max(228 - along, 0, along - 296)) - 24
    along = (x + y) * INVERSE_SQRT_TWO
    perpendicular = abs(x - y) * INVERSE_SQRT_TWO
    diagonal = math.hypot(perpendicular, max(228 - along, 0, along - 296)) - 24
    return min(circle, axis, diagonal)


def tile_distance(x, y):
    """Mac용 여백과 둥근 정사각형. iOS의 모서리는 OS가 처리한다."""
    corner_radius = 190
    qx, qy = abs(x) - (448 - corner_radius), abs(y) - (448 - corner_radius)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - corner_radius


def chunk(kind, data):
    checksum = zlib.crc32(kind + data) & 0xFFFFFFFF
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', checksum)


def render(size, mac):
    pixel_size = 1024 / size
    pixels = bytearray()
    for row in range(size):
        pixels.append(0)  # 각 scanline의 PNG filter: None
        y = (row + 0.5) * pixel_size - 512
        for column in range(size):
            x = (column + 0.5) * pixel_size - 512
            symbol = coverage(symbol_distance(x, y), pixel_size)
            pixels.extend(round(background + symbol * (foreground - background))
                          for background, foreground in zip(ACCENT, SURFACE))
            if mac:
                pixels.append(round(255 * coverage(tile_distance(x, y), pixel_size)))
    # iOS는 alpha channel 자체가 없는 RGB다. Mac은 둥근 tile 바깥의 투명도를 보존한다.
    header = struct.pack('!IIBBBBB', size, size, 8, 6 if mac else 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) +
            chunk(b'IDAT', zlib.compress(pixels, level=9)) + chunk(b'IEND', b''))


def main():
    ICONSET.mkdir(parents=True, exist_ok=True)
    info = {'author': 'xcode', 'version': 1}
    (CATALOG / 'Contents.json').write_text(json.dumps({'info': info}, indent=2) + '\n')
    ios_filename = 'DevelopmentAppIcon-iOS-1024.png'
    (ICONSET / ios_filename).write_bytes(render(1024, mac=False))
    images = [{'filename': ios_filename, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}]
    for size in (16, 32, 64, 128, 256, 512, 1024):
        (ICONSET / f'DevelopmentAppIcon-Mac-{size}.png').write_bytes(render(size, mac=True))
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            images.append({'filename': f'DevelopmentAppIcon-Mac-{points * scale}.png',
                           'idiom': 'mac', 'size': f'{points}x{points}', 'scale': f'{scale}x'})
    (ICONSET / 'Contents.json').write_text(json.dumps({'images': images, 'info': info}, indent=2) + '\n')
    print('개발용 AppIcon 생성: iOS RGB 1024, Mac RGBA 16·32·64·128·256·512·1024')


if __name__ == '__main__':
    main()
