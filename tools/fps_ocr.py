#!/usr/bin/env python3
"""Read the 2-digit FPS readout (overlay font, 5x5 glyphs, line-doubled) from 640x480 misterclaw captures.

Usage: fps_ocr.py <png>...   (prints one value per file; None = no readable digits)
Added 2026-10-12 for the triple-buffer FPS measurements (docs/TRACKB_DESIGN.md)."""
import sys, glob, collections
from PIL import Image
G = {0:"01100_10110_10010_11010_01100",1:"01000_11000_01000_01000_11100",2:"01100_10010_00100_01000_11110",
     3:"11100_00010_01100_00010_11100",4:"10010_10010_11110_00010_00010",5:"11110_10000_11100_00010_11100",
     6:"01100_10000_11100_10010_01100",7:"11110_00010_00100_01000_01000",8:"01100_10010_01100_10010_01100",
     9:"01100_10010_01110_00010_01100"}
T = {d:[[c=='1' for c in r] for r in s.split('_')] for d,s in G.items()}
def white(px): return px[0]>200 and px[1]>200 and px[2]>200
def read(path):
    im = Image.open(path).convert('RGB'); W,H = im.size
    best=None
    # glyphs expected near (7,5),(12,5); scan a small neighbourhood for robustness
    # glyphs are 5 px wide and line-doubled (10 px tall) at ~(8,10) and (13,10)
    for oy in range(8,13):
        for ox in range(6,11):
            score=0; digs=[]
            for k in range(2):
                x0=ox+5*k; bm=[[white(im.getpixel((x0+c,oy+2*r))) for c in range(5)] for r in range(5)]
                # glyph occupies 4 cols (col 4 is spacing) -> compare cols 0..4 anyway
                m=max(T, key=lambda d: sum(bm[r][c]==T[d][r][c] for r in range(5) for c in range(5)))
                s=sum(bm[r][c]==T[m][r][c] for r in range(5) for c in range(5))
                score+=s; digs.append(m)
            if best is None or score>best[0]: best=(score,digs,(ox,oy))
    score,digs,_=best
    return (digs[0]*10+digs[1]) if score>=46 else None
if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(p, read(p))
