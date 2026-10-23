"""Render App Store artwork from the simulator captures in raw/.

Requires Pillow. Run from the repository root with:
    python3 Design/AppStoreScreenshots/render.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
FONT = "/System/Library/Fonts/Avenir Next.ttc"
INK = "#15273B"


def font(size: int, weight: int = 0) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT, size, index=weight)


def background(size: tuple[int, int], top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    width, height = size
    gradient = Image.new("RGB", size)
    pixels = gradient.load()
    for y in range(height):
        t = y / (height - 1)
        colour = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        for x in range(width):
            pixels[x, y] = colour
    return gradient


def add_art(canvas: Image.Image, accent: str) -> None:
    layer = Image.new("RGBA", canvas.size)
    draw = ImageDraw.Draw(layer)
    w, h = canvas.size
    draw.ellipse((w * 0.62, -h * 0.16, w * 1.33, h * 0.33), fill=accent)
    draw.ellipse((-w * 0.35, h * 0.55, w * 0.36, h * 1.06), fill="#FFFFFF73")
    draw.ellipse((w * 0.75, h * 0.7, w * 1.2, h * 1.08), fill="#FFFFFF45")
    canvas.paste(Image.alpha_composite(canvas.convert("RGBA"), layer).convert("RGB"))


def place_capture(canvas: Image.Image, source: Path | Image.Image, box: tuple[int, int, int, int], radius: int) -> None:
    x, y, width, height = box
    screenshot = (Image.open(source) if isinstance(source, Path) else source).convert("RGB").resize((width, height), Image.Resampling.LANCZOS)
    mask = Image.new("L", (width, height))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width - 1, height - 1), radius=radius, fill=255)
    shadow = Image.new("RGBA", canvas.size)
    shadow_mask = Image.new("L", canvas.size)
    ImageDraw.Draw(shadow_mask).rounded_rectangle((x, y, x + width, y + height), radius=radius, fill=190)
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(35))
    shadow.paste((22, 28, 58, 90), (0, 0, canvas.width, canvas.height), shadow_mask)
    canvas.paste(Image.alpha_composite(canvas.convert("RGBA"), shadow).convert("RGB"))
    canvas.paste(screenshot, (x, y), mask)
    ImageDraw.Draw(canvas).rounded_rectangle((x, y, x + width - 1, y + height - 1), radius=radius, outline="#FFFFFFB0", width=3)


PHONE = [
    ("01-browse.png", "iphone-feed.png", "Browse Reddit\nyour way.", (198, 248, 253), (224, 207, 251), "#A5EBF5A0"),
    ("02-discussions.png", "iphone-detail.png", "Follow the whole\nconversation.", (228, 218, 255), (255, 210, 231), "#F8B6D6A0"),
    ("03-feeds.png", "iphone-feeds.png", "Your communities,\nyour feeds.", (255, 223, 229), (255, 226, 201), "#FFC3D1A0"),
    ("04-settings.png", "iphone-settings.png", "Make it feel\nlike yours.", (255, 238, 208), (255, 214, 231), "#FFD0ADA0"),
    ("05-save-media.png", "iphone-media-menu.png", "Save a whole gallery\nto Photos.", (218, 242, 255), (216, 217, 255), "#B8D8FFA0"),
]

IPAD = [
    ("01-browse.png", "ipad-feed.png", "Your communities,\nall in one place.", (198, 248, 253), (224, 207, 251), "#A5EBF5A0"),
    ("02-discussions.png", "ipad-detail.png", "Read posts beside\nyour feeds.", (228, 218, 255), (255, 210, 231), "#F8B6D6A0"),
]


def render_phone(spec: tuple) -> None:
    name, capture, headline, top, bottom, accent = spec
    canvas = background((1320, 2868), top, bottom)
    add_art(canvas, accent)
    ImageDraw.Draw(canvas).multiline_text((92, 130), headline, font=font(98), fill=INK, spacing=-10)
    place_capture(canvas, ROOT / "raw" / capture, (148, 510, 1024, 2225), 95)
    output = ROOT / "iPhone-6.9" / name
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, "PNG", optimize=True)


def render_duo(spec: tuple) -> None:
    name, capture, headline, top, bottom, accent = spec
    canvas = background((1398, 2034), top, bottom)
    add_art(canvas, accent)
    ImageDraw.Draw(canvas).multiline_text((96, 120), headline, font=font(92), fill=INK, spacing=-10)
    place_capture(canvas, ROOT / "raw" / capture.replace("iphone-", "duo-"), (189, 440, 1020, 1484), 60)
    output = ROOT / "iPhone-Duo-Closed" / name
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, "PNG", optimize=True)


def render_duo_open(spec: tuple) -> None:
    name, capture, headline, top, bottom, accent = spec
    canvas = background((2853, 2007), top, bottom)
    add_art(canvas, accent)
    ImageDraw.Draw(canvas).text((200, 120), headline.replace("\n", " "), font=font(120), fill=INK)
    place_capture(canvas, ROOT / "raw" / capture.replace("iphone-", "duo-open-"), (380, 390, 2093, 1472), 80)
    output = ROOT / "iPhone-Duo-Open" / name
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, "PNG", optimize=True)


def render_ipad(spec: tuple) -> None:
    name, capture, headline, top, bottom, accent = spec
    canvas = background((2064, 2752), top, bottom)
    add_art(canvas, accent)
    ImageDraw.Draw(canvas).multiline_text((136, 130), headline, font=font(105), fill=INK, spacing=-6)
    screenshot = Image.open(ROOT / "raw" / capture).crop((0, 55, 2064, 2650))
    place_capture(canvas, screenshot, (182, 500, 1700, 2137), 74)
    output = ROOT / "iPad-13" / name
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, "PNG", optimize=True)


if __name__ == "__main__":
    for item in PHONE:
        render_phone(item)
        render_duo(item)
    for index, item in enumerate(item for item in PHONE if item[0] != "03-feeds.png"):
        render_duo_open((f"{index + 1:02d}{item[0][2:]}",) + item[1:])
    for item in IPAD:
        render_ipad(item)
