#!/usr/bin/env python3
"""Exercise aliases without requiring platform dependencies or a compiler."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as tmp:
    script = pathlib.Path(tmp) / 'options.cmake'
    script.write_text(f'include("{root}/cmake/BrandingOptions.cmake")\nif(NOT TIDYVNC_FLTK_SHARED STREQUAL EXPECTED)\nmessage(FATAL_ERROR "Wrong value")\nendif()\n')
    cases = [([], 'OFF', True), (['-DTIDYVNC_FLTK_SHARED=ON'], 'ON', True),
             (['-DTIGERVNC_FLTK_SHARED=ON'], 'ON', True),
             (['-DTIGERVNC_FLTK_SHARED=OFF'], 'OFF', True),
             (['-DTIGERVNC_FLTK_SHARED=ON','-DTIDYVNC_FLTK_SHARED=ON'], 'ON', True),
             (['-DTIGERVNC_FLTK_SHARED=ON','-DTIDYVNC_FLTK_SHARED=OFF'], 'OFF', False),
             (['-DTIGERVNC_FLTK_SHARED=OFF','-DTIDYVNC_FLTK_SHARED=ON'], 'ON', False)]
    for args, expected, success in cases:
        p = subprocess.run(['cmake', *args, f'-DEXPECTED={expected}', '-P', str(script)], capture_output=True, text=True)
        assert (p.returncode == 0) == success, p.stdout + p.stderr
        if any('TIGERVNC_' in a for a in args): assert 'deprecated' in p.stderr
        if not success: assert 'Conflicting' in p.stderr
print('7 build-option compatibility cases passed')
