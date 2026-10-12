#!/usr/bin/env python3
"""Log input events from the X6200 front panel (passive -- does not grab)."""
import glob
import os
import select
import struct
import sys
import time

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 300.0
EVI = struct.Struct("<IIHHi")  # timeval(2x u32) + type u16 + code u16 + value i32

NAMES = {
    0: "RESERVED", 1: "ESC", 2: "1", 3: "2", 4: "3", 5: "4", 6: "5", 7: "6", 8: "7",
    9: "8", 10: "9", 11: "0", 12: "MINUS", 13: "EQUAL", 14: "BACKSPACE", 15: "TAB",
    16: "Q", 17: "W", 18: "E", 19: "R", 20: "T", 21: "Y", 22: "U", 23: "I", 24: "O",
    25: "P", 26: "LEFTBRACE", 27: "RIGHTBRACE", 28: "ENTER", 29: "LEFTCTRL",
    30: "A", 31: "S", 32: "D", 33: "F", 34: "G", 35: "H", 36: "J", 37: "K", 38: "L",
    39: "SEMICOLON", 40: "APOSTROPHE", 42: "LEFTSHIFT", 43: "BACKSLASH", 44: "Z",
    45: "X", 46: "C", 47: "V", 48: "B", 49: "N", 50: "M", 51: "COMMA", 52: "DOT",
    53: "SLASH", 55: "KPASTERISK", 56: "LEFTALT", 57: "SPACE", 58: "CAPSLOCK",
    59: "F1", 60: "F2", 61: "F3", 62: "F4", 63: "F5", 103: "UP", 105: "LEFT",
    106: "RIGHT", 108: "DOWN", 116: "POWER", 115: "VOLUMEUP", 114: "VOLUMEDOWN",
    119: "PAUSE", 125: "LEFTMETA", 139: "MENU", 158: "BACK", 217: "SEARCH",
    352: "OK", 353: "SELECT", 354: "GOTO", 358: "INFO", 362: "PROGRAM",
}

TYPE_NAMES = {0: "SYN", 1: "KEY", 2: "REL", 3: "ABS", 4: "MSC", 17: "LED", 20: "REP"}
REL_NAMES = {0: "REL_X", 1: "REL_Y", 6: "REL_DIAL", 7: "REL_WHEEL", 8: "REL_MISC"}


def label(type_, code):
    if type_ == 1:
        name = NAMES.get(code)
        if name:
            return "KEY %s (%d)" % (name, code)
        if 700 <= code <= 760:
            return "KEY vendor-%d (0x%X)" % (code, code)
        return "KEY code=%d" % code
    if type_ == 2:
        return "REL %s (%d)" % (REL_NAMES.get(code, "?"), code)
    return "%s code=%d" % (TYPE_NAMES.get(type_, type_), code)


def main():
    devices = {}
    fds = []
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            fh = open(path, "rb", buffering=0)
            sysname = "/sys/class/input/%s/device/name" % os.path.basename(path)
            try:
                name = open(sysname).read().strip()
            except OSError:
                name = os.path.basename(path)
        except OSError:
            continue
        devices[fh.fileno()] = (path, name)
        fds.append(fh)

    with open("/tmp/keylog.txt", "a") as out:
        out.write("=== keylog started, %d devices, %.0fs ===\n" % (len(devices), DURATION))
        out.flush()
        end = time.time() + DURATION
        while time.time() < end:
            ready, _, _ = select.select(fds, [], [], 1.0)
            for fh in ready:
                try:
                    data = fh.read(EVI.size)
                except OSError:
                    continue
                if not data or len(data) < EVI.size:
                    continue
                _, _, type_, code, value = EVI.unpack(data)
                path, name = devices[fh.fileno()]
                if type_ == 0:
                    continue  # SYN
                if value == 0 or type_ != 1:
                    line = "%-11s %-28s %-24s value=%d" % (
                        time.strftime("%H:%M:%S"), name, label(type_, code), value)
                    out.write(line + "\n")
                    if type_ == 1:
                        out.flush()
                else:
                    out.write("%-11s %-28s %-24s value=%d\n" % (
                        time.strftime("%H:%M:%S"), name, label(type_, code), value))
        out.write("=== keylog finished ===\n")


if __name__ == "__main__":
    main()
