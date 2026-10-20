#!/usr/bin/env python3
"""Per-POI frame-time sweep on the Verilator pixel-pipeline bench.

For every POI in tools/poi_master.json this renders, in simulation, each
integer zoom level of the auto-zoom path (z = 1 .. zoom_int, the same
rounding tools/poi_encode.py uses for the snap depth) exactly as auto-zoom
renders it on the device: 640x240 grid (640-mode halves the horizontal
step, rows are shifted by half a pitch), the POI's own max_iter for the
whole path (fractal_top: auto_iter_choice = az_max_iter), period-3
precheck off (osd_p3_mode Auto outside benchmark mode).  cy=0 views are
halved for the real-axis mirror.  The bench counts clk_sys (50 MHz)
cycles to frame_done; sim/pixel_pipeline/tb_pp.sv has matched the device
bench on every comparable scene (90/90 on 2026-10-18).

Outputs tools/poi_frametimes.json: per POI the ms per zoom level, the
target-view and worst-on-path frame times and the minimum vsync-locked
frame rate in 640x480p (every frame is twice the 240-row work there).

    python3 tools/poi_frametime.py                 # local, all cores
    python3 tools/poi_frametime.py --host scm      # rsync + run on scm
    python3 tools/poi_frametime.py --classify-fps 6 --write
        # set/clear "gallery_only" in poi_master.json: a POI whose slowest
        # zoom-in frame drops below 6 fps in 480p is gallery-only
        # (auto_zoom.v skips it when the OSD "Auto-Zoom POIs" row is Fast only)

The iterator count defaults to N_ITERATORS in rtl/fractal_top.v; clk_iter is
read from the PLL (rtl/pll/pll_0002.v) and passed to the bench.  The result
records both plus every POI's inputs and the fps floor, and
tools/poi_encode.py refuses to bake the flags when they no longer match.
"""

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MASTER_JSON = ROOT / "tools" / "poi_master.json"
OUT_JSON = ROOT / "tools" / "poi_frametimes.json"
SIM_DIR = ROOT / "sim" / "pixel_pipeline"
DEFAULT_STEP = 0x0003333333333333
CLK_SYS_HZ = 50e6
VBLANK_MS = 1000.0 / 60.0


def fx(v: float) -> int:
    return int(round(v * (1 << 56))) & 0xFFFFFFFFFFFFFFFF


def tier(z: float) -> int:
    if z < 6:   return 512
    if z < 12:  return 1024
    if z < 18:  return 2048
    return 4095


def zoom_int(z: float) -> int:
    # poi_encode.py: zint = round(zoom_x10 / 10) — snap depth and auto-zoom end
    return max(0, min(31, int(round(int(round(z * 10)) / 10.0))))


def default_ni() -> int:
    m = re.search(r"parameter N_ITERATORS\s*=\s*(\d+)", (ROOT / "rtl" / "fractal_top.v").read_text())
    return int(m.group(1)) if m else 64


def device_clk_iter_mhz() -> float:
    """clk_iter as the device PLL makes it (rtl/pll/pll_0002.v outclk_2)."""
    m = re.search(r'output_clock_frequency2\("([\d.]+) MHz"\)', (ROOT / "rtl" / "pll" / "pll_0002.v").read_text())
    if not m:
        sys.exit("cannot read clk_iter from rtl/pll/pll_0002.v")
    return float(m.group(1))


def fps_locked(ms_480p: float) -> float:
    return 60.0 / max(1, math.ceil(ms_480p / VBLANK_MS - 1e-9))


def build(ni: int, clk_mhz: float, jobs: int) -> Path:
    objdir = SIM_DIR / f"obj_dir_ft{ni}"
    half_ns = 500.0 / clk_mhz    # tb_pp.sv: always #(ITER_HALF_NS) clk_iter = ~clk_iter
    cmd = ["verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-WIDTH", "-I../../rtl",
           "--top", "tb_pp", f"-GNI={ni}", f"-GITER_HALF_NS={half_ns:.3f}", "tb_pp.sv", "../../rtl/pixel_pipeline.v",
           "../../rtl/iter_quad.v", "../../rtl/mul_trunc64.v", "-o", "tb_pp",
           "-Mdir", objdir.name, "-j", str(jobs)]
    env = dict(os.environ, LC_ALL="C.UTF-8")
    r = subprocess.run(cmd, cwd=SIM_DIR, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"verilator build failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    return objdir / "tb_pp"


def make_jobs(pois):
    jobs = []
    for i, p in enumerate(pois):
        zi = zoom_int(float(p["zoom_level"]))
        mi = int(p.get("max_iter", tier(float(p["zoom_level"]))))
        for z in range(1, max(zi, 1) + 1):
            jobs.append((i, z, [f"+cxraw={fx(float(p['cx'])):016x}", f"+cyraw={fx(float(p['cy'])):016x}",
                                f"+stepraw={DEFAULT_STEP >> z:016x}", f"+maxiter={mi}", "+p3=0"]))
    return jobs


def run_jobs(exe: Path, jobs, parallel: int):
    """Run the bench for every (idx, z, args) job, parallel processes."""
    import concurrent.futures as cf
    out = {}

    def one(job):
        i, z, args = job
        r = subprocess.run([str(exe)] + args, capture_output=True, text=True, timeout=3600)
        m = re.search(r"cycles=(\d+)", r.stdout)
        if not m:
            raise RuntimeError(f"POI {i} z{z}: no cycles in output\n{r.stdout[-500:]}")
        return i, z, int(m.group(1))

    done = 0
    with cf.ThreadPoolExecutor(max_workers=parallel) as ex:
        for i, z, cyc in ex.map(one, jobs):
            out[(i, z)] = cyc
            done += 1
            if done % 100 == 0:
                print(f"  {done}/{len(jobs)}", file=sys.stderr)
    return out


def summarize(pois, cycles, ni, clk_mhz):
    rows = []
    for i, p in enumerate(pois):
        zi = zoom_int(float(p["zoom_level"]))
        sym = float(p["cy"]) == 0.0
        per = {}
        for z in range(1, max(zi, 1) + 1):
            ms = cycles[(i, z)] / CLK_SYS_HZ * 1e3
            per[z] = round(ms / 2 if sym else ms, 2)
        worst_z = max(per, key=per.get)
        rows.append({
            "idx": i, "name": p["name"], "category": p.get("category"),
            "cx": float(p["cx"]), "cy": float(p["cy"]),
            "zoom_level": p["zoom_level"], "zoom_int": zi,
            "max_iter": int(p.get("max_iter", tier(float(p["zoom_level"])))),
            "ms_by_zoom": per,
            "target_ms": per[max(zi, 1)], "worst_ms": per[worst_z], "worst_z": worst_z,
            "fps480_min": fps_locked(2 * per[worst_z]),
            "fps480_target": fps_locked(2 * per[max(zi, 1)]),
        })
    return {"note": "sim/pixel_pipeline/tb_pp.sv frame times, ms per 640x240 frame (cy=0 halved); "
                    "auto-zoom path z1..zoom_int with the POI's max_iter, P3 precheck off. "
                    "640x480p frame = 2x; fps = 60/ceil(2*ms/16.67).",
            "iterators": ni, "clk_iter_mhz": clk_mhz, "pois": rows}


def classify(result, fps_thr: float, write: bool):
    pois = json.loads(MASTER_JSON.read_text())
    result["fps_floor"] = fps_thr
    changed = []
    for r in result["pois"]:
        p = pois[r["idx"]]
        slow = r["fps480_min"] < fps_thr
        was = bool(p.get("gallery_only", False))
        if slow != was:
            changed.append((r["idx"], p["name"], was, slow, r["worst_ms"], r["fps480_min"]))
        if slow:
            p["gallery_only"] = True
        else:
            p.pop("gallery_only", None)
    n_slow = sum(1 for p in pois if p.get("gallery_only"))
    print(f"\nthreshold {fps_thr} fps in 480p: {len(pois) - n_slow} auto-zoom POIs, {n_slow} gallery-only")
    for idx, name, was, now, ms, fps in changed:
        print(f"  {idx:3d} {name:<22} gallery_only {was} -> {now}   worst {ms:7.1f} ms = {fps:4.1f} fps")
    if write:
        MASTER_JSON.write_text(json.dumps(pois, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {MASTER_JSON} — now run tools/poi_encode.py")
    elif changed:
        print("(dry run — add --write to update poi_master.json)")


def run_remote(host: str, ni: int, jobs: int | None) -> dict:
    rdir = "projects/mb_frametime"
    files = ["tools/poi_frametime.py", "tools/poi_master.json", "sim/pixel_pipeline/tb_pp.sv",
             "rtl/fractal_top.v", "rtl/pixel_pipeline.v", "rtl/iter_quad.v", "rtl/mul_trunc64.v"]
    subprocess.run(["ssh", host, f"mkdir -p {rdir}/tools {rdir}/sim/pixel_pipeline {rdir}/rtl/pll"], check=True)
    subprocess.run(["rsync", "-a", str(ROOT / "rtl/pll/pll_0002.v"), f"{host}:{rdir}/rtl/pll/"], check=True)
    subprocess.run(["rsync", "-a"] + [str(ROOT / f) for f in files if f.startswith("tools/")]
                   + [f"{host}:{rdir}/tools/"], check=True)
    subprocess.run(["rsync", "-a"] + [str(ROOT / f) for f in files if f.startswith("rtl/")]
                   + [f"{host}:{rdir}/rtl/"], check=True)
    subprocess.run(["rsync", "-a", str(ROOT / "sim/pixel_pipeline/tb_pp.sv"),
                    f"{host}:{rdir}/sim/pixel_pipeline/"], check=True)
    jarg = f"--jobs {jobs}" if jobs else ""
    subprocess.run(["ssh", host, f"cd {rdir} && LC_ALL=C.UTF-8 python3 tools/poi_frametime.py "
                                 f"--ni {ni} {jarg} --out tools/poi_frametimes.json"], check=True)
    tmp = Path(tempfile.mkdtemp()) / "poi_frametimes.json"
    subprocess.run(["scp", "-q", f"{host}:{rdir}/tools/poi_frametimes.json", str(tmp)], check=True)
    return json.loads(tmp.read_text())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ni", type=int, default=None, help="iterators (default: N_ITERATORS in rtl/fractal_top.v)")
    ap.add_argument("--jobs", type=int, default=None, help="parallel bench processes (default: all cores)")
    ap.add_argument("--host", default=None, help="run the sweep on this ssh host (needs verilator, python3)")
    ap.add_argument("--out", default=str(OUT_JSON))
    ap.add_argument("--classify-fps", type=float, default=None,
                    help="flag POIs whose slowest zoom-in frame is below this 480p fps as gallery_only")
    ap.add_argument("--write", action="store_true", help="with --classify-fps: update poi_master.json")
    ap.add_argument("--from-json", default=None, help="skip the sweep, classify from an existing result file")
    a = ap.parse_args()

    ni = a.ni or default_ni()
    clk_mhz = device_clk_iter_mhz()
    if a.from_json:
        result = json.loads(Path(a.from_json).read_text())
    elif a.host:
        result = run_remote(a.host, ni, a.jobs)
    else:
        pois = json.loads(MASTER_JSON.read_text())
        jobs = make_jobs(pois)
        par = a.jobs or os.cpu_count() or 4
        print(f"{len(pois)} POIs, {len(jobs)} views, {ni} iterators @ {clk_mhz:g} MHz, {par} parallel", file=sys.stderr)
        exe = build(ni, clk_mhz, par)
        cycles = run_jobs(exe, jobs, par)
        result = summarize(pois, cycles, ni, clk_mhz)
    rows = result["pois"]
    for thr in (30, 20, 15, 10, 6):
        print(f">= {thr:2d} fps in 480p along the zoom-in: {sum(1 for r in rows if r['fps480_min'] >= thr):3d} POIs")
    if a.classify_fps is not None:
        classify(result, a.classify_fps, a.write)
    if not a.from_json or (a.classify_fps is not None and a.write):
        out = Path(a.from_json) if a.from_json else Path(a.out)
        out.write_text(json.dumps(result, indent=1) + "\n")
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
