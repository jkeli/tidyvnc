"""Minimal PE reader for the Windows package audit (PACKAGING.md section 5).

Reads what the audit needs without external tools: machine type, whether the
image is managed (a CLR header), the import and delay-import DLL names, the
export names, whether an Authenticode signature is embedded, and the embedded
application manifest. Standard library only, so it runs on any host.
"""
from dataclasses import dataclass, field
from pathlib import Path
import struct

MACHINES = {0x14C: "x86", 0x8664: "x64", 0xAA64: "arm64", 0x1C4: "arm"}
IMAGE_DIRECTORY_EXPORT, IMAGE_DIRECTORY_IMPORT, IMAGE_DIRECTORY_RESOURCE = 0, 1, 2
IMAGE_DIRECTORY_SECURITY, IMAGE_DIRECTORY_DELAY_IMPORT, IMAGE_DIRECTORY_CLR = 4, 13, 14
RT_MANIFEST = 24


class PeError(ValueError):
    pass


@dataclass
class PeImage:
    path: Path
    machine: str
    managed: bool
    imports: list = field(default_factory=list)
    delay_imports: list = field(default_factory=list)
    exports: list = field(default_factory=list)
    signed: bool = False
    manifest: str = ""


def is_pe(path):
    with open(path, "rb") as f:
        head = f.read(64)
    if len(head) < 64 or head[:2] != b"MZ":
        return False
    offset = struct.unpack_from("<I", head, 0x3C)[0]
    with open(path, "rb") as f:
        f.seek(offset)
        return f.read(4) == b"PE\0\0"


def read(path):
    data = Path(path).read_bytes()
    if data[:2] != b"MZ":
        raise PeError(f"{path}: not an MZ image")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise PeError(f"{path}: no PE signature")
    machine, sections, _, _, _, optional_size, _ = struct.unpack_from("<HHIIIHH", data, pe + 4)
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    if magic == 0x10B:
        directories_at, count_at = optional + 96, optional + 92
        base = struct.unpack_from("<I", data, optional + 28)[0]
    elif magic == 0x20B:
        directories_at, count_at = optional + 112, optional + 108
        base = struct.unpack_from("<Q", data, optional + 24)[0]
    else:
        raise PeError(f"{path}: unknown optional header {magic:#x}")
    count = struct.unpack_from("<I", data, count_at)[0]
    directories = [struct.unpack_from("<II", data, directories_at + 8 * i) for i in range(min(count, 16))]
    table = optional + optional_size
    sections_list = [struct.unpack_from("<8sIIII", data, table + 40 * i) for i in range(sections)]

    def offset(rva):
        for _, virtual_size, virtual_address, raw_size, raw_pointer in sections_list:
            if virtual_address <= rva < virtual_address + max(virtual_size, raw_size):
                return raw_pointer + rva - virtual_address
        raise PeError(f"{path}: RVA {rva:#x} outside sections")

    def string(rva):
        start = offset(rva)
        return data[start:data.index(b"\0", start)].decode("ascii", "replace")

    def directory(index):
        return directories[index] if index < len(directories) else (0, 0)

    image = PeImage(Path(path), MACHINES.get(machine, f"{machine:#x}"), directory(IMAGE_DIRECTORY_CLR)[0] != 0)
    image.signed = directory(IMAGE_DIRECTORY_SECURITY)[1] != 0

    rva, size = directory(IMAGE_DIRECTORY_IMPORT)
    if rva:
        at = offset(rva)
        while True:
            lookup, _, _, name, thunk = struct.unpack_from("<IIIII", data, at)
            if not (lookup or name or thunk):
                break
            image.imports.append(string(name))
            at += 20
    rva, size = directory(IMAGE_DIRECTORY_DELAY_IMPORT)
    if rva:
        at = offset(rva)
        while True:
            attributes, name = struct.unpack_from("<II", data, at)
            if not name:
                break
            # Old-style (attribute 0) descriptors hold virtual addresses, not RVAs.
            image.delay_imports.append(string(name if attributes & 1 else name - base))
            at += 32
    rva, size = directory(IMAGE_DIRECTORY_EXPORT)
    if rva:
        at = offset(rva)
        names_count = struct.unpack_from("<I", data, at + 24)[0]
        names_rva = struct.unpack_from("<I", data, at + 32)[0]
        for i in range(names_count):
            image.exports.append(string(struct.unpack_from("<I", data, offset(names_rva) + 4 * i)[0]))
    rva, size = directory(IMAGE_DIRECTORY_RESOURCE)
    if rva:
        image.manifest = _manifest(data, offset(rva), offset)
    return image


def _manifest(data, root, offset):
    """The first RT_MANIFEST resource, as text, or ''."""
    def entries(at):
        named, ids = struct.unpack_from("<HH", data, at + 12)
        for i in range(named + ids):
            name, target = struct.unpack_from("<II", data, at + 16 + 8 * i)
            yield name, target
    for name, target in entries(root):
        if name == RT_MANIFEST and target & 0x80000000:
            level = root + (target & 0x7FFFFFFF)
            for _, second in entries(level):
                language = root + (second & 0x7FFFFFFF)
                for _, leaf in entries(language) if second & 0x80000000 else [(0, second)]:
                    rva, size = struct.unpack_from("<II", data, root + (leaf & 0x7FFFFFFF))
                    raw = data[offset(rva):offset(rva) + size]
                    return raw.decode("utf-8-sig", "replace")
    return ""
