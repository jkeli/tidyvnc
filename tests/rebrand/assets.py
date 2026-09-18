#!/usr/bin/env python3
"""Validate checked-in icon containers and their alpha/density representations."""
import pathlib, struct
from PIL import Image
root = pathlib.Path(__file__).resolve().parents[2]
icons = root/'media/icons'
for size in [16,20,22,24,32,40,48,64,96,128,256,512,1024]:
    image = Image.open(icons/f'tidyvnc_{size}.png').convert('RGBA')
    assert image.size == (size,size)
    assert image.getextrema()[3] == (0,255), (size, 'alpha')
    assert image.getpixel((0,0))[3] == 0
ico = Image.open(icons/'tidyvnc.ico')
assert {(s,s) for s in [16,20,24,32,40,48,64,96,128,256]} == ico.ico.sizes()
for size in ico.ico.sizes():
    assert ico.ico.getimage(size).convert('RGBA').tobytes() == Image.open(icons/f'tidyvnc_{size[0]}.png').convert('RGBA').tobytes(), size
raw = (icons/'tidyvnc.icns').read_bytes()
assert raw[:4] == b'icns' and struct.unpack('>I', raw[4:8])[0] == len(raw)
entries = set(); pos = 8
while pos < len(raw):
    tag, length = struct.unpack('>4sI', raw[pos:pos+8])
    assert length >= 8 and pos+length <= len(raw)
    entries.add(tag); pos += length
assert {b'ic07',b'ic08',b'ic09',b'ic10',b'ic11',b'ic12',b'ic13',b'ic14'} <= entries, entries
assert entries & {b'ic04',b'icp4',b'is32'}, entries
assert entries & {b'ic05',b'icp5',b'il32'}, entries
for name in ['connected','connecte','icon_dis','winvnc']:
    resource = Image.open(root/f'win/winvnc/{name}.ico')
    assert resource.ico.sizes() == ico.ico.sizes(), name
assert Image.open(root/'win/winvnc/winvnc.bmp').size == (48,48)
print('PNG alpha/sizes, exact ICO pixels, all 10 ICNS density slots and Windows representations passed')
