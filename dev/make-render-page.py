#!/usr/bin/env python3
"""Build a self-contained contact sheet from the screenshots in dev/renders/.

The Preview tab serves a single HTML file, not its neighbours, so a page that
just points at `remap-main.png` shows broken images.  Inlining the PNGs as
base64 data URIs keeps the page standalone and clickable.

    python3 dev/make-render-page.py          # writes dev/renders/remap-preview.html

Regenerate the frames themselves on the radio first, e.g.:

    ssh root@<radio> 'printf "%s" /tmp/x.png > /tmp/btaudio.snapshot; \
        QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen \
        QT_QUICK_BACKEND=software qmlscene /usr/app_qt/btaudio/BtAudio.qml'
    scp root@<radio>:/tmp/x.png dev/renders/remap-main.png
"""
import base64
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RENDERS = os.path.join(HERE, "renders")
OUT = os.path.join(RENDERS, "remap-preview.html")

#: (file, heading, note).  Missing files are reported and skipped rather than
#: silently producing a page full of broken images.
FIGURES = [
    ("remap-main.png", "1. Main screen, with the new REMAP entry",
     "REMAP sits to the left of SCAN and is part of the same focus walk, so the "
     "knob reaches it: route, volume, speaker, scan, remap, devices, close."),
    ("remap-overlay.png", "2. The remap overlay, step 1 of 3",
     "The sequence is launch, then rotary, then select: the button that opens "
     "the screen, the knob to scroll with, then the button that selects. It is "
     "declared by the backend in state.remap.steps and rendered from that list, "
     "so reordering it is one edit in btaudiod and no edit to the screen. This "
     "frame was forced open for the render only."),
    ("remap-pending.png", "3. The same overlay holding a keycode to be confirmed",
     "A press has arrived for the launch button and is being shown rather than "
     "saved: an extra line appears above the step rows for the keycode, step 1 "
     "reads as waiting to be confirmed, and the title changes to CONFIRM. "
     "Nothing reaches /etc/btaudio.conf until the same button is pressed again, "
     "so a wrong button costs nothing. This is rendered against the mock backend "
     "(dev/mock-backend.py, scenario pending), which is why the panel and knob "
     "below are idle."),
    ("bt-live.png", "Earlier: BT Audio live on the radio, routing to BTSB370",
     "Captured before this change and kept so nothing is lost."),
    ("panelcheck-focus.png", "Earlier: panel check with the amber focus ring",
     "Captured before this change."),
]


def data_uri(path):
    with open(path, "rb") as fh:
        return "data:image/png;base64," + base64.b64encode(fh.read()).decode("ascii")


def main():
    blocks = []
    missing = []
    for name, heading, note in FIGURES:
        path = os.path.join(RENDERS, name)
        if not os.path.isfile(path):
            missing.append(name)
            continue
        blocks.append(
            '<figure>\n'
            '  <figcaption>%s</figcaption>\n'
            '  <img alt="%s" src="%s">\n'
            '  <p class="note">%s</p>\n'
            '</figure>\n' % (heading, heading, data_uri(path), note)
        )

    if not blocks:
        print("no renders found in %s" % RENDERS, file=sys.stderr)
        return 1

    html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>BT Audio -- front-panel remap renders</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; padding: 24px; background: #0b0f14; color: #e6edf3;
         font: 14px/1.5 "DejaVu Sans", system-ui, sans-serif; }
  h1 { font-size: 20px; letter-spacing: 2px; margin: 0 0 4px; }
  p.lede { color: #8b98a5; margin: 0 0 24px; max-width: 90ch; }
  p.warn { color: #d29922; border-left: 3px solid #d29922; padding-left: 12px; }
  figure { margin: 0 0 30px; }
  figcaption { color: #e6edf3; font-weight: bold; margin-bottom: 8px;
               letter-spacing: 1px; }
  img { width: 800px; max-width: 100%%; height: auto; border: 1px solid #26333f;
        border-radius: 6px; display: block; background: #000; }
  p.note { color: #8b98a5; margin-top: 8px; max-width: 90ch; }
  code { color: #39c6f2; }
</style>
</head>
<body>

<h1>FRONT-PANEL REMAP &mdash; RENDERS</h1>
<p class="lede">
  Rendered by the radio itself, offscreen, from the shipped
  <code>BtAudio.qml</code>. On the radio the same design stage is turned 270
  degrees into the panel's own 480x800 frame; the offscreen platform hands over
  800x600, so it appears here unrotated.
</p>

<p class="lede warn">
  <strong>Regenerate these with <code>dev/render-frames.py</code>, not by hand.</strong>
  Qt on this image is built without fontconfig, so it reads fonts only from the
  directory named by <code>QT_QPA_FONTDIR</code>; its compiled-in fallback,
  <code>/usr/lib/fonts</code>, does not exist here. A plain
  <code>ssh root@radio '&hellip;'</code> reads no profile and so inherits nothing,
  and Qt then draws <em>every panel, border and colour with no words at all</em> --
  which reads like a broken screen rather than a broken render. The script sets
  the variable and refuses to render unless it can prove glyphs are being drawn,
  so a frame from it can be trusted for what a label says. The launcher and the
  boot init script both source <code>/etc/profile</code>, so the radio's own
  <code>btaudio snapshot</code> was never affected.
</p>

%s
</body>
</html>
""" % "".join(blocks)

    with open(OUT, "w") as fh:
        fh.write(html)

    print("wrote %s (%.1f KB, %d figures)"
          % (OUT, os.path.getsize(OUT) / 1024.0, len(blocks)))
    if missing:
        print("skipped missing: %s" % ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
