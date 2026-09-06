"""Generate the Pahe Boy launcher icon.

Everything stays inside the inner ~78% of the canvas so iOS's rounded-rect
mask and Android's adaptive-icon circle mask never clip the artwork.
"""
from PIL import Image, ImageDraw
import os

S = 1024
# Indigo -> cyan.
INDIGO = (99, 102, 241)
CYAN = (34, 211, 238)
WHITE = (250, 248, 255)


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


def cat_play_glyph(size):
    """A cat head with the play triangle knocked out of it.

    The ear bases sit inside the head circle so they merge into one silhouette;
    detached triangles just read as noise at small sizes. Supersampled 4x
    because small polygons alias badly.
    """
    ss = 4
    n = size * ss
    layer = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(layer)
    cx = cy = n / 2
    r = n * 0.205

    # Head.
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)

    # Ears — base chord well inside the circle, apex outside, so they fuse.
    for sx in (-1, 1):
        d.polygon(
            [
                (cx + sx * 0.88 * r, cy - 0.42 * r),
                (cx + sx * 0.55 * r, cy - 1.34 * r),
                (cx + sx * 0.16 * r, cy - 0.50 * r),
            ],
            fill=255,
        )

    # Play triangle punched out. Nudged right of centre because a triangle's
    # optical centre sits left of its bounding box.
    tw, th = r * 0.62, r * 0.72
    left = cx - tw * 0.34
    d.polygon(
        [(left, cy - th / 2), (left, cy + th / 2), (left + tw, cy)],
        fill=0,
    )

    return layer.resize((size, size), Image.LANCZOS)


def build(size=S):
    bg = gradient(size, INDIGO, CYAN).convert("RGBA")
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), rounded_mask(size, int(size * 0.235)))

    glyph = cat_play_glyph(size)
    white = Image.new("RGBA", (size, size), WHITE + (255,))
    icon.paste(white, (0, 0), glyph)
    return icon


def build_foreground(size=S):
    """Android adaptive foreground: glyph only, on transparency."""
    fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    white = Image.new("RGBA", (size, size), WHITE + (255,))
    # Adaptive icons crop ~33%, so shrink the glyph into the safe centre.
    inner = int(size * 0.62)
    glyph = cat_play_glyph(inner)
    holder = Image.new("L", (size, size), 0)
    holder.paste(glyph, ((size - inner) // 2, (size - inner) // 2))
    fg.paste(white, (0, 0), holder)
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
