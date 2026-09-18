#!/usr/bin/env python3
"""Inspect a staged macOS app without launching or touching real preferences."""
import argparse, gettext, pathlib, plistlib, shutil, struct, subprocess, tempfile
p=argparse.ArgumentParser();p.add_argument('app',type=pathlib.Path);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[2]
contents=a.app/'Contents'; info=plistlib.loads((contents/'Info.plist').read_bytes())
assert info['CFBundleName']==info['CFBundleDisplayName']=='TidyVNC'
assert info['CFBundleIdentifier']=='io.github.jkeli.tidyvnc'
assert info['CFBundleIconFile']=='tidyvnc.icns'
assert info['NSHighResolutionCapable'] is True
assert info['CFBundleExecutable']=='vncviewer'
assert 'local network' in info['NSLocalNetworkUsageDescription'].lower()
assert 'VNC servers' in info['NSLocalNetworkUsageDescription']
subprocess.run(['codesign','--verify','--strict',str(a.app)],check=True)
signature=subprocess.run(['codesign','-dvv',str(a.app)],check=True,capture_output=True,text=True).stderr
assert 'Identifier=io.github.jkeli.tidyvnc' in signature
assert 'Info.plist=not bound' not in signature
assert 'Sealed Resources=none' not in signature
for field in ['CFBundleGetInfoString','NSHumanReadableCopyright']:
    assert 'Copyright (C) 1999-2026 TigerVNC team and many others (see README.rst)' in info[field]
assert info['CFBundleDocumentTypes'][0]['CFBundleTypeExtensions']==['tidyvnc']
build=a.app.parent
def code_contents(path):
    # Bundle signing changes the signature blob and may align __LINKEDIT to a
    # different VM page size. Compare all other unsigned bytes per architecture,
    # including code, data, UUID and load commands. Never alter the real binaries.
    arches=subprocess.check_output(['lipo','-archs',str(path)],text=True).split()
    result={}
    with tempfile.TemporaryDirectory(prefix='tidyvnc-code-check-') as tmp:
        for arch in arches:
            copy=pathlib.Path(tmp)/arch
            if len(arches)>1:
                subprocess.run(['lipo',str(path),'-thin',arch,'-output',str(copy)],check=True)
            else:
                shutil.copy2(path,copy)
            subprocess.run(['codesign','--remove-signature',str(copy)],check=True)
            data=bytearray(copy.read_bytes())
            assert data[:4]==b'\xcf\xfa\xed\xfe', 'Expected 64-bit Mach-O'
            count=struct.unpack_from('<I',data,16)[0]
            offset=32
            for _ in range(count):
                command,size=struct.unpack_from('<II',data,offset)
                assert size>=8 and offset+size<=len(data)
                if command==0x19 and data[offset+8:offset+24].rstrip(b'\0')==b'__LINKEDIT':
                    data[offset+32:offset+40]=b'\0'*8
                offset+=size
            result[arch]=bytes(data)
    return result
assert code_contents(contents/'MacOS/vncviewer')==code_contents(build/'vncviewer/vncviewer')
assert (contents/'Resources/tidyvnc.icns').read_bytes()==(root/'media/icons/tidyvnc.icns').read_bytes()
langs=(root/'po/LINGUAS').read_text().split()
for lang in langs:
    mo=contents/f'Resources/locale/{lang}/LC_MESSAGES/tidyvnc.mo'
    assert mo.read_bytes()==(build/f'po/{lang}.mo').read_bytes(),lang
    catalog=gettext.GNUTranslations(mo.open('rb'))
    for key,value in catalog._catalog.items():
        if isinstance(key,str) and 'TidyVNC' in key and 'TigerVNC' not in key:
            assert 'tigervnc' not in value.lower(),(lang,key,value)
    assert not (mo.parent/'tigervnc.mo').exists()
print(f'App identity/signature, local-network usage, copyright, file type, code/icon equality and {len(langs)} packaged catalogs passed')
