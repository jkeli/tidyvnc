#!/usr/bin/env python3
"""Exercise terminal-only paths of the actual native application executable."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
args = parser.parse_args()
app = args.app.resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
executable = os.fsencode(app / 'Contents/MacOS' / info['CFBundleExecutable'])
version = info['CFBundleShortVersionString'].encode()
with tempfile.TemporaryDirectory(prefix='tidyvnc-terminal-') as temporary:
    root = Path(temporary)
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_DATA_HOME=str(root / 'data'), XDG_STATE_HOME=str(root / 'state'),
               VNC_USERNAME='private-fixture', VNC_PASSWORD='private-env-' * 500,
               VNC_VIA_CMD='private-shell-$(touch should-not-exist)')
    sentinel = root / 'untouched'
    sentinel.write_bytes(b'fixture input remains unchanged')
    cases = [
        ([b'--help'], 1, b'Usage:', True),
        ([b'--version'], 0, b'TidyVNC v' + version, False),
        ([b'-Shared=on', b'--version'], 0, b'TidyVNC v' + version, False),
        ([b'-Shared=private-value', b'--help'], 1, b'invalid value', False),
        ([b'--unknown=private-value'], 1, b'unrecognized', False),
        ([b'-passwd=/private-fixture-path', b'--help'], 1, b'Usage:', True),
        ([b'/private-fixture-path', b'--version'], 0, b'TidyVNC v' + version, False),
        ([b'--version', b'--unknown'], 0, b'TidyVNC v' + version, False),
        ([b'--version', b'\xff'], 1, b'not valid UTF-8', False),
        ([b'-SecurityTypes=VncAuth', b'127.0.0.1::5900'], 1, b'launch credential exceeds', False),
        ([b'-listen'], 1, b'launch credential exceeds', False),
        ([b'-listen', b'65536'], 1, b'listen port must', False),
        ([b'-listen', b'5500private-value'], 1, b'listen port must', False),
        ([b'-listen', b'./private-file'], 1, b'launch credential exceeds', False),
        ([b'-listen', b'-UseIPv4=off', b'-UseIPv6=off'], 1, b'cannot be applied', False),
        ([b'-via=private invalid'], 1, b'cannot be applied', False),
        ([b'-via=private-gateway'], 1, b'VNC_VIA_CMD shell customizations are not supported', False),
        ([b'-via=private-gateway', b'-listen', b'./private-file'], 1, b'cannot be combined with listening', False),
        ([b'-via=private-gateway', b'-via='], 1, b'launch credential exceeds', False),
        ([b'-Log=private-writer:private-target:2147483648', b'-Log=*::0', b'--help'], 1, b'invalid value', False),
        ([b'-Log=private-writer:private-target:-2147483649', b'--version'], 1, b'invalid value', False),
        ([b'-Log=*:stderr:+30tail', b'--version'], 0, b'TidyVNC v' + version, False),
        ([b'-Log=private:stderr:30', b'-Log=*::0', b'--help'], 1, b'cannot be applied', False),
        ([b'-Log=*:file:30', b'--help'], 1, b'Usage:', True),
        ([b'-Log=*:syslog:30', b'--help'], 1, b'native adapter', False),
        ([b'-Log=*::0', b'--help'], 1, b'Usage:', True),
        ([b'-geometry=bad', b'-geometry=800x600', b'/private-fixture-path'], 1, b'cannot be applied', False),
        ([b'-geometry=2147483648x1'], 1, b'cannot be applied', False),
        ([b'-Maximize=private-value', b'--help'], 1, b'invalid value', False),
        ([b'-geometry=800x600', b'-Maximize', b'--version'], 0, b'TidyVNC v' + version, False),
        ([b'private-host::0'], 1, b'address is invalid', False),
        ([b'-Shared', b'A' * 65537], 1, b'byte limit', False),
    ]
    for index, (arguments, code, expected, help_output) in enumerate(cases, 1):
        result = subprocess.run([executable, *arguments], env=env, cwd=root,
                                capture_output=True, timeout=10)
        assert result.returncode == code, f'case {index}: wrong exit status'
        assert expected in result.stderr and not result.stdout, f'case {index}: wrong output'
        assert (b'Usage:' in result.stderr) == help_output, f'case {index}: wrong terminal routing'
        assert b'private-' not in result.stderr, f'case {index}: reflected input'
        if help_output:
            assert b'MaxCutText <value> [default: 262144]\n' in result.stderr, 'wrong native clipboard limit default'
            assert b'PointerEventInterval <value> [default: 17]\n' in result.stderr, 'wrong native pointer timing default'
            assert b'  geometry <value>\n' in result.stderr, 'missing native geometry adapter'
            assert b'  Log <value> [default: *:stderr:30]\n' in result.stderr, 'missing process logging adapter'
            assert b'  via <value>\n' in result.stderr, 'missing native SSH adapter'
            assert b'Supported ~/.ssh/config settings are captured before connecting; commands, proxy hops and VNC_VIA_CMD are unsupported.' in result.stderr
            assert b'File: /tmp/vncviewer.log, created on first output with one .bak; failures use stderr.' in result.stderr
            for name in (b'UseIPv4', b'UseIPv6', b'Maximize', b'listen'):
                assert b'  ' + name + b' [on|off]\n' in result.stderr, 'missing native network adapter'
    assert sorted(path.name for path in root.iterdir()) == ['untouched'], 'terminal path created state'
    assert sentinel.read_bytes() == b'fixture input remains unchanged', 'terminal path changed input'
print(f'PASS {len(cases)} actual executable help/version/error cases; isolated HOME/XDG unchanged')
