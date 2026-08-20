#!/usr/bin/env python3
"""Deterministic test-fixture generator for the Clipy fixture release.

Builds the real-scale fixture tree at ``.tmp/fixtures/clipy-fixtures-v1/``
(images, texts, rich text, misc + ``manifest.json``) and packs it as
``.tmp/fixtures/clipy-fixtures-v1.tar.gz`` (+ ``.sha256``). The tree is
generated ONCE, reviewed, and hosted on a GitHub release; CI downloads it and
never regenerates it.

Dependency: Pillow (developed and pinned against Pillow 12.3.0 in the
project-local venv ``.tmp/fixture-venv/``). Run with exactly::

    .tmp/fixture-venv/bin/python scripts/generate_fixtures.py

Determinism contract: for a fixed ``--seed`` (default 20260819) every output
byte is identical across runs and machines with the same Pillow version —
no wall clock, no ``os.urandom``; all randomness flows from
``random.Random(seed)`` plus Pillow's deterministic primitives
(``Image.effect_noise`` is libc-``rand`` based but never re-seeded by Pillow,
so a fixed call order reproduces it; a seeded per-pixel dither additionally
binds image content to ``--seed``). The tarball pins mtime/uid/gid/uname and
gzip mtime so it is reproducible too.

Coverage rationale (HistoryAuthority+DetailAndThumbnail.swift,
``thumbnailImageTypeIdentifiers``, docs/04-coherence.md §9): the frozen v1
ImageIO-decodable UTI set is png / jpeg / tiff / heic / heif / gif / bmp. All
except HEIC/HEIF are generated here; HEIC/HEIF cannot be encoded by Pillow and
are recorded in the manifest as deliberately uncovered. Limit-driven sizes
cite docs/06-cross-cutting.md §2 (``HistoryLimits.standard``): searchbody is
300 KiB to straddle the 256 KiB stored-search-body bound, title-over-1kib
exceeds the 1,024-byte stored-title bound.

DELIBERATELY EXCLUDED:

- No truncated/corrupt image fixtures. libpng logs ERROR lines on partial
  decode, which fail the CI log self-scan (learned in CI run 32259544566).
  Corruption negative tests live at the blob-codec level instead.
- No boundary-size binary blobs (64 MiB representation, 128 MiB capture —
  06 §2). Those are cheaply synthesized in-test; fixtures carry only content
  whose REALISM matters.

Budgets: total uncompressed <= 60 MiB; tarball <= ~40 MiB.

Usage:
  generate_fixtures.py generate [--seed N] [--outdir DIR] [--tarball PATH]
  generate_fixtures.py validate [--dir DIR] [--tarball PATH]
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import random
import re
import sys
import tarfile
import urllib.parse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

DEFAULT_SEED = 20260819
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTDIR = REPO_ROOT / ".tmp" / "fixtures" / "clipy-fixtures-v1"
DEFAULT_TARBALL = REPO_ROOT / ".tmp" / "fixtures" / "clipy-fixtures-v1.tar.gz"
TAR_ROOT = "clipy-fixtures-v1"

UNCOMPRESSED_BUDGET = 60 * 1024 * 1024
TARBALL_BUDGET = 40 * 1024 * 1024
HUGE_PNG_BUDGET = 25 * 1024 * 1024

# docs/06-cross-cutting.md §2 (HistoryLimits.standard) values that drive
# fixture sizing.
SEARCH_BODY_BOUND = 256 * 1024
TITLE_BOUND = 1_024

KiB = 1024
MiB = 1024 * 1024

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fit_utf8(text: str, target: int) -> bytes:
    """Trim/pad ``text`` to exactly ``target`` UTF-8 bytes.

    Truncation backs off to a Character boundary so the result is always
    valid UTF-8; padding appends spaces (callers that need a different pad
    shape, e.g. JSON/RTF/HTML, do their own exact-byte assembly).
    """
    data = text.encode("utf-8")
    if len(data) > target:
        data = data[:target].decode("utf-8", "ignore").encode("utf-8")
    if len(data) < target:
        data += b" " * (target - len(data))
    assert len(data) == target
    return data


def fmt_size(n: int) -> str:
    if n >= MiB:
        return f"{n / MiB:8.2f} MiB"
    return f"{n / KiB:8.1f} KiB"


def normalize_tiff(data: bytes) -> bytes:
    """Zero libtiff's uninitialized word-alignment pad byte(s) before the IFD.

    Pillow's LZW TIFF path writes strips, then the IFD at a word-aligned
    offset at the file tail; the alignment gap is never initialized, leaking
    one nondeterministic byte into otherwise deterministic output. Zeroing the
    gap between the last strip's end and the IFD start restores byte-level
    reproducibility without touching any tag or pixel data.
    """
    import struct
    endian = "<" if data[:2] == b"II" else ">"
    ifd_off = struct.unpack(endian + "I", data[4:8])[0]
    n = struct.unpack(endian + "H", data[ifd_off:ifd_off + 2])[0]
    tags = {}
    for i in range(n):
        tag, typ, cnt, val = struct.unpack(
            endian + "HHII", data[ifd_off + 2 + i * 12: ifd_off + 14 + i * 12]
        )
        tags[tag] = (typ, cnt, val)
    if 273 not in tags or 279 not in tags:
        return data
    _, cnt, offs_ptr = tags[273]
    _, _, cnts_ptr = tags[279]
    offsets = struct.unpack(endian + f"{cnt}I", data[offs_ptr:offs_ptr + 4 * cnt])
    counts = struct.unpack(endian + f"{cnt}I", data[cnts_ptr:cnts_ptr + 4 * cnt])
    strips_end = max(o + c for o, c in zip(offsets, counts))
    out = bytearray(data)
    for i in range(strips_end, ifd_off):
        out[i] = 0
    return bytes(out)


# ---------------------------------------------------------------------------
# Images — procedural but photographic-ish masters.
# Vertical-gradient sky + effect_noise grain + seeded dither + gaussian blur +
# ImageDraw shapes (hills/sun/water). Everything is a pure function of the
# seeded RNG and the fixed Pillow call order.
# ---------------------------------------------------------------------------

SKY_PALETTES = [
    ((36, 60, 128), (176, 214, 235)),   # midday blue
    ((24, 32, 78), (238, 166, 121)),    # dusk
    ((58, 92, 140), (204, 226, 240)),   # hazy morning
]
SUN_COLORS = [(255, 214, 140), (255, 178, 102), (252, 232, 178)]
HILL_COLORS = [(52, 78, 60), (63, 94, 82), (40, 62, 74)]
WATER_COLORS = [(44, 88, 122), (56, 104, 140), (38, 76, 108)]


def vertical_gradient(w: int, h: int, top: tuple, bottom: tuple) -> Image.Image:
    column = Image.new("RGB", (1, h))
    column.putdata(
        [
            (
                top[0] + (bottom[0] - top[0]) * y // (h - 1),
                top[1] + (bottom[1] - top[1]) * y // (h - 1),
                top[2] + (bottom[2] - top[2]) * y // (h - 1),
            )
            for y in range(h)
        ]
    )
    return column.resize((w, h), Image.NEAREST)


def seeded_dither(rng: random.Random, w: int, h: int, amplitude: int) -> Image.Image:
    """Seed-bound grayscale dither (amplitude +- around 128), L mode."""
    raw = rng.randbytes(w * h)
    base = 128 - amplitude
    table = [base + (i * (2 * amplitude) // 255) for i in range(256)]
    return Image.frombytes("L", (w, h), raw).point(table)


def draw_landscape_shapes(rng: random.Random, img: Image.Image) -> None:
    w, h = img.size
    draw = ImageDraw.Draw(img)
    # Sun.
    sun_r = int(min(w, h) * rng.uniform(0.05, 0.11))
    sun_x = int(w * rng.uniform(0.55, 0.85))
    sun_y = int(h * rng.uniform(0.15, 0.35))
    sun_color = SUN_COLORS[rng.randrange(len(SUN_COLORS))]
    draw.ellipse(
        [sun_x - sun_r, sun_y - sun_r, sun_x + sun_r, sun_y + sun_r], fill=sun_color
    )
    # Hills: layered polygons across the lower half.
    for layer in range(3):
        horizon = h * (0.55 + 0.10 * layer)
        points = [(0, h)]
        x = 0
        while x < w:
            points.append((x, int(horizon + h * rng.uniform(-0.06, 0.06))))
            x += int(w * rng.uniform(0.08, 0.2))
        points.append((w, int(horizon + h * rng.uniform(-0.04, 0.04))))
        points.append((w, h))
        color = HILL_COLORS[(layer + rng.randrange(len(HILL_COLORS))) % len(HILL_COLORS)]
        draw.polygon(points, fill=color)
    # Water band at the very bottom.
    water_top = int(h * rng.uniform(0.82, 0.9))
    water_color = WATER_COLORS[rng.randrange(len(WATER_COLORS))]
    draw.rectangle([0, water_top, w, h], fill=water_color)


def make_master(rng: random.Random, w: int, h: int) -> Image.Image:
    top, bottom = SKY_PALETTES[rng.randrange(len(SKY_PALETTES))]
    img = vertical_gradient(w, h, top, bottom)
    # Pillow effect_noise grain (fixed call order reproduces it; see header).
    grain = Image.effect_noise((w, h), rng.choice([18.0, 22.0, 26.0]))
    grain_rgb = Image.merge("RGB", (grain, grain, grain))
    img = Image.blend(img, grain_rgb, 0.05)
    # Seed-bound dither so --seed actually changes the pixels.
    dither = seeded_dither(rng, w, h, 10)
    dither_rgb = Image.merge("RGB", (dither, dither, dither))
    img = Image.blend(img, dither_rgb, 0.05)
    img = img.filter(ImageFilter.GaussianBlur(radius=rng.choice([1.6, 2.2, 2.8])))
    draw_landscape_shapes(rng, img)
    return img


def make_icon(rng: random.Random) -> Image.Image:
    size = 512
    img = vertical_gradient(size, size, (84, 110, 200), (34, 40, 84))
    dither = seeded_dither(rng, size, size, 6)
    img = Image.blend(img, Image.merge("RGB", (dither,) * 3), 0.04)
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([96, 96, 416, 416], radius=72, fill=(240, 244, 252))
    draw.rectangle([160, 176, 352, 208], fill=(84, 110, 200))
    draw.rectangle([160, 240, 320, 264], fill=(140, 156, 200))
    draw.rectangle([160, 296, 336, 320], fill=(140, 156, 200))
    return img


def encode_png(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def save_bytes(path: Path, data: bytes) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return len(data)


# ---------------------------------------------------------------------------
# Texts — realistic large bodies, exact byte sizes (06 §2 limit coverage).
# ---------------------------------------------------------------------------

LOREM_WORDS = (
    "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod "
    "tempor incididunt ut labore et dolore magna aliqua enim ad minim veniam "
    "quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo "
    "consequat duis aute irure in reprehenderit voluptate velit esse cillum "
    "fugiat nulla pariatur excepteur sint occaecat cupidatat non proident "
    "sunt culpa qui officia deserunt mollit anim id est laborum"
).split()

MD_WORDS = (
    "clipboard history item revision capture retention policy coherence token "
    "thumbnail paste payload search index snippet authority transaction "
    "projection codec fingerprint deduplication signature observer snapshot"
).split()

EMOJI_SIMPLE = (
    "😀😁😂🤣😃😄😅😆😉😊😋😎😍😘🥰😗😙😚🙂🤗🤩🤔🤨😐😑😶🙄😏😣😥😮🤐😯"
    "😪😫🥱😴😌😛😜😝🤤😒😓😔😕🙃🤑😲☹️🙁😖😞😟😤😢😭😦😧😨😩🤯😬😰😱🥵"
    "🥶😳🤪😵🥴😠😡🤬🤒🤕🤢🤮🥳🥺🤠😇🤡🤥🤫🤭🧐🤓😈👻💩👍👎👏🙌🙏💪"
    "🚀✨🔥🌈⭐🌍🌊🍎🍕🎉🎵🏀⚽🚗✈️🏠💡📚🖥️📱⌚🔒🔑🧭🪐🛰️🧪🧬🦀🐳"
)
EMOJI_ZWJ = [
    "👨‍👩‍👧‍👦", "👩‍💻", "👨‍🔬", "🧑‍🤝‍🧑", "🏳️‍🌈", "🏴‍☠️", "👩‍👩‍👧",
    "👨‍👨‍👦‍👦", "🧑‍🚀", "👩‍🏫", "🧑‍🎨", "👨‍🚒", "🐻‍❄️", "😶‍🌫️",
]
EMOJI_FLAGS = ["🇺🇸", "🇯🇵", "🇧🇷", "🇩🇪", "🇰🇷", "🇫🇷", "🇿🇦", "🇳🇴"]
EMOJI_TONES = ["👍🏻", "👍🏽", "👏🏿", "🙏🏾", "💪🏼", "🤝🏽"]


def sentences(rng: random.Random, words: list[str], n_sentences: int) -> str:
    out = []
    for _ in range(n_sentences):
        length = rng.randrange(6, 16)
        sentence = " ".join(rng.choice(words) for _ in range(length))
        out.append(sentence.capitalize() + rng.choice([".", ".", ".", "!", "?"]))
    return " ".join(out)


def paragraphs(rng: random.Random, words: list[str], n: int) -> str:
    return "\n\n".join(
        sentences(rng, words, rng.randrange(3, 9)) for _ in range(n)
    ) + "\n"


def gen_code_swift(rng: random.Random, target: int) -> bytes:
    """Real Swift source from this repo's own Sources/, chunk-shuffled."""
    files = sorted((REPO_ROOT / "Sources").glob("**/*.swift"))
    blocks = []
    for path in files:
        rel = path.relative_to(REPO_ROOT)
        text = path.read_text(encoding="utf-8")
        blocks.append(f"\n\n// ---- file: {rel} ----\n\n{text}")
    text = ""
    while len(text.encode("utf-8")) < target * 2:
        rng.shuffle(blocks)
        text += "".join(blocks)
    return fit_utf8(text, target)


def gen_json(rng: random.Random, target: int) -> bytes:
    """Valid JSON padded to exactly ``target`` bytes via a final pad record."""
    first_names = ["ada", "grace", "alan", "edsger", "barbara", "donald", "radia"]
    last_names = ["lovelace", "hopper", "turing", "dijkstra", "liskov", "knuth", "perlman"]
    cities = ["lisbon", "kyoto", "nairobi", "oslo", "quito", "tallinn", "hanoi"]
    tag_pool = ["urgent", "review", "archive", "pinned", "shared", "draft", "sync"]
    records = []
    total = 2 + len('{"records":[') + len("]}")
    i = 0
    while total < target - 512:
        rec = {
            "id": i,
            "name": f"{rng.choice(first_names)}.{rng.choice(last_names)}{i}",
            "email": f"user{i}@example{rng.randrange(90)}.test",
            "score": round(rng.uniform(0, 100), 4),
            "active": rng.random() < 0.7,
            "tags": rng.sample(tag_pool, rng.randrange(1, 4)),
            "address": {
                "city": rng.choice(cities),
                "zip": f"{rng.randrange(10000, 99999)}",
                "geo": {"lat": round(rng.uniform(-90, 90), 6),
                        "lon": round(rng.uniform(-180, 180), 6)},
            },
        }
        chunk = ("," if records else "") + json.dumps(
            rec, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        )
        records.append(chunk)
        total += len(chunk.encode("utf-8"))
        i += 1
    header = '{"records":['
    body = "".join(records)
    pad_template = ',{"id":999999,"pad":""}'
    footer = "]}"
    filler_len = target - len(header) - len(body.encode("utf-8")) - len(pad_template) - len(footer)
    while filler_len < 0:
        dropped = records.pop()
        body = body[: -len(dropped)] if body.endswith(dropped) else body
        body = "".join(records)
        filler_len = target - len(header) - len(body.encode("utf-8")) - len(pad_template) - len(footer)
    pad = "x" * filler_len
    out = header + body + pad_template.replace('""', f'"{pad}"') + footer
    data = out.encode("utf-8")
    assert len(data) == target, (len(data), target)
    json.loads(data)  # self-check: still valid JSON
    return data


def gen_markdown(rng: random.Random, target: int) -> bytes:
    parts = ["# Clipy Fixture Document\n"]
    while len("".join(parts).encode("utf-8")) < target * 2:
        kind = rng.randrange(4)
        if kind == 0:
            parts.append(f"\n## {sentences(rng, MD_WORDS, 1)[:-1]}\n")
        elif kind == 1:
            parts.append("\n" + paragraphs(rng, MD_WORDS, rng.randrange(1, 3)))
        elif kind == 2:
            items = "\n".join(
                f"- {sentences(rng, MD_WORDS, 1)}" for _ in range(rng.randrange(3, 8))
            )
            parts.append("\n" + items + "\n")
        else:
            code = "\n".join(
                f"let value{i} = compute({rng.randrange(1000)})"
                for i in range(rng.randrange(2, 7))
            )
            parts.append(f"\n```swift\n{code}\n```\n")
    return fit_utf8("".join(parts), target)


def gen_cjk(rng: random.Random, target: int) -> bytes:
    pool = [chr(c) for c in rng.sample(range(0x4E00, 0x9FFF), 400)]
    punct = ["。", "、", "！", "？", "；"]
    parts = []
    while len("".join(parts).encode("utf-8")) < target * 2:
        para_sentences = []
        for _ in range(rng.randrange(3, 7)):
            length = rng.randrange(8, 30)
            para_sentences.append(
                "".join(rng.choice(pool) for _ in range(length)) + rng.choice(punct)
            )
        parts.append("".join(para_sentences) + "\n\n")
    return fit_utf8("".join(parts), target)


def gen_emoji(rng: random.Random, target: int) -> bytes:
    ext_b = [chr(c) for c in rng.sample(range(0x20000, 0x2A6DF), 100)]
    parts = []
    while len("".join(parts).encode("utf-8")) < target * 2:
        tokens = []
        for _ in range(rng.randrange(10, 60)):
            roll = rng.random()
            if roll < 0.55:
                tokens.append(rng.choice(EMOJI_SIMPLE))
            elif roll < 0.75:
                tokens.append(rng.choice(EMOJI_ZWJ))
            elif roll < 0.85:
                tokens.append(rng.choice(EMOJI_FLAGS))
            elif roll < 0.95:
                tokens.append(rng.choice(EMOJI_TONES))
            else:
                tokens.append(rng.choice(ext_b))
        parts.append(" ".join(tokens) + "\n")
    return fit_utf8("".join(parts), target)


def gen_longlines(rng: random.Random, target: int) -> bytes:
    lines = []
    total = 0
    i = 0
    while total < target * 2:
        if i % 7 == 3:
            # The ~200 KB single lines.
            line_parts = []
            line_len = 0
            while line_len < 200 * KiB:
                word = rng.choice(LOREM_WORDS)
                line_parts.append(word)
                line_len += len(word) + 1
            line = " ".join(line_parts)
        else:
            line = sentences(rng, LOREM_WORDS, rng.randrange(1, 4))
        lines.append(line)
        total += len(line.encode("utf-8")) + 1
        i += 1
    return fit_utf8("\n".join(lines) + "\n", target)


def gen_lorem(rng: random.Random, target: int) -> bytes:
    parts = []
    while len("".join(parts).encode("utf-8")) < target * 2:
        parts.append(paragraphs(rng, LOREM_WORDS, rng.randrange(1, 4)))
    return fit_utf8("".join(parts), target)


def gen_searchbody(rng: random.Random, target: int) -> bytes:
    parts = []
    while len("".join(parts).encode("utf-8")) < target * 2:
        parts.append(paragraphs(rng, MD_WORDS, rng.randrange(1, 3)))
    return fit_utf8("".join(parts), target)


def gen_title(rng: random.Random, target: int) -> bytes:
    words = []
    while len(" ".join(words).encode("utf-8")) < target:
        words.append(rng.choice(MD_WORDS))
    return fit_utf8("Clipy fixture title: " + " ".join(words), target)


# ---------------------------------------------------------------------------
# Rich text / misc.
# ---------------------------------------------------------------------------


def gen_rtf(rng: random.Random, target: int) -> bytes:
    header = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Times New Roman;}}\\f0\\fs24\n"
    footer = "}"
    paras = []
    while len(header) + sum(len(p) for p in paras) < target * 2:
        text = sentences(rng, LOREM_WORDS, rng.randrange(2, 6))
        text = text.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")
        paras.append(text + "\\par\n")
    while paras:
        body = "".join(paras)
        filler_len = target - len(header) - len(body) - len("\\par\n") - len(footer)
        if filler_len >= 0:
            out = header + body + ("p" * filler_len) + "\\par\n" + footer
            data = out.encode("ascii")
            assert len(data) == target
            return data
        paras.pop()
    raise RuntimeError("rtf assembly failed")


def gen_html(rng: random.Random, target: int) -> bytes:
    header = (
        "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
        "<title>Clipy fixture page</title></head><body>\n<h1>Fixture</h1>\n"
    )
    footer = "</body></html>\n"
    paras = []
    while len(header) + sum(len(p) for p in paras) < target * 2:
        paras.append(f"<p>{sentences(rng, LOREM_WORDS, rng.randrange(2, 6))}</p>\n")
    while paras:
        body = "".join(paras)
        fixed = len(header) + len(body) + len("<!--") + len("-->\n") + len(footer)
        filler_len = target - fixed
        if filler_len >= 0:
            out = header + body + "<!--" + ("x" * filler_len) + "-->\n" + footer
            data = out.encode("utf-8")
            assert len(data) == target
            return data
        paras.pop()
    raise RuntimeError("html assembly failed")


def gen_pdf() -> bytes:
    """Minimal valid one-page PDF with programmatically computed xref offsets."""
    stream = b"BT /F1 18 Tf 72 720 Td (Clipy minimal PDF fixture) Tj ET\n"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n"
        + stream + b"endstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode("ascii") + body + b"\nendobj\n"
    xref_pos = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode("ascii")
    out += b"0000000000 65535 f \n"
    for off in offsets[1:]:
        out += f"{off:010d} 00000 n \n".encode("ascii")
    out += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref_pos}\n%%EOF\n"
    ).encode("ascii")
    return bytes(out)


def gen_files_txt(rng: random.Random) -> bytes:
    dirs = ["Documents", "Desktop", "Downloads/reports", "Projects/clipy", "Pictures"]
    stems = ["notes", "quarterly-report", "screenshot", "draft", "meeting minutes",
             "résumé", "预算表", "archive", "todo", "design doc"]
    exts = ["txt", "pdf", "png", "md", "csv", "rtf", "json", "pages"]
    lines = []
    for i in range(50):
        path = f"/Users/clipy/{rng.choice(dirs)}/{rng.choice(stems)}-{i}.{rng.choice(exts)}"
        lines.append("file://" + urllib.parse.quote(path))
    return ("\n".join(lines) + "\n").encode("utf-8")


# ---------------------------------------------------------------------------
# Manifest + tarball
# ---------------------------------------------------------------------------


def build_tarball(tree: Path, tarball: Path) -> None:
    """Reproducible .tar.gz: sorted entries, zeroed metadata, gzip mtime=0."""
    members = sorted(p for p in tree.rglob("*") if p.is_file())
    raw = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w") as tar:
            for path in members:
                rel = path.relative_to(tree)
                info = tarfile.TarInfo(name=f"{TAR_ROOT}/{rel.as_posix()}")
                data = path.read_bytes()
                info.size = len(data)
                info.mtime = 0
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mode = 0o644
                tar.addfile(info, io.BytesIO(data))
    tarball.parent.mkdir(parents=True, exist_ok=True)
    tarball.write_bytes(raw.getvalue())
    digest = sha256_bytes(raw.getvalue())
    tarball.with_suffix(tarball.suffix + ".sha256").write_text(
        f"{digest}  {tarball.name}\n", encoding="ascii"
    )


# ---------------------------------------------------------------------------
# Generation driver
# ---------------------------------------------------------------------------

TEXT_TARGETS = [
    # (filename, generator-key, exact byte target, note)
    ("code-swift-200kb.txt", "code", 200 * KiB,
     "real Swift source from this repo's Sources/, chunk-shuffled; 200 KiB"),
    ("json-1mb.json", "json", 1 * MiB, "valid generated JSON, exactly 1 MiB"),
    ("markdown-300kb.md", "markdown", 300 * KiB, "generated markdown, 300 KiB"),
    ("cjk-500kb.txt", "cjk", 500 * KiB,
     "CJK paragraphs from a seeded ideograph pool; multibyte UTF-8 density, 500 KiB"),
    ("emoji-150kb.txt", "emoji", 150 * KiB,
     "emoji-heavy; mixed ZWJ sequences and supplementary-plane content, 150 KiB"),
    ("longlines-2mb.txt", "longlines", 2 * MiB,
     "single lines up to ~200 KB; 2 MiB"),
    ("lorem-5mb.txt", "lorem", 5 * MiB, "lorem prose bulk, 5 MiB"),
    ("searchbody-300kb.txt", "searchbody", 300 * KiB,
     "search-body truncation boundary: 300 KiB > 256 KiB stored-search-body "
     "bound (docs/06 §2)"),
    ("title-over-1kib.txt", "title", 1_200,
     "single line > 1,024-byte stored-title bound (docs/06 §2)"),
]

EXPECTED_IMAGE_DIMS = {
    "photo4k-a.png": (3840, 2160),
    "photo4k-b.jpg": (3840, 2160),
    "photo4k-c.tiff": (3840, 2160),
    "photo-1080.bmp": (1920, 1080),
    "anim-720.gif": (1280, 720),
    "icon-512.png": (512, 512),
}


def generate(seed: int, outdir: Path, tarball: Path) -> list[dict]:
    rng = random.Random(seed)
    files: list[dict] = []

    def record(relpath: str, data: bytes, kind: str, note: str) -> None:
        save_bytes(outdir / relpath, data)
        files.append({
            "path": relpath,
            "sha256": sha256_bytes(data),
            "bytes": len(data),
            "kind": kind,
            "note": note,
        })

    # ---- images/ -----------------------------------------------------------
    masters = {
        "a": make_master(rng, 3840, 2160),
        "b": make_master(rng, 3840, 2160),
        "c": make_master(rng, 3840, 2160),
    }
    buf = io.BytesIO()
    masters["a"].save(buf, format="PNG")
    record("images/photo4k-a.png", buf.getvalue(), "image",
           "4K master A (public.png) — thumbnail storm source")
    buf = io.BytesIO()
    masters["b"].save(buf, format="JPEG", quality=87)
    record("images/photo4k-b.jpg", buf.getvalue(), "image",
           "4K master B (public.jpeg), quality 87")
    buf = io.BytesIO()
    masters["c"].save(buf, format="TIFF", compression="tiff_lzw")
    record("images/photo4k-c.tiff", normalize_tiff(buf.getvalue()), "image",
           "4K master C (public.tiff), LZW")

    bmp = masters["a"].resize((1920, 1080), Image.BICUBIC)
    buf = io.BytesIO()
    bmp.save(buf, format="BMP")
    record("images/photo-1080.bmp", buf.getvalue(), "image",
           "com.microsoft.bmp coverage; BMP kept at 1080p to bound uncompressed size")

    base_frame = masters["b"].resize((1280, 720), Image.BICUBIC)
    frames = []
    for f in range(3):
        tint = Image.new("RGB", base_frame.size, SUN_COLORS[f % len(SUN_COLORS)])
        frames.append(Image.blend(base_frame, tint, 0.06 * f).quantize(colors=256))
    buf = io.BytesIO()
    frames[0].save(buf, format="GIF", save_all=True, append_images=frames[1:],
                   duration=333, loop=0)
    record("images/anim-720.gif", buf.getvalue(), "image",
           "animated GIF (com.compuserve.gif), 3 frames, palette mode")

    crop_sizes = [(1600, 900), (1024, 1024), (640, 360)]
    for i in range(12):
        key = rng.choice(["a", "b", "c"])
        cw, ch = crop_sizes[i % len(crop_sizes)]
        master = masters[key]
        x = rng.randrange(0, master.width - cw + 1)
        y = rng.randrange(0, master.height - ch + 1)
        crop = master.crop((x, y, x + cw, y + ch))
        fmt = "PNG" if i % 2 == 0 else "JPEG"
        ext = "png" if fmt == "PNG" else "jpg"
        buf = io.BytesIO()
        if fmt == "JPEG":
            crop.save(buf, format="JPEG", quality=90)
        else:
            crop.save(buf, format="PNG")
        record(f"images/crop-{i + 1:02d}-{cw}x{ch}.{ext}", buf.getvalue(), "image",
               f"realistic crop of 4K master {key} (public.{ext if ext == 'png' else 'jpeg'})")

    huge = make_master(rng, 7680, 4320)
    huge_png = encode_png(huge)
    if len(huge_png) <= HUGE_PNG_BUDGET:
        record("images/huge-8k.png", huge_png, "image",
               "largest raster fixture (7680x4320); thumbnail stress, <= 25 MiB budget")
    else:
        # Deterministic fallback: the size check is a pure function of the
        # seeded content, so every run takes the same branch.
        huge = huge.resize((5120, 2880), Image.BICUBIC)
        record("images/huge-5k.png", encode_png(huge), "image",
               "8K exceeded the 25 MiB budget; downscaled to 5120x2880")

    record("images/icon-512.png", encode_png(make_icon(rng)), "image",
           "app-icon-scale raster")

    # ---- text/ -------------------------------------------------------------
    generators = {
        "code": gen_code_swift,
        "json": gen_json,
        "markdown": gen_markdown,
        "cjk": gen_cjk,
        "emoji": gen_emoji,
        "longlines": gen_longlines,
        "lorem": gen_lorem,
        "searchbody": gen_searchbody,
        "title": gen_title,
    }
    for filename, gen_key, target, note in TEXT_TARGETS:
        data = generators[gen_key](rng, target)
        record(f"text/{filename}", data, "text", note)

    # ---- rich/ -------------------------------------------------------------
    record("rich/doc-300kb.rtf", gen_rtf(rng, 300 * KiB), "rich",
           "valid RTF 1.6 wrapping generated paragraphs, 300 KiB")
    record("rich/page-300kb.html", gen_html(rng, 300 * KiB), "rich",
           "valid HTML5, 300 KiB")

    # ---- misc/ -------------------------------------------------------------
    record("misc/tiny.pdf", gen_pdf(), "misc",
           "hand-written minimal valid one-page PDF, programmatic xref offsets")
    record("misc/files.txt", gen_files_txt(rng), "misc",
           "50 file:// URLs (mixed ASCII / UTF-8 paths)")

    # ---- manifest ----------------------------------------------------------
    files.sort(key=lambda f: f["path"])
    manifest = {
        "version": 1,
        "seed": seed,
        "uncovered": [
            {
                "typeIdentifier": "public.heic",
                "reason": "HEIC/HEIF cannot be encoded by Pillow; deliberately "
                          "uncovered by this fixture set (thumbnail UTI set in "
                          "HistoryAuthority+DetailAndThumbnail.swift).",
            },
            {
                "typeIdentifier": "public.heif",
                "reason": "HEIC/HEIF cannot be encoded by Pillow; deliberately "
                          "uncovered by this fixture set (thumbnail UTI set in "
                          "HistoryAuthority+DetailAndThumbnail.swift).",
            },
        ],
        "files": files,
    }
    manifest_bytes = json.dumps(manifest, indent=2, ensure_ascii=False).encode("utf-8") + b"\n"
    save_bytes(outdir / "manifest.json", manifest_bytes)

    build_tarball(outdir, tarball)
    print_size_table(files, manifest_bytes, tarball)
    return files


def print_size_table(files: list[dict], manifest_bytes: bytes, tarball: Path) -> None:
    by_kind: dict[str, list[int]] = {}
    for f in files:
        by_kind.setdefault(f["kind"], []).append(f["bytes"])
    total = sum(f["bytes"] for f in files) + len(manifest_bytes)
    print("\n=== fixture size table ===")
    for kind in sorted(by_kind):
        sizes = by_kind[kind]
        print(f"{kind:8s} {len(sizes):3d} files  {fmt_size(sum(sizes))}")
    print(f"{'manifest':8s}   1 file   {fmt_size(len(manifest_bytes))}")
    print(f"{'TOTAL':8s} {len(files) + 1:3d} files  {fmt_size(total)}"
          f"  (budget {fmt_size(UNCOMPRESSED_BUDGET)})")
    tar_size = tarball.stat().st_size
    print(f"{'tarball':8s}           {fmt_size(tar_size)}"
          f"  (budget {fmt_size(TARBALL_BUDGET)})")
    if total > UNCOMPRESSED_BUDGET:
        raise SystemExit(f"BUDGET EXCEEDED: uncompressed {total} > {UNCOMPRESSED_BUDGET}")
    if tar_size > TARBALL_BUDGET:
        raise SystemExit(f"BUDGET EXCEEDED: tarball {tar_size} > {TARBALL_BUDGET}")
    print("budgets: OK")


# ---------------------------------------------------------------------------
# Validation (stdlib + Pillow only)
# ---------------------------------------------------------------------------


def validate_pdf(data: bytes) -> list[str]:
    errors = []
    if not data.startswith(b"%PDF-1."):
        errors.append("missing %PDF-1.x header")
        return errors
    if not data.rstrip().endswith(b"%%EOF"):
        errors.append("missing %%EOF trailer")
    m = re.search(rb"startxref\s*\n(\d+)\s*\n", data)
    if not m:
        errors.append("missing startxref")
        return errors
    xref_pos = int(m.group(1))
    if data[xref_pos:xref_pos + 4] != b"xref":
        errors.append(f"startxref offset {xref_pos} does not point at 'xref'")
        return errors
    lines = data[xref_pos:].split(b"\n")
    # lines[0] = b'xref', lines[1] = b'0 N', then N 20-byte entries.
    try:
        count = int(lines[1].split()[1])
    except (IndexError, ValueError):
        errors.append("malformed xref subsection header")
        return errors
    for i in range(1, count):  # skip object 0 (free entry)
        entry = lines[2 + i]
        if len(entry) < 18:
            errors.append(f"xref entry {i} too short: {entry!r}")
            continue
        off = int(entry[:10])
        if entry[17:18] != b"n":
            continue
        if not re.match(rb"%d 0 obj" % i, data[off:off + 16]):
            errors.append(f"xref entry {i} offset {off} does not point at '{i} 0 obj'")
    return errors


def validate(tree: Path, tarball: Path) -> None:
    manifest = json.loads((tree / "manifest.json").read_text(encoding="utf-8"))
    problems: list[str] = []

    entries = {f["path"]: f for f in manifest["files"]}
    on_disk = sorted(
        p.relative_to(tree).as_posix()
        for p in tree.rglob("*") if p.is_file() and p.name != "manifest.json"
    )
    if sorted(entries) != on_disk:
        problems.append(
            f"manifest/tree mismatch: only-in-manifest={sorted(set(entries) - set(on_disk))} "
            f"only-on-disk={sorted(set(on_disk) - set(entries))}"
        )

    for rel in sorted(entries):
        entry = entries[rel]
        data = (tree / rel).read_bytes()
        if len(data) != entry["bytes"]:
            problems.append(f"{rel}: size {len(data)} != manifest {entry['bytes']}")
        if sha256_bytes(data) != entry["sha256"]:
            problems.append(f"{rel}: sha256 mismatch")
        kind = entry["kind"]

        if kind == "image":
            with Image.open(tree / rel) as im:
                im.load()
                name = Path(rel).name
                if name in EXPECTED_IMAGE_DIMS:
                    if im.size != EXPECTED_IMAGE_DIMS[name]:
                        problems.append(f"{rel}: dims {im.size} != {EXPECTED_IMAGE_DIMS[name]}")
                elif name.startswith("crop-"):
                    mw, mh = (int(v) for v in re.search(r"-(\d+)x(\d+)\.", name).groups())
                    if im.size != (mw, mh):
                        problems.append(f"{rel}: dims {im.size} != {mw}x{mh}")
                elif name == "huge-8k.png" and im.size != (7680, 4320):
                    problems.append(f"{rel}: dims {im.size} != (7680, 4320)")
                elif name == "huge-5k.png" and im.size != (5120, 2880):
                    problems.append(f"{rel}: dims {im.size} != (5120, 2880)")
                if name == "anim-720.gif" and getattr(im, "n_frames", 1) != 3:
                    problems.append(f"{rel}: n_frames {im.n_frames} != 3")

        if kind in ("text", "rich", "misc") and rel.endswith((".txt", ".md", ".json", ".html", ".rtf")):
            try:
                data.decode("utf-8")
            except UnicodeDecodeError as exc:
                problems.append(f"{rel}: invalid UTF-8: {exc}")
        if rel.endswith(".json") and kind == "text":
            json.loads(data)
        if rel.endswith(".rtf") and not data.startswith(b"{\\rtf1"):
            problems.append(f"{rel}: missing {{\\rtf1 header")
        if rel.endswith(".html") and b"<!DOCTYPE html" not in data[:64]:
            problems.append(f"{rel}: missing <!DOCTYPE html")
        if rel.endswith(".pdf"):
            problems.extend(f"{rel}: {e}" for e in validate_pdf(data))

    # Limit-boundary assertions (docs/06 §2).
    sb = entries["text/searchbody-300kb.txt"]["bytes"]
    if not sb > SEARCH_BODY_BOUND:
        problems.append(f"searchbody {sb} not > 256 KiB search-body bound")
    title = (tree / "text/title-over-1kib.txt").read_bytes()
    if not len(title) > TITLE_BOUND:
        problems.append(f"title {len(title)} not > 1,024-byte title bound")
    if b"\n" in title.rstrip(b" "):
        problems.append("title-over-1kib.txt is not a single line")

    # Tarball: hash matches .sha256 sidecar; member bytes match the tree.
    tar_data = tarball.read_bytes()
    sidecar = tarball.with_suffix(tarball.suffix + ".sha256").read_text("ascii")
    if sha256_bytes(tar_data) != sidecar.split()[0]:
        problems.append("tarball sha256 != .sha256 sidecar")
    with tarfile.open(fileobj=io.BytesIO(tar_data), mode="r:gz") as tar:
        for member in tar.getmembers():
            if not member.isfile():
                continue
            rel = member.name.removeprefix(f"{TAR_ROOT}/")
            member_data = tar.extractfile(member).read()
            if rel == "manifest.json":
                expected = (tree / "manifest.json").read_bytes()
            elif rel in entries:
                expected = (tree / rel).read_bytes()
            else:
                problems.append(f"tarball member {rel} not in tree")
                continue
            if member_data != expected:
                problems.append(f"tarball member {rel} bytes differ from tree")

    if problems:
        print("VALIDATION FAILED:")
        for p in problems:
            print(f"  - {p}")
        raise SystemExit(1)
    print(f"validation OK: {len(entries)} files, tarball + sha256 verified")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate")
    gen.add_argument("--seed", type=int, default=DEFAULT_SEED)
    gen.add_argument("--outdir", type=Path, default=DEFAULT_OUTDIR)
    gen.add_argument("--tarball", type=Path, default=DEFAULT_TARBALL)

    val = sub.add_parser("validate")
    val.add_argument("--dir", type=Path, default=DEFAULT_OUTDIR)
    val.add_argument("--tarball", type=Path, default=DEFAULT_TARBALL)

    args = parser.parse_args()
    if args.command == "generate":
        generate(args.seed, args.outdir, args.tarball)
    else:
        validate(args.dir, args.tarball)


if __name__ == "__main__":
    main()
