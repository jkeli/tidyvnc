#!/usr/bin/env python3
"""Exact source/path branding ledger and attribution regression check.

The ledger's replace/migrate entries are visible deferred debt, not acceptance.
No source-directory exemptions. Ledger files themselves are data, not products.
"""
import collections, hashlib, json, pathlib, re, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[2]
ledger_path = 'tests/fixtures/rebrand-exceptions.json'
attribution_path = 'tests/fixtures/rebrand-attribution.json'
pattern = re.compile(r'tiger[-_ ]?vnc', re.I)

def scan():
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
    occurrences = collections.Counter()
    for name in sorted(set(names) - {'', ledger_path, attribution_path}):
        p = root/name
        if not p.is_file(): continue
        if pattern.search(name): occurrences[(name, None)] += 1
        try: text = p.read_text(encoding='utf-8')
        except UnicodeDecodeError: continue
        for line in text.splitlines():
            if pattern.search(line): occurrences[(name, line)] += 1
    return occurrences

def check_attribution():
    baseline = json.loads((root/attribution_path).read_text())
    errors = []
    for name, entry in baseline.items():
        p = root/name
        if 'sha256' in entry:
            if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != entry['sha256']:
                errors.append('Changed license body: '+name)
            continue
        # Plans are statements about notices, not authorship notices themselves.
        if name.startswith('plans/') or name.startswith('po/'): continue
        if not p.is_file():
            if name.startswith('media/'): continue  # Removed original artwork, recorded provenance in media/README.md
            errors.append('Missing attribution source: '+name); continue
        text = p.read_text(errors='replace')
        for line in entry['copyright_lines']:
            if line not in text: errors.append('Changed copyright line: '+name+': '+line)
    # Catalog translator comments and legal translations are checked semantically
    # because msgmerge wraps quoted lines and refreshes stale English msgids.
    commit = json.loads((root/ledger_path).read_text())['baseline']
    for p in sorted((root/'po').glob('*.po')):
        name = p.relative_to(root).as_posix()
        old = subprocess.check_output(['git', 'show', f'{commit}:{name}'], cwd=root).decode()
        new = p.read_text()
        old_comments = [line for line in old.splitlines() if line.startswith('# ') and ('@' in line or 'Copyright' in line)]
        for line in old_comments:
            if line not in new: errors.append('Changed translator/attribution comment: '+name+': '+line)
        # Every original translation containing the old product in an About
        # message with a copyright year remains, including fuzzy translations.
        for block in old.split('\n\n'):
            if 'msgstr' not in block or '1999' not in block: continue
            original = decode_po_field(block, 'msgstr')
            if original and original not in decoded_po(new):
                errors.append('Changed translated legal/About text: '+name)
    return errors

def decode_po_field(block, field):
    lines = block.splitlines(); values = []; active = False
    for line in lines:
        line = re.sub(r'^#~ ?', '', line)
        if line.startswith(field+' '): active=True; line=line[len(field)+1:]
        elif not line.startswith('"'): active=False
        if active:
            try: values.append(json.loads(line))
            except (ValueError, TypeError): pass
    return ''.join(values)

def decoded_po(text):
    return [decode_po_field(block, 'msgstr') for block in text.split('\n\n')]

def main():
    ledger = json.loads((root/ledger_path).read_text())
    expected = collections.Counter({(e['path'], e['text']):e['count'] for e in ledger['entries']})
    actual = scan()
    errors = []
    for (path, text), count in (actual-expected).items():
        errors.append(f'Unexplained old-brand occurrence ({count}): {path}: {text}')
    for (path, text), count in (expected-actual).items():
        errors.append(f'Stale ledger entry ({count}): {path}: {text}')
    errors += check_attribution()
    # Removed assets must never return as active runtime/build references.
    removed = re.compile(r'tigervnc(?:_\d+)?\.(?:png|svg|ico|icns)')
    for (path, text) in actual:
        if text and removed.search(text) and (path.startswith(('vncviewer/', 'release/', 'java/', 'media/'))):
            errors.append('Removed asset reference: '+path+': '+text)
    if errors:
        print('\n'.join(errors)); return 1
    debt = sum(e['count'] for e in ledger['entries'] if e['action'] in ('replace','migrate'))
    print(f'Branding ledger and attribution checks passed; {debt} deferred replacement/migration occurrences remain.')
    return 0
if __name__ == '__main__': sys.exit(main())
