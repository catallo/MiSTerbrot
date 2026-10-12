#!/usr/bin/env python3
"""Deterministic per-POI FPS measurement on hardware.

Loads <rbf> in 640x480p with "Always Show FPS", presses N (skip) through the attract
playlist until the overlay shows the target POI name (OCR), then samples
(elapsed, zoom, fps) from the overlay while it zooms in, until the dwell.  The zoom
pacing is per vblank, so samples of two builds compare at equal zoom readouts.

Usage:  tools/mister-lock python3 tools/fps_poi_measure.py <rbf-on-device> <tag> "POI NAME" [...]
Output: screenshots + results.json under $MISTERBROT_OUT (default /tmp/fps_poi_<tag>).
The saved MiSTerbrot.cfg is backed up and restored.  Added 2026-10-12."""
import sys, time, re, json, subprocess, os
from pathlib import Path
ROOT = str(Path(__file__).resolve().parent.parent); H = os.environ.get("MISTER_HOST", "100.101.202.25")
sys.path.insert(0, ROOT + "/tools")
import fps_ocr, poi_ocr
MC = [ROOT + "/tools/misterclaw-send", "--host", H]
CFG = "/media/fat/config/MiSTerbrot.cfg"
def rsh(cmd): subprocess.run(["sshpass", "-p", "1", "ssh", "-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR", f"root@{H}", cmd], check=True, capture_output=True)
def key(c): subprocess.run(MC + ["input", "type", c], capture_output=True); time.sleep(0.35)
def shot(path): subprocess.run(MC + ["screenshot", "--output", path], capture_output=True); return path
def zoom_of(path):
    try: line = poi_ocr.read_target_line(path, line_idx=1)
    except Exception: return None
    m = re.search(r"ZOOM: X2\^(\d+\.\d)", line); return float(m.group(1)) if m else None
def name_of(path):
    try: return poi_ocr.read_poi_name(path)
    except Exception: return ""
rbf, tag, targets = sys.argv[1], sys.argv[2], sys.argv[3:]
out = os.environ.get("MISTERBROT_OUT", f"/tmp/fps_poi_{tag}"); os.makedirs(out, exist_ok=True)
rsh(f"cp {CFG} {CFG}.poi_bak; printf '\\x50' | dd of={CFG} bs=1 seek=2 conv=notrunc 2>/dev/null; printf '\\x01' | dd of={CFG} bs=1 seek=7 conv=notrunc 2>/dev/null; echo load_core /media/fat/_Other/{rbf} > /dev/MiSTer_cmd")
time.sleep(22); key("l"); key("l"); key("g")
results = {}
for target in targets:
    found = None
    for i in range(150):
        p = shot(f"{out}/scan.png"); n = name_of(p)
        if n == target: found = time.time(); break
        key("n"); time.sleep(1.0)
    if not found: print(f"{tag}: {target} not found after 150 skips"); results[target] = None; continue
    samples = []; same = 0; last = None
    while time.time() - found < 45:
        p = shot(f"{out}/{target.replace(' ','_')}_{len(samples):02d}.png")
        z, f = zoom_of(p), fps_ocr.read(p); samples.append((round(time.time() - found, 1), z, f))
        if z == last: same += 1
        else: same = 0
        last = z
        if same >= 3: break
        time.sleep(1.0)
    results[target] = samples
    print(f"{tag}: {target}: " + " ".join(f"({t}s z{z} fps{f})" for t, z, f in samples), flush=True)
rsh(f"cp {CFG}.poi_bak {CFG}")
json.dump(results, open(f"{out}/results.json", "w"))
