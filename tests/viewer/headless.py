#!/usr/bin/env python3
"""Clean configure/build/test and dependency audit for the portable viewer targets."""
import argparse
import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=pathlib.Path, required=True,
                    help='New directory; existing directories are rejected, never removed')
parser.add_argument('--cmake-arg', action='append', default=[],
                    help='Extra dependency/toolchain argument, e.g. --cmake-arg=-DGTest_DIR=...')
args = parser.parse_args()
build = args.build_dir.resolve()
build.mkdir(parents=True, exist_ok=False)
query = build / '.cmake/api/v1/query'
query.mkdir(parents=True)
(query / 'codemodel-v2').touch()

def run(*command):
    subprocess.run(command, cwd=root, check=True)

run('cmake', '-S', str(root), '-B', str(build), *args.cmake_arg,
    '-DBUILD_VIEWER=OFF', '-DBUILD_PLATFORM_APPS=OFF', '-DBUILD_MACOS_NATIVE=OFF',
    '-DENABLE_NLS=OFF', '-DENABLE_AUDIO=OFF', '-DENABLE_H264=OFF',
    '-DCMAKE_DISABLE_FIND_PACKAGE_FLTK=TRUE',
    '-DCMAKE_DISABLE_FIND_PACKAGE_X11=TRUE',
    '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON')

# Inspect the generated graph, not just top-level target_link_libraries text.
reply = build / '.cmake/api/v1/reply'
index = json.loads(max(reply.glob('index-*.json')).read_text())
model = json.loads((reply / index['reply']['codemodel-v2']['jsonFile']).read_text())
configuration = model['configurations'][0]
refs = {entry['id']: entry for entry in configuration['targets']}
names = {entry['name']: entry['id'] for entry in configuration['targets']}
for forbidden in ['vncviewer', 'winvnc', 'vncconfig', 'x0vncserver', 'w0vncserver']:
    if forbidden in names:
        raise RuntimeError(f'Headless build contains platform app: {forbidden}')
seen = set()
forbidden = re.compile(r'FLTK|fltk::|/FL/|["<]FL/|["<]vncviewer/|(?:^|[/\\])vncviewer(?:[/\\])|'
                       r'AppKit|Cocoa|Carbon|SwiftUI|WinUI|["<]X11/', re.I)
pending = [names['viewer-core-smoke'], names['viewer-c-abi-smoke']]
while pending:
    target_id = pending.pop()
    if target_id in seen:
        continue
    seen.add(target_id)
    target = json.loads((reply / refs[target_id]['jsonFile']).read_text())
    for field in ['compileGroups', 'link']:
        if forbidden.search(json.dumps(target.get(field, {}))):
            raise RuntimeError(f'GUI dependency in {target["name"]}: {field}')
    for source in target.get('sources', []):
        path = pathlib.Path(source['path'])
        if not path.is_absolute():
            path = root / path
        if forbidden.search(str(path)):
            raise RuntimeError(f'Frontend source in portable graph: {path}')
        if path.is_file():
            for line in path.read_text().splitlines():
                if re.match(r'\s*#\s*include', line) and forbidden.search(line):
                    raise RuntimeError(f'GUI include in {path}: {line}')
    pending.extend(entry['id'] for entry in target.get('dependencies', []))
for name in ['tidyvnc_viewer_c', 'tidyvnc_viewer_core', 'tidyvnc_viewer_platform', 'rfbclient', 'network']:
    if names[name] not in seen:
        raise RuntimeError(f'Smoke consumer does not exercise {name}')
if names.get('rfbserver') in seen:
    raise RuntimeError('Viewer core must not depend on the server implementation')
for header in (root / 'viewer').rglob('*.h'):
    for line in header.read_text().splitlines():
        if re.match(r'\s*#\s*include', line) and forbidden.search(line):
            raise RuntimeError(f'GUI include in public header {header}: {line}')
print('Portable dependency graph:', ', '.join(sorted(refs[x]['name'] for x in seen)), flush=True)
run('cmake', '--build', str(build), '--parallel', '4')
run('ctest', '--test-dir', str(build / 'tests/viewer'), '--output-on-failure', '--no-tests=error')
if (build / 'tests/unit/CTestTestfile.cmake').exists():
    run('ctest', '--test-dir', str(build / 'tests/unit'), '--output-on-failure', '--no-tests=error')
print('Clean headless build, dependency audit and tests passed.', flush=True)
