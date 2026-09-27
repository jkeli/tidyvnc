#!/usr/bin/env python3
"""Collect the source of the MSYS2 libraries the Windows app ships, for a release.

TidyVNC is under the GPL, and GnuTLS, Nettle, GMP and several other DLLs that
apps/windows/deps.py stages are under the GPL or LGPL, so their corresponding
source goes with each release (the macOS release carries the archives of its
statically linked libraries the same way). For every package build, MSYS2
publishes a source package, <pkgbase>-<version>.src.tar.zst, holding the
upstream archive, MSYS2's patches and the PKGBUILD that built the binary, with a
detached signature. This script downloads the source package of every package
in deps.json, checks its signature against the keyring pacman trusts for the
binaries, and writes an uncompressed tar:

  sources/<pkgbase>-<version>.src.tar.zst
  sources/<pkgbase>-<version>.src.tar.zst.sig
  <arch>/deps.json
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import toolchain  # noqa: E402

SOURCES = "https://repo.msys2.org/mingw/sources"


def download(url, target):
    partial = target.with_name(target.name + ".part")
    print(f"Downloading {url}", flush=True)
    try:
        with urllib.request.urlopen(url, timeout=120) as response, partial.open("wb") as out:
            shutil.copyfileobj(response, out)
    except OSError as error:
        partial.unlink(missing_ok=True)
        raise SystemExit(f"Could not download {url}: {error}")
    partial.replace(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--arch", choices=toolchain.ARCHES, default="x64")
    parser.add_argument("--msys-root", type=Path, default=Path(r"C:\msys64"))
    parser.add_argument("--deps", type=Path, help="deps.py prefix (default build/winui/deps/<arch>)")
    parser.add_argument("--cache", type=Path, help="Download directory (default build/winui/sources)")
    parser.add_argument("--output", type=Path, required=True, help="The tar to write")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    deps_dir = (args.deps or root / "build/winui/deps" / args.arch).resolve()
    cache = (args.cache or root / "build/winui/sources").resolve()
    manifest = deps_dir / "deps.json"
    deps = json.loads(manifest.read_text())
    if deps["architecture"] != args.arch:
        raise SystemExit(f"{manifest} is for {deps['architecture']}, not {args.arch}")
    try:
        names = sorted({f"{info['base']}-{info['version']}" for info in deps["packages"].values()})
    except KeyError:
        raise SystemExit(f"{manifest} records no pkgbase; run apps/windows/deps.py again")

    gpgv = args.msys_root / "usr/bin/gpgv.exe"
    gnupg = args.msys_root / "etc/pacman.d/gnupg"
    keyring = next((k for k in (gnupg / "pubring.gpg", gnupg / "pubring.kbx") if k.exists()), None)
    if not gpgv.exists() or not keyring:
        raise SystemExit(f"{args.msys_root} lacks gpgv or pacman's keyring (pacman-key --init; pacman-key --populate)")

    cache.mkdir(parents=True, exist_ok=True)
    files = []
    for name in names:
        archive = cache / f"{name}.src.tar.zst"
        signature = archive.with_name(archive.name + ".sig")
        for path in (archive, signature):
            if not path.exists():
                download(f"{SOURCES}/{path.name}", path)
        # gpgv takes a keyring named C:/... for a URL, so it is named relative to the keyring's directory.
        check = subprocess.run([str(gpgv), "--keyring", f"./{keyring.name}", str(signature), str(archive)],
                               cwd=keyring.parent, capture_output=True, text=True, errors="replace")
        if check.returncode:
            archive.unlink()
            signature.unlink()
            raise SystemExit(f"{archive.name} has no valid MSYS2 signature:\n{check.stderr}")
        files += [archive, signature]

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_name(output.name + ".part")
    with tarfile.open(partial, "w", format=tarfile.PAX_FORMAT) as tar:
        for path in files:
            tar.add(path, f"sources/{path.name}")
        tar.add(manifest, f"{args.arch}/deps.json")
    partial.replace(output)
    size = output.stat().st_size / 1e6
    print(f"Wrote {output} ({len(names)} source packages, {size:.1f} MB)")


if __name__ == "__main__":
    main()
