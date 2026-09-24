#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Windows string catalog (plans/native-ui-winui DECISIONS.md D20, UX.md section 9).

`generate` derives apps/windows/TidyVNC/Strings/en-US/Resources.resw from the
macOS catalog (apps/macos/Localizable.xcstrings) and the Windows rules in
Strings/windows.json:

- resource names are the macOS keys with dots replaced by underscores;
- macOS `%@`/`%u`/`%lld` placeholders become .NET composite `{0}`, `{1}`, ...;
- title-style labels become Windows sentence case, and the same labels quoted
  inside sentences follow them;
- `overrides` replace the wording of individual keys (already in .NET format);
- `macOnly` keys are left out, `windowsOnly` keys are added;
- a key whose macOS text names a macOS term (Mac, Keychain, Finder, Return,
  sheet, ...) must be overridden, left out or listed in `reviewed`.

`audit` checks the generated file is current, that every key the Windows
sources reference exists, and lists macOS keys the sources never use.
`pseudo` writes the qps-ploc (expanded) and qps-plocm (mirrored) catalogs for
layout checks. Exit status is non-zero on any failure.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "apps" / "macos" / "Localizable.xcstrings"
STRINGS = ROOT / "apps" / "windows" / "TidyVNC" / "Strings"
RULES = STRINGS / "windows.json"
OUTPUT = STRINGS / "en-US" / "Resources.resw"
SOURCES = [ROOT / "apps" / "windows" / "TidyVNC", ROOT / "platform" / "windows" / "TidyVNC.Native"]

# Words that keep their capitals in sentence case.
PROPER = {
    "TidyVNC", "VNC", "SSH", "TLS", "X.509", "X509", "RSA", "AES", "IPv4", "IPv6", "TCP", "UDP", "Unix", "Windows",
    "TigerVNC", "Ed25519", "ECDSA", "GnuTLS", "JPEG", "ZRLE", "Tight", "Hextile", "RRE", "CopyRect", "Raw", "Ctrl",
    "Alt", "Shift", "Enter", "Esc", "Tab", "Del", "Space", "Super", "UTF-8", "SHA-256", "SHA-1", "MD5", "CA", "CRL",
    "DNS", "URL", "ID", "IDs", "OK", "SASL", "VeNCrypt", "PC", "RFB",
    "I", "Ed448", "DSA", "IPv4:", "IPv6:", "HD", "4K", "Narrator", "AltGr", "F1", "F11", "PEM", "DER", "API",
}
# macOS terms a Windows string must not carry over unreviewed.
MAC_TERMS = re.compile(
    r"\b(Mac|macOS|Keychain|Finder|Option|Dock|Return|Application Support|Accessibility|Local Network|"
    r"points?|System Settings|pasteboard|Quit|menu bar|sheet|Retina|Spaces|Mission Control|Command(?![- ][Ll]ine)|Control)\b|[⌘⌥⌃⇧]")
PLACEHOLDER = re.compile(r"%(?:@|u|lld|ld|d)")
SMALL = {"a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "per", "the", "to", "via", "with"}


def load_catalog() -> dict[str, str]:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    result = {}
    for key, entry in data["strings"].items():
        unit = entry["localizations"]["en"]["stringUnit"]
        if unit.get("state") not in (None, "translated"):
            raise SystemExit(f"{key}: English value is not final")
        result[key] = unit["value"]
    return result


def load_rules() -> dict:
    rules = json.loads(RULES.read_text(encoding="utf-8"))
    unknown = set(rules) - {"comment", "macOnly", "overrides", "windowsOnly", "reviewed", "keepCase"}
    if unknown:
        raise SystemExit(f"windows.json: unknown sections {sorted(unknown)}")
    return rules


def resource_name(key: str) -> str:
    return key.replace(".", "_")


def dotnet_format(text: str) -> str:
    """macOS printf placeholders to .NET composite placeholders, escaping braces."""
    text = text.replace("{", "{{").replace("}", "}}")
    index = iter(range(100))
    return PLACEHOLDER.sub(lambda _: "{%d}" % next(index), text)


# Windows terminology (Microsoft Writing Style Guide): "full screen" is the
# noun, "full-screen" the adjective. Applied to generated text, not overrides.
TERMINOLOGY = [
    (re.compile(r"\bor fullscreen this window\b"), "or make this window full screen"),
    (re.compile(r"\b([Ff])ullscreen (?=(?:display|displays|mode|surface|surfaces|bar|arrangement|connection|window|windows)\b)"),
     lambda m: m.group(1) + "ull-screen "),
    (re.compile(r"\b([Ff])ullscreen\b"), lambda m: m.group(1) + "ull screen"),
    # Windows calls a display's density its scale.
    (re.compile(r"\bbacking scale\b"), "scale"),
]


def windows_terms(text: str) -> str:
    for pattern, replacement in TERMINOLOGY:
        text = pattern.sub(replacement, text)
    return text


def is_title(text: str) -> bool:
    words = [w for w in re.split(r"\s+", text.strip().rstrip("…").strip()) if w]
    if len(words) < 2 or text.rstrip().endswith((".", ":", "?", "!")) or "{" in text:
        return False
    significant = [w for w in words if w.lower() not in SMALL]
    capitalized = [w for w in significant if w[:1].isupper() or not w[:1].isalpha()]
    return len(significant) >= 2 and len(capitalized) == len(significant) and \
        sum(1 for w in words[1:] if w[:1].isupper() and w not in PROPER and w.strip("()…,") not in PROPER) >= 1


def sentence_case(text: str) -> str:
    words = text.split(" ")
    out = []
    for i, word in enumerate(words):
        bare = word.strip("()…,:“”\"'")
        if i == 0 or bare in PROPER or (len(bare) > 1 and bare.isupper()) or any(c.isdigit() for c in bare[1:2]):
            out.append(word)
        elif re.fullmatch(r"[A-Z][a-z’']*", bare.split("-")[0]) and \
                all(re.fullmatch(r"[A-Za-z][a-z’']*", part) for part in bare.split("-")[1:]):
            # Capitalized words, including hyphenated ones (Command-Line, Built-In).
            out.append(word.replace(bare, "-".join(p[:1].lower() + p[1:] for p in bare.split("-")), 1))
        else:
            out.append(word)
    return " ".join(out)


def build() -> tuple[dict[str, str], list[str]]:
    catalog = load_catalog()
    rules = load_rules()
    mac_only = set(rules.get("macOnly", []))
    overrides: dict[str, str] = rules.get("overrides", {})
    windows_only: dict[str, str] = rules.get("windowsOnly", {})
    reviewed = set(rules.get("reviewed", []))
    keep_case = set(rules.get("keepCase", []))
    problems = []
    for section, keys in (("macOnly", mac_only), ("overrides", overrides), ("reviewed", reviewed), ("keepCase", keep_case)):
        for key in keys:
            if key not in catalog:
                problems.append(f"{section}: {key} is not a macOS key")
    for key in windows_only:
        if key in catalog:
            problems.append(f"windowsOnly: {key} exists in the macOS catalog; use overrides")

    # Pass 1: title-style labels to sentence case.
    labels = {}
    for key, text in catalog.items():
        if key in mac_only or key in overrides or key in keep_case:
            continue
        if is_title(text):
            labels[text] = sentence_case(text)
    # Overridden labels (Enter Full Screen -> Full screen) are quoted the same way in sentences.
    quoted = dict(labels)
    for key, text in overrides.items():
        if key in catalog and is_title(catalog[key]) and "{" not in text:
            quoted[catalog[key]] = text
    phrases = sorted(((t, s) for t, s in quoted.items() if t != s and len(t.split()) >= 2), key=lambda p: -len(p[0]))

    result: dict[str, str] = {}
    for key, text in catalog.items():
        if key in mac_only:
            continue
        if key in overrides:
            result[key] = overrides[key]
            continue
        if MAC_TERMS.search(text) and key not in reviewed:
            problems.append(f"{key}: macOS wording needs an override, macOnly or reviewed entry: {text!r}")
        if key in keep_case:
            value = text
        elif text in labels:
            value = labels[text]
        else:
            value = text
            for title, sentence in phrases:
                value = value.replace(title, sentence)
        result[key] = dotnet_format(windows_terms(value))
    for key, text in windows_only.items():
        result[key] = text
    for key, text in result.items():
        if MAC_TERMS.search(text) and key not in reviewed:
            problems.append(f"{key}: Windows text still uses a macOS term: {text!r}")
        try:
            text.format(*["x"] * 20)
        except (IndexError, ValueError) as error:
            problems.append(f"{key}: invalid .NET format string ({error}): {text!r}")
    names = {}
    for key in result:
        name = resource_name(key).lower()  # MRT names are case-insensitive.
        if name in names:
            problems.append(f"{key}: resource name collides with {names[name]}")
        names[name] = key
    return result, problems


def render(strings: dict[str, str]) -> str:
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<!-- Generated by apps/windows/strings.py from apps/macos/Localizable.xcstrings and",
        "     Strings/windows.json. Do not edit; run `python apps/windows/strings.py generate`. -->",
        "<root>",
        '  <resheader name="resmimetype"><value>text/microsoft-resx</value></resheader>',
        '  <resheader name="version"><value>2.0</value></resheader>',
        '  <resheader name="reader"><value>System.Resources.ResXResourceReader, System.Windows.Forms, '
        'Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>',
        '  <resheader name="writer"><value>System.Resources.ResXResourceWriter, System.Windows.Forms, '
        'Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>',
    ]
    for key in sorted(strings, key=resource_name):
        lines.append(f'  <data name="{resource_name(key)}" xml:space="preserve"><value>{escape(strings[key])}</value></data>')
    lines.append("</root>")
    return "\n".join(lines) + "\n"


# Key references in the Windows sources: NativeText("key"...), Strings.Get/Format("key"...),
# and {s:Str Key=key} in XAML.
REFERENCE = re.compile(r'(?:NativeText(?:\.Of)?\(|Strings\.(?:Get|Format)\()"([a-zA-Z][\w.]*\.[\w.]+)"|Str Key=([a-zA-Z][\w.]*)')


def references() -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for base in SOURCES:
        for path in sorted(base.rglob("*")):
            if path.suffix not in (".cs", ".xaml") or "obj" in path.parts or "bin" in path.parts:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                for match in REFERENCE.finditer(line):
                    key = match.group(1) or match.group(2)
                    found.setdefault(key, []).append(f"{path.relative_to(ROOT)}:{number}")
    return found


def pseudo(strings: dict[str, str], mirrored: bool) -> dict[str, str]:
    accents = str.maketrans("aeiouAEIOUcnyCNY", "àéîõüÀÉÎÕÜçñýÇÑÝ")
    result = {}
    for key, text in strings.items():
        parts = re.split(r"(\{\d+\}|\{\{|\}\})", text)
        body = "".join(p if re.fullmatch(r"\{\d+\}|\{\{|\}\}", p) else p.translate(accents) for p in parts)
        pad = "~" * max(2, len(text) * 2 // 5)  # About 40% longer, as translations can be.
        result[key] = ("‮" + body + pad + "‬") if mirrored else ("[" + body + pad + "]")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["generate", "audit", "pseudo"])
    args = parser.parse_args()
    strings, problems = build()
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    text = render(strings)
    if args.command == "generate":
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(text, encoding="utf-8", newline="\n")
        print(f"{OUTPUT.relative_to(ROOT)}: {len(strings)} strings")
        return 0
    if args.command == "pseudo":
        for locale, mirrored in (("qps-ploc", False), ("qps-plocm", True)):
            path = STRINGS / locale / "Resources.resw"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(render(pseudo(strings, mirrored)), encoding="utf-8", newline="\n")
            print(f"{path.relative_to(ROOT)}: {len(strings)} strings")
        return 0
    failed = False
    # Compare content, not the line endings a checkout may have converted.
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8").replace("\r\n", "\n") != text:
        print(f"{OUTPUT.relative_to(ROOT)} is stale; run `python apps/windows/strings.py generate`", file=sys.stderr)
        failed = True
    used = references()
    for key, places in sorted(used.items()):
        if key not in strings:
            print(f"missing: {key} ({', '.join(places[:3])})", file=sys.stderr)
            failed = True
    catalog = load_catalog()
    rules = load_rules()
    unused = sorted(k for k in catalog if k not in used and k not in rules.get("macOnly", []))
    print(f"{len(strings)} Windows strings; {len(used)} referenced; "
          f"{len(rules.get('macOnly', []))} macOS-only; {len(unused)} macOS keys not yet used on Windows")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
