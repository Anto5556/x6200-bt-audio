#!/usr/bin/env python3
"""Render the BT Audio screens offscreen on the radio, text included.

Run this on the radio:

    python3 dev/render-frames.py [OUTDIR]        # default /tmp

then pull the frames back and build the contact sheet:

    scp 'root@<radio>:/tmp/btframe-*.png' dev/renders/
    python3 dev/make-render-page.py

Why this is a script rather than three commands
-----------------------------------------------
Qt on this image is built *without* fontconfig, so it reads fonts only from the
directory named by `QT_QPA_FONTDIR`.  Its compiled-in fallback, /usr/lib/fonts,
does not exist here.  /etc/profile sets

    export QT_QPA_FONTDIR=/usr/share/fonts        # /etc/profile, line 45

which is why the panel is fine: the launcher and the boot init script both
`source /etc/profile`, and anything they start inherits it.  But a plain
`ssh root@radio '<command>'` reads no profile, so a render launched that way has
no font directory and Qt draws *no glyphs at all* -- while still rendering every
panel, border and colour correctly.  The result looks like a plausible frame with
the words missing, and it is very easy to conclude the screen itself is broken.

So the font directory is set here explicitly, and `selfcheck()` proves glyphs are
really being drawn before any frame is rendered.  If that check ever fails, this
script says so loudly instead of quietly writing text-less images.

`btaudio snapshot` is the simpler way to render just the main screen; it goes
through the launcher and so already has the font directory.
"""
import hashlib
import os
import subprocess
import sys
import time

SRC = os.environ.get("BTAUDIO_QML", "/usr/app_qt/btaudio/BtAudio.qml")
MOCK = os.environ.get("BTAUDIO_MOCK", "/tmp/mock-backend.py")
OUTDIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp"

#: Where the fonts actually are on this image, and what Qt must be told.
FONT_DIR = os.environ.get("QT_QPA_FONTDIR") or "/usr/share/fonts"

BASE_ENV = {
    "QML_XHR_ALLOW_FILE_READ": "1",
    "QT_QPA_PLATFORM": "offscreen",
    "QT_QUICK_BACKEND": "software",
    "QT_QPA_FONTDIR": FONT_DIR,
}

PROBE_QML = '''import QtQuick 2.12
import QtQuick.Window 2.12
Window {
    id: root
    width: 420; height: 120; visible: true; color: "#000000"
    property string label: "%s"
    property string out: "%s"
    Text { anchors.centerIn: parent; color: "#ffffff"; font.pixelSize: 44
           font.family: "DejaVu Sans"; text: root.label }
    Timer { interval: 1000; running: true
            onTriggered: root.contentItem.grabToImage(function (r) {
                r.saveToFile(root.out); Qt.quit();
            }) }
}
'''


def env(**extra):
    merged = dict(os.environ)
    merged.update(BASE_ENV)
    merged.update(extra)
    return merged


def run_qml(path, timeout=60):
    """Run a screen to completion; a hang is reported, not raised.

    qmlscene only exits because the screen calls Qt.quit() after grabbing its
    frame, so anything that stops that from running (a QML error in the quit
    path, say) leaves the process alive for good.  Treating that as a plain
    timeout keeps the tool honest about what happened.
    """
    try:
        proc = subprocess.run(["qmlscene", path], env=env(), timeout=timeout,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = proc.stdout.decode()
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or b"").decode()
        noise = ("QFontDatabase", "Qt no longer ships", "XDG_RUNTIME_DIR",
                 "createPlatformOpenGLContext", "bt audio: logical")
        shown = [l for l in out.splitlines()
                 if l.strip() and not any(n in l for n in noise)][:4]
        return (["!! did not exit within %ds (it never called Qt.quit())" % timeout]
                + shown)
    noise = ("QFontDatabase", "Qt no longer ships", "XDG_RUNTIME_DIR",
             "createPlatformOpenGLContext", "bt audio: logical")
    return [l for l in out.splitlines()
            if l.strip() and not any(n in l for n in noise)]


def selfcheck():
    """Prove the font directory works, so a blank frame is never mistaken."""
    if not os.path.isdir(FONT_DIR):
        print("!! font directory %s does not exist" % FONT_DIR)
        return False
    digests = []
    for label, tag in (("READY", "a"), ("WWWWWWWWWW", "b")):
        out = "/tmp/glyph-%s.png" % tag
        qml = "/tmp/glyph-%s.qml" % tag
        with open(qml, "w") as fh:
            fh.write(PROBE_QML % (label, out))
        if os.path.exists(out):
            os.unlink(out)
        try:
            subprocess.run(["qmlscene", qml], env=env(), timeout=30,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            print("!! glyph probe did not exit -- check it still has 'id: root'")
            return False
        if not os.path.exists(out):
            print("!! glyph probe produced no image")
            return False
        digests.append(hashlib.md5(open(out, "rb").read()).hexdigest())
        os.unlink(out)
        os.unlink(qml)
    ok = len(set(digests)) == 2
    print("glyph check: %s (QT_QPA_FONTDIR=%s)"
          % ("text is drawn" if ok else "NO TEXT -- frames would be blank",
             FONT_DIR))
    return ok


def variant(port, force_open):
    """A copy of the screen pointed at another port / forced into the overlay."""
    src = open(SRC).read()
    if port != 8637:
        src = src.replace("127.0.0.1:8637", "127.0.0.1:%d" % port)
    if force_open:
        src = src.replace("    property bool remapOpen: false",
                          "    property bool remapOpen: true")
    path = "/tmp/render-%d-%s.qml" % (port, "open" if force_open else "shut")
    with open(path, "w") as fh:
        fh.write(src)
    return path


def render(name, port, force_open, scenario):
    """Render one frame, with a mock backend when a scenario is given."""
    server = None
    png = os.path.join(OUTDIR, name)
    if scenario:
        server = subprocess.Popen([sys.executable, MOCK, str(port), scenario],
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        time.sleep(2.0)
    try:
        with open("/tmp/btaudio.snapshot", "w") as fh:
            fh.write(png)
        warnings = run_qml(variant(port, force_open))
        try:
            os.unlink("/tmp/btaudio.snapshot")
        except OSError:
            pass
        size = os.path.getsize(png) if os.path.exists(png) else 0
        print("  %-20s %7d bytes  %s" % (name, size,
                                         "; ".join(warnings) or "clean"))
        return size == 0
    finally:
        if server:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
            time.sleep(0.5)


def main():
    print("source :", SRC)
    print("output :", OUTDIR)
    if not selfcheck():
        print("refusing to render frames that would look fine but have no words")
        return 1
    if not os.path.exists(MOCK):
        print("!! mock backend %s missing (scp dev/mock-backend.py to /tmp)"
              % MOCK)
        return 1

    print("frames :")
    failed = 0
    failed += render("remap-main.png", 8637, False, None)
    failed += render("remap-overlay.png", 8639, True, "idle")
    failed += render("remap-pending.png", 8640, True, "pending")
    if failed:
        print("%d frame(s) failed to render" % failed)
        return 1
    print("done -- pull them back with:")
    print("  scp 'root@<radio>:%s/remap-*.png' dev/renders/" % OUTDIR.rstrip("/"))
    print("  python3 dev/make-render-page.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
