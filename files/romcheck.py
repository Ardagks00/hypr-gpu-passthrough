#!/usr/bin/env python3
"""Check a dumped PCI option ROM (GPU vBIOS).

Usage: romcheck.py ROM_FILE VENDOR_ID DEVICE_ID      (IDs as hex, e.g. 0x10de 0x28a0)

Walks the ROM image chain (0x55AA signature + "PCIR" structure), prints each image and exits 0
when the first image belongs to the expected device. An EFI (type 3) image means the card can
show the UEFI boot screen in the VM; it is reported but not required.
"""
import struct
import sys

TYPES = {0: "x86 BIOS", 1: "Open Firmware", 2: "PA-RISC", 3: "EFI"}


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip())
        return 2
    data = open(sys.argv[1], "rb").read()
    vendor, device = int(sys.argv[2], 16), int(sys.argv[3], 16)
    off, images = 0, []
    while off + 0x1A <= len(data):
        if data[off:off + 2] != b"\x55\xaa":
            off += 512
            continue
        (pcir_off,) = struct.unpack_from("<H", data, off + 0x18)
        p = off + pcir_off
        if p + 0x18 > len(data) or data[p:p + 4] != b"PCIR":
            print(f"@0x{off:x}: ROM signature without a valid PCIR structure")
            break
        ven, dev = struct.unpack_from("<HH", data, p + 4)
        (length,) = struct.unpack_from("<H", data, p + 0x10)
        code_type, indicator = data[p + 0x14], data[p + 0x15]
        extra = ""
        if code_type == 3:
            sig, subsystem, machine = struct.unpack_from("<IHH", data, off + 4)
            extra = f", signature {'ok' if sig == 0x0EF1 else 'BAD'}, machine 0x{machine:04x}"
        print(f"@0x{off:x}: {TYPES.get(code_type, code_type)} image, {ven:04x}:{dev:04x}, {length * 512} bytes{extra}")
        images.append((code_type, ven, dev))
        if indicator & 0x80 or length == 0:
            break
        off += length * 512
    if not images:
        print("No ROM image found (the dump is empty or the card exposes no ROM).")
        return 1
    if (images[0][1], images[0][2]) != (vendor, device):
        print(f"First image is {images[0][1]:04x}:{images[0][2]:04x}, expected {vendor:04x}:{device:04x}.")
        return 1
    print("EFI image: " + ("yes" if any(t == 3 for t, _, _ in images) else "no (the VM shows no boot screen on this GPU)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
