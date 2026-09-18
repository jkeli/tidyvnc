#!/usr/bin/env python3
"""Export reviewed SVG into a build directory. Requires Qt renderer, Pillow, iconutil."""
import argparse, pathlib, shutil, subprocess
from PIL import Image
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--renderer', required=True, type=pathlib.Path)
p.add_argument('--output', required=True, type=pathlib.Path)
p.add_argument('--verify', action='store_true', help='compare exported pixels/containers with checked-in resources')
a = p.parse_args()
media = pathlib.Path(__file__).resolve().parents[1]
a.output.mkdir(parents=True, exist_ok=True)
sizes = [16,20,22,24,32,40,48,64,96,128,256,512,1024]
for size in sizes:
    subprocess.run([str(a.renderer.resolve()), str(media/('tidyvnc-small.svg' if size <= 24 else 'tidyvnc.svg')), str(size), str(a.output/f'tidyvnc_{size}.png')], check=True)
shutil.copyfile(media/'tidyvnc.svg', a.output/'tidyvnc.svg')
ico_sizes = [(s,s) for s in sizes if s <= 256 and s != 22]
im = Image.open(a.output/'tidyvnc_256.png')
im.save(a.output/'tidyvnc.ico', sizes=ico_sizes, append_images=[Image.open(a.output/f'tidyvnc_{s}.png') for s,_ in ico_sizes if s != 256])
iconset = a.output/'tidyvnc.iconset'
iconset.mkdir(exist_ok=True)
for logical in [16,32,128,256,512]:
    for scale in [1,2]:
        suffix = '@2x' if scale == 2 else ''
        shutil.copyfile(a.output/f'tidyvnc_{logical*scale}.png', iconset/f'icon_{logical}x{logical}{suffix}.png')
if shutil.which('iconutil'):
    subprocess.run(['iconutil','-c','icns','-o',str(a.output/'tidyvnc.icns'),str(iconset)], check=True)
else:
    raise SystemExit('macOS iconutil is required for the complete ICNS export')
# Export Windows resources from the same reviewed sources.
windows = a.output/'windows'
windows.mkdir(exist_ok=True)
for name in ['winvnc.ico', 'vncconfig.ico']:
    shutil.copyfile(a.output/'tidyvnc.ico', windows/name)
# State is communicated by shape as well as color; every size is vector rendered.
for state, color, mark in [('connected', '#4ae3a0', 'M712 790l48 48 88-96'),
                           ('disconnected', '#ff747c', 'M732 748l96 96')]:
    badge = f'<circle cx="790" cy="790" r="138" fill="{color}" stroke="#f4fafb" stroke-width="28"/><path d="{mark}" stroke="#142f43" stroke-width="32" fill="none" stroke-linecap="round" stroke-linejoin="round"/>'
    master = (media/'tidyvnc.svg').read_text().replace('</svg>', badge+'</svg>')
    source = windows/f'{state}.svg'
    source.write_text(master)
    images = []
    for size, _ in ico_sizes:
        png = windows/f'{state}_{size}.png'
        subprocess.run([str(a.renderer.resolve()), str(source), str(size), str(png)], check=True)
        images.append(Image.open(png))
    images[-1].save(windows/f'{state}.ico', sizes=ico_sizes, append_images=images[:-1])
shutil.copyfile(windows/'disconnected.ico', windows/'icon_dis.ico')
shutil.copyfile(windows/'connected.ico', windows/'connecte.ico')
bitmap = Image.new('RGB', (48,48), '#ffffff')
foreground = Image.open(a.output/'tidyvnc_48.png').convert('RGBA')
bitmap.paste(foreground, (0,0), foreground)
bitmap.save(windows/'winvnc.bmp')
if a.verify:
    for generated in a.output.glob('tidyvnc*'):
        if generated.is_file():
            source = media/'icons'/generated.name
            if generated.suffix == '.png':
                assert Image.open(source).tobytes() == Image.open(generated).tobytes(), source
            else:
                assert source.read_bytes() == generated.read_bytes(), source
    print('Exports match checked-in assets')

    for name in ['winvnc.ico','connecte.ico','connected.ico','icon_dis.ico','winvnc.bmp']:
        assert (windows/name).read_bytes() == (media.parent/'win/winvnc'/name).read_bytes(), name
    assert (windows/'vncconfig.ico').read_bytes() == (media.parent/'win/vncconfig/vncconfig.ico').read_bytes()
