#!/usr/bin/env python3
"""Launch or clean up an isolated copy of the native app for interactive acceptance.

The copy gets a UUID-suffixed bundle identifier (so its CFPreferences domains are
its own), fresh HOME/XDG roots and a relocated Foundation home, exactly like the
protocol baseline. Nothing in the user's own preferences, history, profiles,
Keychain or trust stores is read or written. Credential/tunnel environment inputs
are removed. Cleanup removes only the recorded fixture domains and directory.

  isolated-app.py launch APP.app STATE-DIR [-- viewer arguments]
  isolated-app.py cleanup STATE-DIR
"""
import json
import os
import plistlib
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ISOLATION = HERE.parent / 'integration' / 'native-isolation.swift'
PREFIX = 'io.github.jkeli.tidyvnc.protocol-fixture.'


def helper(state):
    binary = state / 'isolation'
    if not binary.exists():
        subprocess.run(['xcrun', 'swiftc', str(ISOLATION), '-o', str(binary)], check=True)
    return binary


def environment(state):
    env = os.environ.copy()
    for name in ['VNC_USERNAME', 'VNC_PASSWORD', 'VNC_VIA_CMD', 'CFFIXED_USER_HOME',
                 '__CFPREFERENCES_AVOID_DAEMON', 'SSH_AUTH_SOCK']:
        env.pop(name, None)
    for name in ['HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME']:
        directory = state / name
        directory.mkdir(exist_ok=True)
        env[name] = str(directory)
    env['CFFIXED_USER_HOME'] = env['HOME']
    return env


def seed(state, files):
    """Writes {state-relative path: text} (0600, parents 0700), e.g. XDG_CONFIG_HOME/tidyvnc/..."""
    for relative, text in (files or {}).items():
        path = state / relative
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_text(text); path.chmod(0o600)


def launch(source, state, arguments, extra_env=None, home_files=None, state_files=None):
    """home_files maps HOME-relative and state_files state-relative paths to text,
    written with seed() before launch."""
    state.mkdir(parents=True, exist_ok=False)
    state = state.resolve()
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'io.github.jkeli.tidyvnc':
        raise SystemExit('Unexpected source bundle identifier')
    domain = PREFIX + str(uuid.uuid4())
    copied = state / 'TidyVNC Acceptance.app'
    subprocess.run(['/usr/bin/ditto', str(source), str(copied)], check=True)
    info['CFBundleIdentifier'] = domain
    (copied / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', domain,
                    '--timestamp=none', str(copied)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(copied)], check=True)
    (state / 'fixture.json').write_text(json.dumps({'domain': domain, 'app': str(copied)}))
    env = environment(state)
    seed(state, {**{'HOME/' + relative: text for relative, text in (home_files or {}).items()}, **(state_files or {})})
    subprocess.run([str(helper(state)), env['HOME'], domain], env=env, check=True, timeout=30)
    log = open(state / 'app.log', 'wb')
    process = subprocess.Popen([str(copied / 'Contents/MacOS' / info['CFBundleExecutable']), *arguments],
                               env={**env, **(extra_env or {})}, stdout=log, stderr=subprocess.STDOUT,
                               start_new_session=True)
    return {'domain': domain, 'pid': process.pid, 'app': str(copied), 'process': process}


def cleanup(state):
    state = state.resolve()
    fixture = json.loads((state / 'fixture.json').read_text())
    domain = fixture['domain']
    if not domain.startswith(PREFIX):
        raise SystemExit('Refusing to clean a non-fixture domain')
    env = environment(state)
    subprocess.run([str(helper(state)), '--cleanup', domain], env=env, check=True, timeout=30)
    shutil.rmtree(state)
    print('Removed fixture domains and', state)


if __name__ == '__main__':
    if len(sys.argv) >= 4 and sys.argv[1] == 'launch':
        extra = sys.argv[4:]
        if extra[:1] == ['--']:
            extra = extra[1:]
        result = launch(Path(sys.argv[2]).resolve(), Path(sys.argv[3]), extra)
        print(json.dumps({key: value for key, value in result.items() if key != 'process'}))
    elif len(sys.argv) == 3 and sys.argv[1] == 'cleanup':
        cleanup(Path(sys.argv[2]))
    else:
        raise SystemExit(__doc__)
