"""Render the 物语 「轻」 icon and its platform resources.

Requires Pillow and fontTools. Pass --font to use a local Noto Sans SC font.
The checked-in SVG contains outlines, so the shipped app needs no extra font.
"""
import argparse
import json
from io import BytesIO
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024
INK = '#ff2d55'
DARK = '#1c1c1e'
GLYPH = '轻'
GLYPH_SIZE = 620
RADIUS = 224


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--font', type=Path,
                        default=Path('C:/Windows/Fonts/NotoSansSC-VF.ttf'))
    args = parser.parse_args()
    font = TTFont(args.font)
    if 'fvar' in font:
        font = instantiateVariableFont(font, {'wght': 900}, inplace=False)

    write_svg(font)
    mask = glyph_mask(font)

    foreground = Image.new('RGBA', (SIZE, SIZE), INK)
    foreground.putalpha(mask)
    square = Image.new('RGB', (SIZE, SIZE), 'white')
    square.paste(foreground, mask=mask)
    corners = Image.new('L', (SIZE, SIZE))
    ImageDraw.Draw(corners).rounded_rectangle(
        (0, 0, SIZE - 1, SIZE - 1), radius=RADIUS, fill=255)
    rounded = square.convert('RGBA')
    rounded.putalpha(corners)
    circle_mask = Image.new('L', (SIZE, SIZE))
    ImageDraw.Draw(circle_mask).ellipse((0, 0, SIZE - 1, SIZE - 1), fill=255)
    circle = square.convert('RGBA')
    circle.putalpha(circle_mask)
    monochrome = Image.new('RGBA', (SIZE, SIZE), 'black')
    monochrome.putalpha(mask)

    save(rounded, 'assets/branding/logo_rounded.png', (512, 512))

    # Android: legacy launcher bitmaps plus an adaptive icon (white background, inset glyph).
    res = 'android/app/src/main/res'
    densities = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    for density, px in densities.items():
        folder = ROOT / res / f'mipmap-{density}'
        for stale in folder.glob('ic_launcher*'):
            stale.unlink()
        save(rounded, f'{res}/mipmap-{density}/ic_launcher.png', (px, px))
        save(circle, f'{res}/mipmap-{density}/ic_launcher_round.png', (px, px))
    save(foreground, f'{res}/drawable-nodpi/ic_launcher_foreground.png', (432, 432))
    save(monochrome, f'{res}/drawable-nodpi/ic_launcher_monochrome.png', (432, 432))
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground>\n'
        '        <inset android:drawable="@drawable/ic_launcher_foreground" android:inset="12%" />\n'
        '    </foreground>\n'
        '    <monochrome>\n'
        '        <inset android:drawable="@drawable/ic_launcher_monochrome" android:inset="12%" />\n'
        '    </monochrome>\n'
        '</adaptive-icon>\n'
    )
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        (ROOT / res / 'mipmap-anydpi-v26' / name).write_text(adaptive, encoding='utf-8')
    (ROOT / res / 'values/ic_launcher_background.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">#FFFFFF</color>\n</resources>\n',
        encoding='utf-8')

    # iOS: one 1024 icon each for the light, dark and tinted appearances.
    icons = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    for stale in icons.glob('*.png'):
        stale.unlink()
    dark = Image.new('RGB', (SIZE, SIZE), DARK)
    dark.paste(foreground, mask=mask)
    tinted = Image.new('RGB', (SIZE, SIZE), 'black')
    tinted.paste(Image.new('RGB', (SIZE, SIZE), 'white'), mask=mask)
    square.save(icons / 'monogatari.png')
    dark.save(icons / 'monogatari-dark.png')
    tinted.save(icons / 'monogatari-tinted.png')
    entry = {'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}
    contents = {
        'images': [
            {**entry, 'filename': 'monogatari.png'},
            {'appearances': [{'appearance': 'luminosity', 'value': 'dark'}],
             **entry, 'filename': 'monogatari-dark.png'},
            {'appearances': [{'appearance': 'luminosity', 'value': 'tinted'}],
             **entry, 'filename': 'monogatari-tinted.png'},
        ],
        'info': {'author': 'xcode', 'version': 1},
    }
    (icons / 'Contents.json').write_text(json.dumps(contents, indent=2) + '\n',
                                         encoding='utf-8')

    # Windows: a multi-size icon for the executable and the window.
    ico = ROOT / 'windows/runner/resources/app_icon.ico'
    rounded.save(ico, sizes=[(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)])
    print('Created the outlined SVG and Android, iOS and Windows icons.')


def write_svg(font):
    glyph_set = font.getGlyphSet()
    glyph = glyph_set[font.getBestCmap()[ord(GLYPH)]]
    bounds_pen = BoundsPen(glyph_set)
    glyph.draw(bounds_pen)
    x0, y0, x1, y1 = bounds_pen.bounds
    scale = GLYPH_SIZE / max(x1 - x0, y1 - y0)
    tx = SIZE / 2 - scale * (x0 + x1) / 2
    ty = SIZE / 2 + scale * (y0 + y1) / 2
    path_pen = SVGPathPen(glyph_set)
    glyph.draw(path_pen)
    branding = ROOT / 'assets/branding'
    branding.mkdir(parents=True, exist_ok=True)
    (branding / 'monogatari.svg').write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">\n'
        f'  <title>物语 / Monogatari — {GLYPH}</title>\n'
        '  <rect width="1024" height="1024" fill="#fff"/>\n'
        f'  <path fill="{INK}" transform="matrix({scale:.8f} 0 0 {-scale:.8f} '
        f'{tx:.8f} {ty:.8f})" d="{path_pen.getCommands()}"/>\n</svg>\n',
        encoding='utf-8',
    )


def glyph_mask(font):
    data = BytesIO()
    font.save(data)
    font_bytes = data.getvalue()
    oversample = 4
    face = ImageFont.truetype(BytesIO(font_bytes), SIZE * oversample)
    box = face.getbbox(GLYPH)
    font_size = round(SIZE * oversample * GLYPH_SIZE * oversample /
                      max(box[2] - box[0], box[3] - box[1]))
    face = ImageFont.truetype(BytesIO(font_bytes), font_size)
    box = face.getbbox(GLYPH)
    mask = Image.new('L', (SIZE * oversample,) * 2)
    ImageDraw.Draw(mask).text(
        ((SIZE * oversample - box[2] + box[0]) / 2 - box[0],
         (SIZE * oversample - box[3] + box[1]) / 2 - box[1]),
        GLYPH, font=face, fill=255,
    )
    return mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def save(image, relative, size=None):
    destination = ROOT / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if size is not None:
        image = image.resize(size, Image.Resampling.LANCZOS)
    image.save(destination)


if __name__ == '__main__':
    main()
