#!/usr/bin/env python3
"""Оформление окна DMG: фон со стрелкой и раскладка значков.

  dmg_style.py background <папка>        — рисует <папка>/.background/background.tiff (1x и 2x в одном файле)
  dmg_style.py layout <том> <приложение>  — пишет .DS_Store в смонтированный том: окно, значки 128 pt, позиции, фон

Раскладку Finder хранит в .DS_Store. Пишем его напрямую (`pip3 install ds_store mac_alias pillow`),
а не через AppleScript к Finder: не нужно разрешение «Автоматизация», результат всегда одинаковый.
Фон — ссылкой (alias) на файл внутри тома, поэтому .DS_Store пишется в уже смонтированный образ.
"""
import os
import subprocess
import sys
import tempfile

# Содержимое окна и значки — в пунктах; координаты значков — их центры от левого верхнего угла содержимого.
# Значки чуть выше середины: у кого в Finder включена строка пути, она закрывает низ окна.
WIDTH, HEIGHT = 560, 320
ICON_SIZE = 128
APP_POS = (150, 140)
APPLICATIONS_POS = (410, 140)
# Высоту окна Finder считает вместе с заголовком (32 pt на macOS 27), а начало — от низа экрана.
TITLEBAR = 32
WINDOW_ORIGIN = (400, 420)
FONT = "/System/Library/Fonts/SFNS.ttf"


def draw_background(scale):
    from PIL import Image, ImageDraw, ImageFont

    w, h = WIDTH * scale, HEIGHT * scale
    image = Image.new("RGB", (w, h))
    draw = ImageDraw.Draw(image)
    # Еле заметный вертикальный градиент — светлый, под чёрные подписи значков Finder.
    top, bottom = (250, 250, 252), (238, 239, 243)
    for y in range(h):
        t = y / (h - 1)
        draw.line([(0, y), (w, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))

    # Стрелка между значками, на высоте их центров.
    gray = (152, 152, 158)
    y = APP_POS[1] * scale
    x0 = (APP_POS[0] + ICON_SIZE // 2 + 22) * scale
    x1 = (APPLICATIONS_POS[0] - ICON_SIZE // 2 - 22) * scale
    head = 16 * scale
    draw.line([(x0, y), (x1 - head, y)], fill=gray, width=6 * scale)
    draw.ellipse([x0 - 3 * scale, y - 3 * scale, x0 + 3 * scale, y + 3 * scale], fill=gray)
    draw.polygon([(x1, y), (x1 - head - 2 * scale, y - 13 * scale), (x1 - head - 2 * scale, y + 13 * scale)], fill=gray)

    font = ImageFont.truetype(FONT, 15 * scale)
    try:
        font.set_variation_by_name("Medium")
    except (OSError, ValueError):
        pass
    text = "Drag here"
    left, _, right, _ = draw.textbbox((0, 0), text, font=font)
    draw.text(((x0 + x1) / 2 - (right - left) / 2, y - 40 * scale), text, font=font, fill=(128, 128, 134))
    return image


def make_background(folder):
    target = os.path.join(folder, ".background")
    os.makedirs(target, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        one, two = os.path.join(tmp, "bg.png"), os.path.join(tmp, "bg@2x.png")
        draw_background(1).save(one, dpi=(72, 72))
        draw_background(2).save(two, dpi=(144, 144))
        # Один TIFF с обоими размерами: на Retina Finder берёт второй.
        subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", os.path.join(target, "background.tiff")],
                       check=True, capture_output=True)


def write_layout(volume, app_name):
    from ds_store import DSStore
    from mac_alias import Alias

    background = Alias.for_file(os.path.join(volume, ".background", "background.tiff")).to_bytes()
    with DSStore.open(os.path.join(volume, ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = {
            "WindowBounds": "{{%d, %d}, {%d, %d}}" % (*WINDOW_ORIGIN, WIDTH, HEIGHT + TITLEBAR),
            "ShowToolbar": False, "ShowTabView": False, "ShowStatusBar": False, "ShowPathbar": False,
            "ShowSidebar": False, "ContainerShowSidebar": False, "SidebarWidth": 180, "PreviewPaneVisibility": False,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 2,  # картинка
            "backgroundImageAlias": background,
            "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
            "iconSize": float(ICON_SIZE), "textSize": 13.0, "labelOnBottom": True,
            "arrangeBy": "none", "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
            "showIconPreview": False, "showItemInfo": False, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
        }
        store[app_name]["Iloc"] = APP_POS
        store["Applications"]["Iloc"] = APPLICATIONS_POS


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "background":
        make_background(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "layout":
        write_layout(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
