#!/usr/bin/env python3
"""
patch_ws_client.py — Tạo NRO J2ME client dùng WebSocket thay raw socket

Cách hoạt động:
  1. Compile WsC.java → a/WsC.class (dùng REPLIT_DEV_DOMAIN)
  2. Patch a/J.class: đổi CP entry "javax/microedition/io/Connector" → "a/WsC"
     → Connector.open(url) trở thành WsC.open(url)
  3. Thêm a/WsC.class vào JAR
  4. Xuất JAR mới

Usage:
  python3 patch_ws_client.py [replit_domain]
  # nếu không truyền domain, đọc từ env REPLIT_DEV_DOMAIN
"""

from __future__ import annotations
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────
TOOLS_DIR  = Path(__file__).parent
SOURCE_JAR = TOOLS_DIR.parent.parent / "attached_assets" / "nrmod_1784777142804_bore20445.jar"
OUTPUT_JAR = TOOLS_DIR.parent.parent / "attached_assets" / "nrmod_ws.jar"
WSC_JAVA   = TOOLS_DIR / "WsC.java"

# Class name to redirect: Connector → WsC
OLD_CLASS = "javax/microedition/io/Connector"
NEW_CLASS = "a/WsC"

# Host placeholder in WsC.java (exactly 64 chars)
PLACEHOLDER = "REPLIT_HOST_PLACEHOLDER_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

# ── Helpers ────────────────────────────────────────────────────────────────

def get_domain() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
    d = os.environ.get("REPLIT_DEV_DOMAIN", "")
    if not d:
        raise SystemExit("REPLIT_DEV_DOMAIN not set and no argument given")
    return d


def patch_wsc_java(domain: str) -> str:
    """Return WsC.java source with domain substituted."""
    src = WSC_JAVA.read_text()
    padded = (domain + "X" * 64)[:64]   # pad/trim to exactly 64 chars
    if PLACEHOLDER not in src:
        raise SystemExit(f"Placeholder '{PLACEHOLDER}' not found in WsC.java")
    return src.replace(PLACEHOLDER, padded)


def compile_wsc(domain: str, tmpdir: Path) -> Path:
    """Compile WsC.java and return path to the .class file."""
    java_src = tmpdir / "WsC.java"
    java_src.write_text(patch_wsc_java(domain))

    # Find javac
    javac = shutil.which("javac")
    if not javac:
        raise SystemExit("javac not found; install JDK")

    # Find javax.microedition stubs - check if they exist in our JAR
    # We'll compile against the JAR itself so the SocketConnection interface is found
    result = subprocess.run(
        [javac, "-source", "8", "-target", "8",
         "-classpath", str(SOURCE_JAR),
         str(java_src)],
        capture_output=True, text=True, cwd=str(tmpdir)
    )
    if result.returncode != 0:
        print("javac stdout:", result.stdout)
        print("javac stderr:", result.stderr)
        raise SystemExit("Compilation failed")
    
    # WsC.class is produced in tmpdir/a/WsC.class
    wsc_class = tmpdir / "a" / "WsC.class"
    if not wsc_class.exists():
        raise SystemExit(f"Expected {wsc_class} after compilation, not found")
    return wsc_class


# ── Constant pool rebuild ─────────────────────────────────────────────────

def rebuild_class_with_patched_class_name(data: bytes, old_name: str, new_name: str) -> bytes:
    """
    Parse the class file constant pool and replace one UTF8 entry
    (the class name string) with a new value, rebuilding the CP bytes.
    All subsequent bytecode uses CP indices (unchanged), so only the
    CP binary layout needs to be re-emitted.
    """
    old_enc = old_name.encode("utf-8")
    new_enc = new_name.encode("utf-8")

    # ── Parse CP ──────────────────────────────────────────────────────────
    magic   = data[:4]    # cafebabe
    version = data[4:8]   # minor + major
    pos = 8
    cp_count = struct.unpack(">H", data[pos:pos+2])[0]
    pos += 2

    entries: list[bytes] = []   # raw bytes for each entry slot (1-indexed; slot 0 empty)
    raw_parts: list[bytes] = [] # raw bytes of each entry as they appear in file

    i = 0
    while i < cp_count - 1:
        tag = data[pos]
        if tag == 1:   # UTF8
            ln = struct.unpack(">H", data[pos+1:pos+3])[0]
            raw = data[pos:pos+3+ln]
            val = data[pos+3:pos+3+ln]
            if val == old_enc:
                # Replace with new name
                new_raw = bytes([1]) + struct.pack(">H", len(new_enc)) + new_enc
                raw_parts.append(new_raw)
                print(f"  ✓ Patched UTF8 cp entry: '{old_name}' → '{new_name}'")
            else:
                raw_parts.append(raw)
            pos += 3 + ln
            i += 1
        elif tag in (7, 8):   # Class, String — 2 bytes
            raw_parts.append(data[pos:pos+3])
            pos += 3; i += 1
        elif tag in (9, 10, 11, 12):  # Fieldref, Methodref, IMethodref, NameAndType — 4 bytes
            raw_parts.append(data[pos:pos+5])
            pos += 5; i += 1
        elif tag in (3, 4):   # Integer, Float — 4 bytes
            raw_parts.append(data[pos:pos+5])
            pos += 5; i += 1
        elif tag in (5, 6):   # Long, Double — 8 bytes, takes 2 slots
            raw_parts.append(data[pos:pos+9])
            raw_parts.append(b"")   # placeholder for slot N+1
            pos += 9; i += 2
        else:
            raise ValueError(f"Unknown CP tag {tag} at byte offset {pos}")

    cp_end = pos

    # ── Rebuild class file ─────────────────────────────────────────────────
    new_cp = b"".join(raw_parts)
    rest   = data[cp_end:]   # access flags, this class, super, interfaces, fields, methods, attrs

    return magic + version + struct.pack(">H", cp_count) + new_cp + rest


# ── Main ───────────────────────────────────────────────────────────────────

def main() -> None:
    domain = get_domain()
    print(f"[patch_ws_client] Domain: {domain}")
    print(f"  Source JAR: {SOURCE_JAR}")
    print(f"  Output JAR: {OUTPUT_JAR}")

    if not SOURCE_JAR.is_file():
        raise SystemExit(f"Source JAR not found: {SOURCE_JAR}")

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)

        # Step 1: Compile WsC.java
        print("\n[1/3] Compiling WsC.java...")
        wsc_class = compile_wsc(domain, tmpdir)
        print(f"  WsC.class: {wsc_class.stat().st_size} bytes")

        # Step 2: Patch a/J.class constant pool
        print("\n[2/3] Patching a/J.class constant pool...")
        with zipfile.ZipFile(SOURCE_JAR, "r") as zin:
            all_entries = {name: zin.read(name) for name in zin.namelist()}

        J_ENTRY = "a/J.class"
        if J_ENTRY not in all_entries:
            raise SystemExit(f"{J_ENTRY} not found in JAR")

        patched_J = rebuild_class_with_patched_class_name(
            all_entries[J_ENTRY], OLD_CLASS, NEW_CLASS
        )
        if patched_J == all_entries[J_ENTRY]:
            print(f"  ⚠ WARNING: no bytes changed — '{OLD_CLASS}' not found in CP")
        else:
            print(f"  ✓ a/J.class: {len(all_entries[J_ENTRY])} → {len(patched_J)} bytes")

        all_entries[J_ENTRY] = patched_J

        # Step 3: Add WsC.class to JAR
        WSC_ENTRY = "a/WsC.class"
        all_entries[WSC_ENTRY] = wsc_class.read_bytes()
        print(f"\n[3/3] Adding {WSC_ENTRY} ({len(all_entries[WSC_ENTRY])} bytes)")

        # Write output JAR
        OUTPUT_JAR.parent.mkdir(parents=True, exist_ok=True)
        tmp_out = OUTPUT_JAR.with_suffix(".tmp.jar")
        with zipfile.ZipFile(tmp_out, "w", compression=zipfile.ZIP_DEFLATED) as zout:
            for name, data in all_entries.items():
                info = zipfile.ZipInfo(name)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.date_time = (2026, 7, 23, 0, 0, 0)
                zout.writestr(info, data)
        shutil.move(tmp_out, OUTPUT_JAR)

    print(f"\n✅ Done → {OUTPUT_JAR}")
    print(f"   Total entries: {len(all_entries)}")


if __name__ == "__main__":
    main()
