#!/usr/bin/env python3
"""Inspect a staged macOS app without launching or touching real preferences."""
import argparse, gettext, hashlib, pathlib, plistlib
p=argparse.ArgumentParser();p.add_argument('app',type=pathlib.Path);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[2]
contents=a.app/'Contents'; info=plistlib.loads((contents/'Info.plist').read_bytes())
assert info['CFBundleName']==info['CFBundleDisplayName']=='TidyVNC'
assert info['CFBundleIdentifier']=='io.github.jkeli.tidyvnc'
assert info['CFBundleIconFile']=='tidyvnc.icns'
assert info['NSHighResolutionCapable'] is True
assert info['CFBundleExecutable']=='vncviewer'
for field in ['CFBundleGetInfoString','NSHumanReadableCopyright']:
    assert 'Copyright (C) 1999-2026 TigerVNC team and many others (see README.rst)' in info[field]
assert info['CFBundleDocumentTypes'][0]['CFBundleTypeExtensions']==['tidyvnc']
build=a.app.parent
for staged,built in [(contents/'MacOS/vncviewer',build/'vncviewer/vncviewer'),
                     (contents/'Resources/tidyvnc.icns',root/'media/icons/tidyvnc.icns')]:
    assert hashlib.sha256(staged.read_bytes()).digest()==hashlib.sha256(built.read_bytes()).digest(),staged
langs=(root/'po/LINGUAS').read_text().split()
for lang in langs:
    mo=contents/f'Resources/locale/{lang}/LC_MESSAGES/tidyvnc.mo'
    assert mo.read_bytes()==(build/f'po/{lang}.mo').read_bytes(),lang
    catalog=gettext.GNUTranslations(mo.open('rb'))
    for key,value in catalog._catalog.items():
        if isinstance(key,str) and 'TidyVNC' in key and 'TigerVNC' not in key:
            assert 'tigervnc' not in value.lower(),(lang,key,value)
    assert not (mo.parent/'tigervnc.mo').exists()
print(f'App identity, copyright, file type, binary/icon equality and {len(langs)} packaged catalogs passed')
