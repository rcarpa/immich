#!/usr/bin/env python3
"""Generate every piece of Mirrich's artwork from one description of the mark.

Design intent (see mobile/FORK.md):
  lineage  - five-blade camera iris, the same rotational motif as Immich's mark
  contrast - a single warm amber instead of Immich's five colours, on near-black
  meaning  - the iris is CLOSED around a solid core: an image held, not streamed

Two shapes come out of the same geometry: the *icon*, which is the mark on its
own near-black tile because iOS wants an opaque square, and the *mark*, which is
the blades alone on transparency for use in the app and on the launch screen.

Usage:
  python3 tools/make_icon.py <out-dir> [sizes...]   # icon tiles, as before
  python3 tools/make_icon.py --brand [mobile-dir]   # every branded asset, in place

Nothing here is hand-editable: change the constants, re-run, commit the output.
The alternative is thirty-odd PNGs drifting out of step with each other.
"""
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image

W = 1024
C = W / 2

R_OUT = 340.0   # outer radius of the blade ring
R_IN = 38.0     # a pinhole: shut, but unmistakably a shutter and not a pinwheel
SPAN = 72.0     # 5 blades
GAP = 9.5      # angular seam, wide enough to survive downscaling to 29px
TWIST = 44.0    # spiral, echoing Immich's swirl
SOFT = 13.0     # stroke width that rounds the blade corners


def pol(radius, deg):
    rad = math.radians(deg - 90.0)  # 0deg points up
    return (C + radius * math.cos(rad), C + radius * math.sin(rad))


def fmt(pt):
    return f"{pt[0]:.2f},{pt[1]:.2f}"


def blade(index):
    base = index * SPAN
    a_out = base - SPAN / 2 + GAP / 2
    b_out = base + SPAN / 2 - GAP / 2
    a_in, b_in = a_out + TWIST, b_out + TWIST
    return (
        f"M {fmt(pol(R_OUT, a_out))} "
        f"A {R_OUT:.2f},{R_OUT:.2f} 0 0 1 {fmt(pol(R_OUT, b_out))} "
        f"L {fmt(pol(R_IN, b_in))} "
        f"A {R_IN:.2f},{R_IN:.2f} 0 0 0 {fmt(pol(R_IN, a_in))} Z"
    )


blades = "\n".join(f'      <path d="{blade(i)}"/>' for i in range(5))

ICON_SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">
  <defs>
    <linearGradient id="ground" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#232736"/>
      <stop offset="50%" stop-color="#141722"/>
      <stop offset="100%" stop-color="#070810"/>
    </linearGradient>
    <linearGradient id="metal" x1="0.12" y1="0" x2="0.88" y2="1">
      <stop offset="0%" stop-color="#FFE3A3"/>
      <stop offset="30%" stop-color="#FFC64F"/>
      <stop offset="65%" stop-color="#F9971F"/>
      <stop offset="100%" stop-color="#DC6B0C"/>
    </linearGradient>
    <radialGradient id="halo" cx="0.5" cy="0.5" r="0.5">
      <stop offset="55%" stop-color="#FFB020" stop-opacity="0"/>
      <stop offset="78%" stop-color="#FFB020" stop-opacity="0.16"/>
      <stop offset="100%" stop-color="#FFB020" stop-opacity="0"/>
    </radialGradient>
  </defs>

  <rect width="{W}" height="{W}" fill="url(#ground)"/>
  <circle cx="{C}" cy="{C}" r="{R_OUT * 1.32:.0f}" fill="url(#halo)"/>

  <!-- The blades run all the way to the centre, so the iris is fully shut:
       no opening, nothing showing through. The seams taper to a point, which
       is exactly how a real closed aperture looks. -->
  <g fill="url(#metal)" stroke="url(#metal)" stroke-width="{SOFT}" stroke-linejoin="round">
{blades}
  </g>
</svg>
"""

# The mark alone: no tile, no ground, so it can sit on a launch screen or beside
# text at any size. The halo goes too — it reads as grime on a light background.
MARK_SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">
  <defs>
    <linearGradient id="metal" x1="0.12" y1="0" x2="0.88" y2="1">
      <stop offset="0%" stop-color="#FFE3A3"/>
      <stop offset="30%" stop-color="#FFC64F"/>
      <stop offset="65%" stop-color="#F9971F"/>
      <stop offset="100%" stop-color="#DC6B0C"/>
    </linearGradient>
  </defs>

  <g fill="url(#metal)" stroke="url(#metal)" stroke-width="{SOFT}" stroke-linejoin="round">
{blades}
  </g>
</svg>
"""

# Launch-screen ground. Warm off-white in light mode rather than Immich's cool
# one, and the icon's own near-black in dark mode, so the mark sits on the colour
# it was drawn against.
LAUNCH_LIGHT = (255, 248, 238)
LAUNCH_DARK = (7, 8, 16)

# The wordmark is set in Overpass Bold, which the app already bundles, so the
# type on the splash screen is the type in the app. It is emitted as a
# transparent mask because the widget tints it with the theme's primary colour.
WORDMARK_FONT = "fonts/overpass/Overpass-Bold.ttf"
WORDMARK = "Mirrich"


def render(svg_text, size, out_path, *, flatten=None, pad=0.0):
    """SVG -> PNG at `size`, optionally flattened onto a colour and inset."""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.svg"
        src.write_text(svg_text)
        raw = Path(tmp) / "out.png"
        inner = max(1, round(size * (1.0 - 2 * pad)))
        subprocess.run(
            ["rsvg-convert", "-w", str(inner), "-h", str(inner), str(src), "-o", str(raw)],
            check=True,
        )
        img = Image.open(raw).convert("RGBA")

    if pad > 0:
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        offset = ((size - img.width) // 2, (size - img.height) // 2)
        canvas.paste(img, offset, img)
        img = canvas

    if flatten is not None:
        # iOS rejects icons with an alpha channel.
        flat = Image.new("RGB", img.size, flatten)
        flat.paste(img, mask=img.split()[3])
        img = flat

    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, "PNG", optimize=True)


def wordmark(root, height, out_path, colour):
    """The word, as a transparent PNG the widget can tint."""
    from PIL import ImageDraw, ImageFont

    font = ImageFont.truetype(str(root / WORDMARK_FONT), height)
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    left, top, right, bottom = probe.textbbox((0, 0), WORDMARK, font=font)
    margin = round(height * 0.12)
    img = Image.new("RGBA", (right - left + 2 * margin, bottom - top + 2 * margin), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((margin - left, margin - top), WORDMARK, font=font, fill=colour)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, "PNG", optimize=True)


def brand(root):
    """Every branded asset, written where the app expects it."""
    assets = root / "assets"

    # In-app mark, and the inline form the app bar uses. One drawing serves both
    # themes: amber reads on either, and two files that differ only in name would
    # be two files to keep in step.
    (assets / "mirrich-logo.svg").write_text(MARK_SVG)
    for name in ("mirrich-logo-inline-dark.svg", "mirrich-logo-inline-light.svg"):
        (assets / name).write_text(MARK_SVG)
    render(MARK_SVG, 1024, assets / "mirrich-logo.png")

    # Launch screen. Sizes match what flutter_native_splash generates from these
    # sources, so a build works before anyone re-runs the generator.
    render(MARK_SVG, 320, assets / "mirrich-splash.png")
    render(MARK_SVG, 1152, assets / "mirrich-splash-android12.png", pad=1 / 6)

    launch = root / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
    for size, name in ((80, "LaunchImage.png"), (160, "LaunchImage@2x.png"), (240, "LaunchImage@3x.png")):
        render(MARK_SVG, size, launch / name)

    ground = root / "ios/Runner/Assets.xcassets/LaunchBackground.imageset"
    for colour, name in ((LAUNCH_LIGHT, "background.png"), (LAUNCH_DARK, "darkbackground.png")):
        Image.new("RGB", (1, 1), colour).save(ground / name, "PNG", optimize=True)

    # Wordmark, in both themes the widget asks for. It tints what it loads, so
    # the two differ only in the colour they carry for anything that does not.
    wordmark(root, 512, assets / "mirrich-text-dark.png", (255, 255, 255, 255))
    wordmark(root, 512, assets / "mirrich-text-light.png", (17, 17, 17, 255))

    print("wrote the mark, the launch screen and the wordmark under", root)


if sys.argv[1:2] == ["--brand"]:
    brand(Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent)
    sys.exit(0)

out_dir = Path(sys.argv[1])
out_dir.mkdir(parents=True, exist_ok=True)
master = out_dir / "mirrich-icon.svg"
master.write_text(ICON_SVG)

sizes = [int(a) for a in sys.argv[2:]] or [1024]
for size in sizes:
    render(ICON_SVG, size, out_dir / f"{size}.png", flatten=(7, 8, 16))

print(f"wrote {len(sizes)} png(s) + {master}")
