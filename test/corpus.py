#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the media test's disk images and Harness scripts: scenarios of control
words and SCSI request packets.

  corpus.py <work dir>    writes <work dir>/images and <work dir>/scripts

Everything is built from a SHA-256 counter, not Python's random module, and the
scripts name images by relative path, so every machine writes the same bytes and
one set of recorded replies (expected.sha256) checks them all. Harness runs from
the images directory.

Reads are capped at 64 sectors: the Intel library overruns its reply buffer
beyond that, and the viewer never asks for more.
"""
import hashlib, os, struct, sys

SECTOR = 2048
work = sys.argv[1]
images, out = os.path.join(work, "images"), os.path.join(work, "scripts")
os.makedirs(images, exist_ok=True)
os.makedirs(out, exist_ok=True)


class Rng:
    """A deterministic stream: the same on every Python and platform."""

    def __init__(self, seed):
        self.seed, self.n, self.buf = str(seed).encode(), 0, b""

    def randbytes(self, k):
        chunks, have = [self.buf], len(self.buf)
        while have < k:
            chunks.append(hashlib.sha256(self.seed + struct.pack(">Q", self.n)).digest())
            self.n += 1
            have += 32
        b = b"".join(chunks)
        self.buf = b[k:]
        return b[:k]

    def random(self):
        return int.from_bytes(self.randbytes(7), "big") / (1 << 56)

    def randrange(self, n):
        return int.from_bytes(self.randbytes(8), "big") % n

    def choice(self, seq):
        return seq[self.randrange(len(seq))]


rng = Rng(51)


def write_image(name, data):
    with open(os.path.join(images, name), "wb") as f:
        f.write(data)


def iso(sectors):
    """Random sectors, with an ISO 9660 primary volume descriptor at sector 16:
    the only part of the format the CD library checks."""
    data = bytearray(rng.randbytes(sectors * SECTOR))
    data[16 * SECTOR:16 * SECTOR + 7] = b"\x01CD001\x01"
    return bytes(data)


# Two whole images, then cut-down and broken ones for the error paths.
small, big = iso(450), iso(10000)
write_image("small.iso", small)
write_image("big.iso", big)
write_image("tiny.img", small[:40 * SECTOR])                # 40 whole sectors
write_image("odd.img", small[:40 * SECTOR + 1000])          # ends mid-sector
write_image("short.img", small[:16 * SECTOR + 100])         # no whole sector 16
write_image("notiso.img", bytes(1000000))


def ctl(*words):
    return ("CTL:" + " ".join(words)).encode().ljust(1024, b"\0")


def request(opcode, lba=0, count=0, lun=0, seq=1, cdb=None, wild=False):
    hdr = bytearray(32)
    hdr[0:8] = b"IUSB    "
    hdr[8:11] = bytes([1, 0, 32])
    struct.pack_into("<I", hdr, 12, 30)
    hdr[17:20] = bytes([5, 1, 0x80])
    struct.pack_into("<I", hdr, 24, seq)
    hdr[11] = -sum(hdr) & 0xFF
    c = bytearray(cdb if cdb is not None else rng.randbytes(12) if wild else bytes(12))
    c[0], c[1] = opcode, lun
    struct.pack_into(">I", c, 2, lba)
    if opcode in (0x28, 0xA8) or cdb is None:
        struct.pack_into(">H", c, 7, count)
    if wild:  # the library must copy all of this through untouched
        if rng.random() < 0.5:
            hdr = bytearray(rng.randbytes(32))
        body = rng.randbytes(9) + bytes(c) + rng.randbytes(8)
        tail = rng.randbytes(1024 - 61)
    else:
        body = bytes(9) + bytes(c) + bytes(8)
        tail = bytes(1024 - 61)
    return bytes(hdr) + body + tail


def fuzz(sectors, n):
    recs = []
    lbas = [0, 1, 15, 16, 17, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF] + [max(0, sectors + d) for d in range(-66, 3)]
    for i in range(n):
        r = rng.random()
        lun = rng.choice([0, 0, 2, rng.randrange(256)])
        wild = rng.random() < 0.4
        if r < 0.40:
            lba = rng.choice(lbas) if rng.random() < 0.5 else rng.randrange(max(1, sectors))
            count = rng.choice([0, 1, 1, 2, 3, 8, 16, 32, 63, 64, rng.randrange(65)])
            recs.append(request(rng.choice([0x28, 0x28, 0x28, 0xA8]), lba, count, lun, i, wild=wild))
        elif r < 0.55:
            recs.append(request(0x00, lun=lun, seq=i, wild=wild))
        elif r < 0.65:
            recs.append(request(0x25, rng.randrange(1 << 32), rng.randrange(1 << 16), lun, i, wild=wild))
        elif r < 0.80:
            c = bytearray(rng.randbytes(12))
            c[6] = rng.choice([0, 1, 2, 0xAA, rng.randrange(256)])
            room = rng.choice([0, 1, 2, 3, 4, 5, 11, 12, 13, 19, 20, 21, 255, 0xFFFF, rng.randrange(1 << 16)])
            struct.pack_into(">H", c, 7, room)
            recs.append(request(0x43, struct.unpack_from(">I", c, 2)[0], lun=lun, seq=i, cdb=c, wild=wild))
        elif r < 0.85:
            recs.append(request(0x1B, rng.randrange(1 << 32), rng.randrange(1 << 16), lun, i, wild=wild))
        else:
            op = rng.randrange(256)
            count = rng.randrange(65) if op in (0x28, 0xA8) else rng.randrange(1 << 16)
            recs.append(request(op, rng.randrange(1 << 32), count, lun, i, wild=wild))
    return recs


def sectors(name):
    return os.path.getsize(os.path.join(images, name)) // SECTOR


def write(name, recs):
    with open(os.path.join(out, name + ".script"), "wb") as f:
        f.write(b"".join(recs))


first = {"tur": request(0x00), "cap": request(0x25), "read": request(0x28, 16, 1), "toc": request(0x43, count=20),
         "start": request(0x1B), "bogus": request(0xEE)}
# What the first few commands after an open are decides when the "medium
# changed" report and the swallowed first command happen: try every opening.
names = sorted(first)
for a in names:
    recs = [ctl("NEW", "image"), ctl("INFO"), ctl("OPEN", "small.iso")]
    for b in names:
        recs += [first[a], first[b], first["tur"], first["cap"], first["read"], first["toc"],
                 ctl("CLOSE"), first["tur"], ctl("OPEN", "small.iso")]
    write("opening-" + a, recs + [ctl("CLOSE"), ctl("DELETE")])

for image in ("small.iso", "big.iso", "odd.img", "tiny.img"):
    write("fuzz-" + image.split(".")[0],
          [ctl("NEW", "image"), ctl("OPEN", image)] + fuzz(sectors(image), 4000) + [ctl("CLOSE"), ctl("DELETE")])

few = lambda: fuzz(450, 12)
write("opens", [request(0x00), ctl("INFO"), ctl("OPEN", "small.iso"), ctl("NEW", "image"), ctl("INFO")] + few()
      + [ctl("OPEN", "short.img")] + few() + [ctl("OPEN", "notiso.img")] + few()
      + [ctl("OPEN", "missing.iso")] + few() + [ctl("OPEN", "x" * 300)] + few()
      + [ctl("OPEN", "small.iso")] + few() + [ctl("OPEN", "big.iso")] + few()
      + [ctl("CLOSE")] + few() + [ctl("CLOSE"), ctl("OPEN", "big.iso")] + fuzz(sectors("big.iso"), 200)
      + [ctl("CLOSE"), ctl("DELETE"), ctl("INFO"), ctl("NEW", "image"), ctl("NEW", "image"), ctl("INFO"), ctl("DELETE")])

# The image disappears, comes back, and is swapped for a different one mid-session.
write("swap", [ctl("COPY", "small.iso", "live.iso"), ctl("NEW", "image"), ctl("OPEN", "live.iso")] + fuzz(450, 60)
      + [ctl("REMOVE", "live.iso")] + fuzz(450, 30) + [ctl("COPY", "small.iso", "live.iso")] + fuzz(450, 60)
      + [ctl("COPY", "tiny.img", "live.iso")] + fuzz(40, 200) + [ctl("COPY", "short.img", "live.iso")] + fuzz(40, 60)
      + [ctl("COPY", "big.iso", "live.iso")] + fuzz(sectors("big.iso"), 200) + [ctl("CLOSE"), ctl("DELETE"),
                                                                                   ctl("REMOVE", "live.iso")])
