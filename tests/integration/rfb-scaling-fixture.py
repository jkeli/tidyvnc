#!/usr/bin/env python3
# Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later.
"""Local-only RFB 3.8 pixel-grid fixture. No authentication or remote control.

Run with Python 3, then connect a viewer to 127.0.0.1:5909 with clipboard and
RemoteResize disabled. The framebuffer is 320x240; an 8-pixel white border,
three primary-color bands and a one-pixel checkerboard reveal geometry and
sampling problems. Pointer messages print (button mask, remote x, remote y).
This is a manual fixture, not a complete RFB server or an automated assertion.
"""
import socket,struct,threading

def run(c):
 def read(n):
  out=b''
  while len(out)<n:
   chunk=c.recv(n-len(out))
   if not chunk: raise EOFError()
   out+=chunk
  return out
 try:
  c.sendall(b'RFB 003.008\n');read(12);c.sendall(b'\1\1');read(1);c.sendall(b'\0'*4);read(1)
  pf=struct.pack('>BBBBHHHBBBxxx',32,24,0,1,255,255,255,16,8,0)
  name=b'HiDPI test grid 320x240'
  c.sendall(struct.pack('>HH',320,240)+pf+struct.pack('>I',len(name))+name)
  while True:
   msg=read(1)[0]
   if msg==0: read(3);pf=read(16)
   elif msg==2: read(1);n=struct.unpack('>H',read(2))[0];read(n*4)
   elif msg==3:
    req=read(9)
    if req[0]: continue
    bits,depth,big,true,rmax,gmax,bmax,rs,gs,bs=struct.unpack('>BBBBHHHBBBxxx',pf)
    payload=bytearray()
    for y in range(240):
     for x in range(320):
      if x<80:r,g,b=255,0,0
      elif x<160:r,g,b=0,255,0
      elif x<240:r,g,b=0,0,255
      else:r=g=b=255*((x+y)%2)
      if y<8 or y>=232 or x<8 or x>=312:r=g=b=255
      if y in (79,159):r=g=b=0
      pixel=((r*rmax//255)<<rs)|((g*gmax//255)<<gs)|((b*bmax//255)<<bs)
      payload+=pixel.to_bytes(bits//8,'big' if big else 'little')
    c.sendall(b'\0\0\0\1'+struct.pack('>HHHHi',0,0,320,240,0)+payload)
   elif msg==4:read(7)
   elif msg==5:print('pointer',struct.unpack('>BHH',read(5)),flush=True)
   elif msg==6:
    read(3);n=struct.unpack('>I',read(4))[0]
    if n>1024*1024: raise ValueError('Clipboard message exceeds fixture limit')
    read(n)
   elif msg==150:read(9)
   else:print('unsupported',msg,flush=True);break
 except (EOFError,ConnectionError,ValueError):pass
 finally:c.close()
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',5909));s.listen();print('ready',flush=True)
while True:
 c,a=s.accept();threading.Thread(target=run,args=(c,),daemon=True).start()
