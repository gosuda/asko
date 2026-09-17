#!/usr/bin/env python3
"""Redirect Iris v0.32's shared image directory without changing DEX offsets."""
import hashlib
from pathlib import Path
import struct
import zipfile
import zlib

root = Path(__file__).resolve().parent.parent
source = root / ".cache/iris/Iris.apk"
target = root / ".cache/iris/Iris-asko.apk"
expected = "00eaa7800f904b7e3082277525adbbc0581ffe9efdb1c7a475561361f918eab0"
if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
    raise SystemExit("Unexpected upstream Iris APK")
old = b"/sdcard/Android/data/com.kakao.talk/files"
new = b"/data/local/tmp/asko-iris/scratch-images/"
assert len(old) == len(new)
changed = 0
temporary = target.with_suffix(".apk.tmp")
with zipfile.ZipFile(source) as original, zipfile.ZipFile(temporary, "w") as output:
    for entry in original.infolist():
        data = original.read(entry.filename)
        if entry.filename.endswith(".dex") and old in data:
            changed += data.count(old)
            data = bytearray(data.replace(old, new))
            data[12:32] = hashlib.sha1(data[32:]).digest()
            data[8:12] = struct.pack("<I", zlib.adler32(data[12:]) & 0xffffffff)
        output.writestr(entry, data)
if changed != 1:
    temporary.unlink()
    raise SystemExit("Expected exactly one Iris image directory constant")
temporary.replace(target)
print(hashlib.sha256(target.read_bytes()).hexdigest())
