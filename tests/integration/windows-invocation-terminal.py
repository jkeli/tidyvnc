#!/usr/bin/env python3
# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
"""Terminal-only paths of the actual vncviewer.exe (plans/native-ui-winui D9,
TODO W0.10; the port of tests/macos/invocation-terminal.py).

Every case runs directly and through cmd.exe, Windows PowerShell and
PowerShell 7 (when installed). Standard error must be byte-identical across
the shells, standard output empty, the exit status the retained one, no input
reflected, and no GUI process, state or file created. Documented platform
differences from the macOS cases:

- A command line is UTF-16, so the invalid-UTF-8 argument case does not exist.
- The 65,537-character argument cannot be passed at all: CreateProcess limits
  a whole command line to 32,767 characters. InvocationLaunchCheckTests checks
  the core's byte limit in-process instead.
- Help names Windows paths (%TMP%\\vncviewer.log, %USERPROFILE%\\.ssh\\config)
  and English text (the console launcher is not localized, like FLTK's).

These paths end in the launcher before TidyVNC.exe starts. A regression
would open a window, so like the UI suite the script runs only with
TIDYVNC_UI_TESTS=1 on a desktop nobody has used for a minute; a stray window
is closed through its close event and the case fails.
"""
import argparse
import ctypes
import os
import subprocess
import tempfile
from pathlib import Path

PWSH = Path(r'C:\Program Files\PowerShell\7\pwsh.exe')
WINDOWS_POWERSHELL = Path(os.environ.get('SystemRoot', r'C:\Windows')) / r'System32\WindowsPowerShell\v1.0\powershell.exe'


def version_of(executable):
    result = subprocess.run([str(executable), '--version'], capture_output=True, timeout=10)
    return result.stderr.split(b'\n', 1)[0].removeprefix(b'TidyVNC v')


def cmd_line(executable, arguments):
    # cmd.exe /s /c "..." keeps the inner quoting; none of the cases use & | < > ^ or %.
    inner = subprocess.list2cmdline([str(executable), *arguments])
    return f'cmd.exe /d /s /c "{inner}"'


def powershell_args(shell, executable, arguments):
    quoted = ' '.join("'" + a.replace("'", "''") + "'" for a in [str(executable), *arguments])
    return [str(shell), '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', f'& {quoted}; exit $LASTEXITCODE']


def idle_seconds():
    class LastInput(ctypes.Structure):
        _fields_ = [('size', ctypes.c_uint), ('time', ctypes.c_uint)]
    info = LastInput(ctypes.sizeof(LastInput), 0)
    if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
        return 0
    return ((ctypes.windll.kernel32.GetTickCount() - info.time) & 0xFFFFFFFF) / 1000


def close_gui(pid):
    """Asks a TidyVNC.exe to close its windows (the launcher's Ctrl+C route)."""
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.OpenEventW.restype = ctypes.c_void_p
    handle = kernel32.OpenEventW(0x0002, False, f'Local\\TidyVNC-close-{pid}')  # EVENT_MODIFY_STATE
    if handle:
        kernel32.SetEvent(ctypes.c_void_p(handle))
        kernel32.CloseHandle(ctypes.c_void_p(handle))


def run(command, env, cwd, folder, before):
    """Runs one case with its output in files, so a stray GUI holding the handles cannot block."""
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process = subprocess.Popen(command, env=env, cwd=cwd, stdout=out, stderr=err)
        try:
            code = process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            for pid in set(gui_processes(folder)) - before:
                close_gui(pid)
            process.wait(timeout=30)
            raise AssertionError(f'{command!r} started the GUI instead of ending in the terminal')
        out.seek(0); err.seek(0)
        return code, out.read(), err.read()


def gui_processes(folder):
    script = (f"Get-CimInstance Win32_Process -Filter \"Name='TidyVNC.exe'\" | "
              f"Where-Object {{ $_.ExecutablePath -like '{folder}\\*' }} | ForEach-Object {{ $_.ProcessId }}")
    output = subprocess.run([str(WINDOWS_POWERSHELL), '-NoProfile', '-Command', script], capture_output=True, text=True).stdout
    return [int(p) for p in output.split()]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('viewer', type=Path, help='vncviewer.exe of a publish')
    args = parser.parse_args()
    if os.environ.get('TIDYVNC_UI_TESTS') != '1':
        parser.exit(2, 'A failing case would open a window; set TIDYVNC_UI_TESTS=1 to run this.\n')
    if idle_seconds() < 60:
        parser.exit(2, f'The desktop is in use (idle {idle_seconds():.0f} s); not risking a window on it.\n')
    executable = args.viewer.resolve()
    version = version_of(executable)
    assert version, 'no version from --version'
    shells = [('direct', None), ('cmd', 'cmd')]
    shells += [('powershell', WINDOWS_POWERSHELL)] if WINDOWS_POWERSHELL.exists() else []
    shells += [('pwsh', PWSH)] if PWSH.exists() else []
    before = set(gui_processes(executable.parent))
    with tempfile.TemporaryDirectory(prefix='tidyvnc-terminal-') as temporary:
        root = Path(temporary)
        state = root / 'state'
        env = {k: v for k, v in os.environ.items() if not k.upper().startswith(('VNC_', 'TIDYVNC_'))}
        env.update(TIDYVNC_STATE_ROOT=str(state), VNC_USERNAME='private-fixture', VNC_PASSWORD='private-env-' * 500,
                   VNC_VIA_CMD='private-shell-$(New-Item should-not-exist)')
        sentinel = root / 'untouched'
        sentinel.write_bytes(b'fixture input remains unchanged')
        cases = [
            (['--help'], 1, b'Usage:', True),
            (['-AlertOnFatalError=off', '--help'], 1, b'Usage:', True),
            (['-AlertOnFatalError=private', '-AlertOnFatalError=off'], 1, b'invalid value', False),
            (['-AlertOnFatalError=off'], 1, b'launch credential exceeds', False),
            (['-AlertOnFatalError=on'], 1, b'launch credential exceeds', False),
            (['--version'], 0, b'TidyVNC v' + version, False),
            (['-Shared=on', '--version'], 0, b'TidyVNC v' + version, False),
            (['-Shared=private-value', '--help'], 1, b'invalid value', False),
            (['--unknown=private-value'], 1, b'unrecognized', False),
            (['-passwd=C:\\private-fixture-path', '--help'], 1, b'Usage:', True),
            (['C:\\private-fixture-path', '--version'], 0, b'TidyVNC v' + version, False),
            (['--version', '--unknown'], 0, b'TidyVNC v' + version, False),
            (['-SecurityTypes=VncAuth', '127.0.0.1::5900'], 1, b'launch credential exceeds', False),
            (['-listen'], 1, b'launch credential exceeds', False),
            (['-listen', '65536'], 1, b'listen port must', False),
            (['-listen', '5500private-value'], 1, b'listen port must', False),
            (['-listen', '.\\private-file'], 1, b'launch credential exceeds', False),
            (['-listen', '-UseIPv4=off', '-UseIPv6=off'], 1, b'cannot be applied', False),
            (['-via=private invalid'], 1, b'cannot be applied', False),
            (['-via=private-gateway'], 1, b'VNC_VIA_CMD shell customizations are not supported', False),
            (['-via=private-gateway', '-listen', '.\\private-file'], 1, b'cannot be combined with listening', False),
            (['-via=private-gateway', '-via='], 1, b'launch credential exceeds', False),
            (['-Log=private-writer:private-target:2147483648', '-Log=*::0', '--help'], 1, b'invalid value', False),
            (['-Log=private-writer:private-target:-2147483649', '--version'], 1, b'invalid value', False),
            (['-Log=*:stderr:+30tail', '--version'], 0, b'TidyVNC v' + version, False),
            (['-Log=private:stderr:30', '-Log=*::0', '--help'], 1, b'cannot be applied', False),
            (['-Log=*:file:30', '--help'], 1, b'Usage:', True),
            (['-Log=*:syslog:30', '--help'], 1, b'native adapter', False),
            (['-Log=*::0', '--help'], 1, b'Usage:', True),
            (['-geometry=bad', '-geometry=800x600', 'C:\\private-fixture-path'], 1, b'cannot be applied', False),
            (['-geometry=2147483648x1'], 1, b'cannot be applied', False),
            (['-Maximize=private-value', '--help'], 1, b'invalid value', False),
            (['-geometry=800x600', '-Maximize', '--version'], 0, b'TidyVNC v' + version, False),
            (['private-host::0'], 1, b'address is invalid', False),
        ]
        runs = 0
        for index, (arguments, code, expected, help_output) in enumerate(cases, 1):
            outputs = {}
            for name, shell in shells:
                if name == 'direct':
                    command = [str(executable), *arguments]
                elif name == 'cmd':
                    command = cmd_line(executable, arguments)
                else:
                    command = powershell_args(shell, executable, arguments)
                returncode, stdout, stderr = run(command, env, root, executable.parent, before)
                result = subprocess.CompletedProcess(command, returncode, stdout, stderr)
                runs += 1
                where = f'case {index} ({name})'
                assert result.returncode == code, f'{where}: exit {result.returncode}, wanted {code}: {result.stderr[:300]!r}'
                assert expected in result.stderr and not result.stdout, f'{where}: wrong output {result.stderr[:300]!r} / {result.stdout[:200]!r}'
                assert (b'Usage:' in result.stderr) == help_output, f'{where}: wrong terminal routing'
                assert b'private-' not in result.stderr, f'{where}: reflected input'
                outputs[name] = result.stderr
                if help_output:
                    for line in (b'MaxCutText <value> [default: 262144]\n', b'PointerEventInterval <value> [default: 17]\n',
                                 b'  geometry <value>\n', b'  Log <value> [default: *:stderr:30]\n', b'  via <value>\n',
                                 b'Supported %USERPROFILE%\\.ssh\\config settings are captured before connecting; '
                                 b'commands, proxy hops and VNC_VIA_CMD are unsupported.',
                                 b'File: %TMP%\\vncviewer.log (else %TEMP% or %USERPROFILE%), created on first output '
                                 b'with one .bak; failures use stderr.'):
                        assert line in result.stderr, f'{where}: help lacks {line!r}'
                    for name_ in (b'UseIPv4', b'UseIPv6', b'Maximize', b'listen', b'AlertOnFatalError'):
                        assert b'  ' + name_ + b' [on|off]' in result.stderr, f'{where}: help lacks {name_!r}'
            first = next(iter(outputs.values()))
            for name, value in outputs.items():
                assert value == first, f'case {index}: {name} output differs from direct'
        assert sorted(path.name for path in root.iterdir()) == ['untouched'], f'terminal path created state: {sorted(p.name for p in root.iterdir())}'
        assert sentinel.read_bytes() == b'fixture input remains unchanged', 'terminal path changed input'
    started = set(gui_processes(executable.parent)) - before
    assert not started, f'a terminal case started TidyVNC.exe: {sorted(started)}'
    print(f'PASS {len(cases)} help/version/error cases, {runs} runs through {", ".join(n for n, _ in shells)}; '
          'no state, files or GUI process created')


if __name__ == '__main__':
    main()
