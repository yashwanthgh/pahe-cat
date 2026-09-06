"""Generate the Pahe Boy launcher icon.

Everything stays inside the inner ~78% of the canvas so iOS's rounded-rect
mask and Android's adaptive-icon circle mask never clip the artwork.
"""
from PIL import Image, ImageDraw, ImageFilter
import os

S = 1024
# A white plate with a warm-grey paw, matching the White Cat palette.
# A white paw on a white plate would vanish, so the paw carries the colour and
# the plate stays white — that also keeps the icon visible on dark wallpapers.
PLATE = (255, 255, 255)
PLATE_EDGE = (247, 245, 242)
PAW = (122, 112, 104)


def gradient(size, c1, c2):
    """Diagonal linear gradient, matching the app's theme direction."""
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size - 2)
            px[x, y] = (
                round(c1[0] + (c2[0] - c1[0]) * t),
                round(c1[1] + (c2[1] - c1[1]) * t),
                round(c1[2] + (c2[2] - c1[2]) * t),
            )
    return g


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius, fill=255)
    return m


def paw_glyph(size, scale=1.0):
    """A paw print: one broad pad with four toes arched above it.

    Every shape is an ellipse — no corners anywhere, which is the whole point
    after the eared version read as sharp. The outer toes sit lower and tilt
    outward so the arch looks like a paw rather than a row of dots.
    Supersampled 4x because circles this small alias badly.
    """
    ss = 4
    n = size * ss
    layer = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(layer)
    cx = cy = n / 2
    r = n * 0.30 * scale

    # Main pad, sitting low and slightly wider than tall.
    pad_w, pad_h = r * 1.06, r * 0.88
    pad_cy = cy + r * 0.33
    d.ellipse(
        [cx - pad_w / 2, pad_cy - pad_h / 2, cx + pad_w / 2, pad_cy + pad_h / 2],
        fill=255,
    )

    # Toes as (dx, dy, w, h) in units of r.
    for dx, dy, w, h in (
        (-0.70, -0.14, 0.30, 0.37),
        (-0.25, -0.47, 0.33, 0.41),
        (0.25, -0.47, 0.33, 0.41),
        (0.70, -0.14, 0.30, 0.37),
    ):
        tx, ty = cx + dx * r, cy + dy * r
        d.ellipse(
            [tx - w * r / 2, ty - h * r / 2, tx + w * r / 2, ty + h * r / 2],
            fill=255,
        )

    return layer.resize((size, size), Image.LANCZOS)


def build(size=S):
    bg = gradient(size, PLATE, PLATE_EDGE).convert("RGBA")
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), rounded_mask(size, int(size * 0.235)))

    paw = Image.new("RGBA", (size, size), PAW + (255,))
    icon.paste(paw, (0, 0), paw_glyph(size))
    return icon


def build_foreground(size=S):
    """Android adaptive foreground: paw only, on transparency.
    Adaptive icons crop ~33%, so the paw is shrunk into the safe centre.
    """
    fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    paw = Image.new("RGBA", (size, size), PAW + (255,))
    fg.paste(paw, (0, 0), paw_glyph(size, scale=0.62))
    return fg


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "out")
    os.makedirs(out, exist_ok=True)
    build().save(os.path.join(out, "icon.png"))
    build_foreground().save(os.path.join(out, "icon_foreground.png"))
    # Small sizes to eyeball legibility where it actually matters.
    for s in (16, 32, 48, 64, 128, 256):
        build().resize((s, s), Image.LANCZOS).save(os.path.join(out, f"preview_{s}.png"))
    print("wrote", out)
