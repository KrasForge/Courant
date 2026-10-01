#!/usr/bin/env python3
"""Trim transparent margins from the 3D renders (keeps a small border)."""
import os
import sys

from PIL import Image

IMG = os.path.join(os.path.dirname(__file__), '..', 'images')
for name in sys.argv[1:]:
    path = os.path.join(IMG, name)
    im = Image.open(path)
    x0, y0, x1, y1 = im.getchannel('A').point(lambda a: 255 if a > 8 else 0).getbbox()
    pad = 24
    im.crop((max(x0 - pad, 0), max(y0 - pad, 0), min(x1 + pad, im.width), min(y1 + pad, im.height))).save(path, optimize=True)
    print('cropped', name)
