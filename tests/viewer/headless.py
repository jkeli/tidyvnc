#!/usr/bin/env python3
"""Clean configure/build/test and dependency audit for the portable viewer targets."""
import argparse
import json
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=pathlib.Path, required=True,
                    help='New directory; existing directories are rejected, never removed')
parser.add_argument('--cmake-arg', action='append', default=[],
                    help='Extra dependency/toolchain argument, e.g. --cmake-arg=-DGTest_DIR=...')
parser.add_argument('--arch', choices=('x64', 'arm64'), default='x64',
                    help='Windows only: target architecture for the MSVC build')
args = parser.parse_args()
build = args.build_dir.resolve()
build.mkdir(parents=True, exist_ok=False)
query = build / '.cmake/api/v1/query'
query.mkdir(parents=True)
(query / 'codemodel-v2').touch()

# Windows mode (plans/native-ui-winui CORE.md section 7): MSVC through
# vcvarsall, Ninja, and the staged dependency prefixes unless given.
environment = None
platform_args = []
windows = sys.platform == 'win32'
if windows:
    sys.path.insert(0, str(root / 'apps/windows'))
    import toolchain
    environment = toolchain.environment(args.arch)
    platform_args = ['-G', 'Ninja', *toolchain.cmake_compilers(args.arch)]
    if not any(a.startswith('-DCMAKE_PREFIX_PATH') for a in args.cmake_arg):
        prefixes = [root / 'build/winui/deps' / args.arch,
                    root / 'build/vcpkg_installed' / f'{args.arch}-windows']
        platform_args.append('-DCMAKE_PREFIX_PATH=' + ';'.join(p.as_posix() for p in prefixes))
    platform_args.append('-DCMAKE_BUILD_TYPE=Debug')

def run(*command):
    subprocess.run(command, cwd=root, check=True, env=environment)

run('cmake', '-S', str(root), '-B', str(build), *platform_args, *args.cmake_arg,
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
def masked(value):
    # The build and source roots are chosen by the caller (build/winui/...);
    # only paths inside them may reveal a GUI dependency.
    text = json.dumps(value)
    for base in (build, root / 'build/winui', root):
        for spelling in {base.as_posix(), json.dumps(str(base))[1:-1], str(base)}:
            text = text.replace(spelling, '<root>')
    return text
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
        if forbidden.search(masked(target.get(field, {}))):
            raise RuntimeError(f'GUI dependency in {target["name"]}: {field}')
    for source in target.get('sources', []):
        path = pathlib.Path(source['path'])
        if not path.is_absolute():
            path = root / path
        if forbidden.search(masked(str(path))):
            raise RuntimeError(f'Frontend source in portable graph: {path}')
        if path.is_file():
            for line in path.read_text().splitlines():
                if re.match(r'\s*#\s*include', line) and forbidden.search(line):
                    raise RuntimeError(f'GUI include in {path}: {line}')
    pending.extend(entry['id'] for entry in target.get('dependencies', []))
if windows:
    pending = [names['tidyvnc_viewer_shared']]
    while pending:
        target_id = pending.pop()
        if target_id in seen:
            continue
        seen.add(target_id)
        target = json.loads((reply / refs[target_id]['jsonFile']).read_text())
        for field in ['compileGroups', 'link']:
            if forbidden.search(masked(target.get(field, {}))):
                raise RuntimeError(f'GUI dependency in {target["name"]}: {field}')
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
# The public C contract carries only fixed-width values, spans and opaque handles:
# no POSIX, Apple, Objective-C/Swift, Windows or widget types, and no platform
# headers, so a non-Apple frontend consumes exactly the same declarations.
public = (root / 'viewer/bridge/tidyvnc.h').read_text()
includes = re.findall(r'#\s*include\s*[<"]([^>"]+)[>"]', public)
if any(name not in ('stdint.h', 'stddef.h') for name in includes):
    raise RuntimeError(f'Public C header includes a platform header: {includes}')
declarations = re.sub(r'/\*.*?\*/', '', public, flags=re.S)
leaked = sorted(set(re.findall(
    r'\b(pthread_\w+|sockaddr\w*|socklen_t|pid_t|ssize_t|off_t|FILE|time_t|timeval|timespec|dispatch_\w+|'
    r'CF\w+Ref|NS[A-Z]\w+|BOOL|HWND|HANDLE|DWORD|wchar_t|bool|long|size_t|Fl_\w+)\b', declarations)))
if leaked:
    raise RuntimeError(f'Public C header exposes platform or non-fixed-width types: {leaked}')
# Every exported function carries exactly the TIDYVNC_API export annotation,
# and it is the only macro the header defines apart from constants.
unannotated = re.findall(r'^(?!TIDYVNC_API )\w[\w ]*\btidyvnc_\w+\([^;]*\);', declarations, re.M)
if unannotated:
    raise RuntimeError(f'Public C functions without TIDYVNC_API: {unannotated[:5]}')
macros = set(re.findall(r'#\s*define\s+(\w+)\(', public))
if macros:
    raise RuntimeError(f'Public C header defines function-like macros: {sorted(macros)}')
print('Portable dependency graph:', ', '.join(sorted(refs[x]['name'] for x in seen)), flush=True)
run('cmake', '--build', str(build), '--parallel', '4')
run('ctest', '--test-dir', str(build / 'tests/viewer'), '--output-on-failure', '--no-tests=error')
if (build / 'tests/unit/CTestTestfile.cmake').exists():
    run('ctest', '--test-dir', str(build / 'tests/unit'), '--output-on-failure', '--no-tests=error')
print('Clean headless build, dependency audit and tests passed.', flush=True)
