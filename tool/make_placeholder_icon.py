"""Generates the PLACEHOLDER app icon and splash art (a chat bubble on the
tenant's primary colour). Replace assets/branding/*.png with real artwork,
then re-run:

    dart run flutter_launcher_icons
    dart run flutter_native_splash:create
"""
from PIL import Image, ImageDraw

BLUE = (0x1A, 0x56, 0xA0, 255)
WHITE = (255, 255, 255, 255)
S = 4  # supersampling factor for smooth edges


def bubble(size: int, scale: float, background) -> Image.Image:
    """A speech bubble with three dots, centred, `scale` of the canvas wide."""
    n = size * S
    img = Image.new("RGBA", (n, n), background)
    d = ImageDraw.Draw(img)
    w = n * scale
    h = w * 0.72
    x0, y0 = (n - w) / 2, (n - h) / 2 - w * 0.06
    x1, y1 = x0 + w, y0 + h
    d.rounded_rectangle((x0, y0, x1, y1), radius=h * 0.3, fill=WHITE)
    # Tail, bottom-left.
    d.polygon(
        [(x0 + w * 0.16, y1 - h * 0.3), (x0 + w * 0.16, y1 + w * 0.2), (x0 + w * 0.4, y1 - h * 0.05)],
        fill=WHITE,
    )
    r = w * 0.065
    cy = (y0 + y1) / 2
    for i in (-1, 0, 1):
        cx = n / 2 + i * w * 0.22
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=BLUE)
    return img.resize((size, size), Image.LANCZOS)


out = "assets/branding/"
bubble(1024, 0.56, BLUE).convert("RGB").save(out + "icon.png")
# Adaptive-icon / Android 12 splash foreground: art inside the central safe zone.
bubble(1024, 0.40, (0, 0, 0, 0)).save(out + "icon_foreground.png")
bubble(512, 0.80, (0, 0, 0, 0)).save(out + "splash.png")
print("wrote icon.png, icon_foreground.png, splash.png")
