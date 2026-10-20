#!/bin/bash
# Device checks for a MiSTerbrot build (run under tools/mister-lock).  Outputs under
# $MISTERBROT_CAPTURES/devcheck/<tag> (default <repo>/captures, gitignored, persistent —
# /tmp got wiped on 2026-10-15 and took every reference capture with it).
#   tools/devcheck.sh deploy <local.rbf> <name-on-device.rbf>        copy + load + overlay OCR boot check
#   tools/devcheck.sh pal    <name-on-device.rbf> <tag> <osd-values>   home view, cycling off, screenshot per palette
#   tools/devcheck.sh bound  <name-on-device.rbf> <tag>                zoom-out x30 / pan-left x40 / pan-up x40 readouts
#   tools/devcheck.sh cmp    <tagA> <tagB>                             pixel-exact diff of matching captures
# The MiSTerbrot.cfg is restored from a single .orig copy around palette patches (survives a killed run).  Keys sent right after a load are
# often dropped, so the home view is verified by OCR (ZOOM: X2^00.0) and retried; C (cycling toggle)
# is only pressed on the first try.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); H=${MISTER_HOST:-100.101.202.25}
MC="$ROOT/tools/misterclaw-send --host $H"; CFG=/media/fat/config/MiSTerbrot.cfg
CAP=${MISTERBROT_CAPTURES:-$ROOT/captures}; DC=$CAP/devcheck; mkdir -p $DC
rsh() { sshpass -p 1 ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@$H "$@"; }
ocr() { (cd $ROOT && python3 -c "import sys; sys.path.insert(0,'tools'); import poi_ocr; print(poi_ocr.read_target_line('$1', line_idx=1)[:44])" 2>/dev/null); }
home() { # $1 = out png ; reach the home view with verification
  for try in 1 2 3 4; do
    if [ $try = 1 ]; then ks="r r c g l"; else ks="r r g l"; fi
    for k in $ks; do $MC input type $k >/dev/null; sleep 0.5; done; sleep 2
    $MC screenshot --output "$1" >/dev/null
    case "$(ocr "$1")" in *X2^00.0*) return 0;; esac
    sleep 3
  done; echo "  WARN: home view not reached"; return 1
}
cmd=$1; shift
case $cmd in
  deploy)
    case "$2" in *.rbf) ;; *) echo "deploy: device name must end in .rbf (got '$2') — main only loads what the later load_core names"; exit 1;; esac
    # 2026-10-17: an interrupted scp from the build host left a 0-byte RBF, the
    # chain loaded it, the FPGA ended up uninitialized and the MiSTer main
    # process quit (recovery needed a reboot).  Refuse anything that is not a
    # plausible bitstream, and only load what the device verifiably received.
    sz=$(stat -c %s "$1" 2>/dev/null || echo 0)
    [ "$sz" -gt 3000000 ] || { echo "deploy: $1 is $sz bytes — not an RBF, refusing"; exit 1; }
    lsum=$(sha256sum "$1" | cut -c1-16)
    sshpass -p 1 scp -o StrictHostKeyChecking=no -o LogLevel=ERROR "$1" root@$H:/media/fat/_Other/$2 || { echo "deploy: scp failed"; exit 1; }
    rsum=$(rsh "sha256sum /media/fat/_Other/$2 | cut -c1-16")
    [ "$lsum" = "$rsum" ] || { echo "deploy: checksum mismatch local $lsum device $rsum — not loading"; rsh "rm -f /media/fat/_Other/$2"; exit 1; }
    echo "$rsum"
    rsh "timeout 10 sh -c 'echo load_core /media/fat/_Other/$2 > /dev/MiSTer_cmd'" || { echo "deploy: MiSTer command pipe has no reader (main process down?)"; exit 1; }; sleep 22
    $MC screenshot --output $DC/deploy.png >/dev/null
    (cd $ROOT && python3 -c "import sys; sys.path.insert(0,'tools'); import poi_ocr; print('overlay:', poi_ocr.read_poi_name('$DC/deploy.png'))");;
  pal)
    RBF=$1; TAG=$2; shift 2; OUT=$DC/$TAG; mkdir -p $OUT
    # One pristine copy per device: if a previous run died mid-way, .orig still exists and is
    # restored FIRST, so a pinned palette can never become the "original" of the next run.
    rsh "[ -f $CFG.orig ] && cp $CFG.orig $CFG || cp $CFG $CFG.orig"; b1orig=$(rsh "xxd -p -s1 -l1 $CFG")
    for v in "$@"; do
      b0=$(printf '%02x' $(( (v & 15) << 4 ))); b1=$(printf '%02x' $(( (0x$b1orig & ~7) | (v >> 4) )))
      rsh "printf '\\x$b0\\x$b1' | dd of=$CFG bs=1 seek=0 conv=notrunc 2>/dev/null; echo load_core /media/fat/_Other/$RBF > /dev/MiSTer_cmd"; sleep 22
      home $OUT/pal_$v.png && echo "  $TAG palette $v captured"
    done
    rsh "cp $CFG.orig $CFG && rm -f $CFG.orig";;
  bound)
    RBF=$1; TAG=$2; OUT=$DC/$TAG; mkdir -p $OUT
    rsh "echo load_core /media/fat/_Other/$RBF > /dev/MiSTer_cmd"; sleep 22
    home $OUT/bound_home.png; echo "  $TAG home: $(ocr $OUT/bound_home.png)"
    for i in $(seq 30); do $MC input type / >/dev/null; sleep 0.25; done; sleep 2; $MC screenshot --output $OUT/bound_zoomout.png >/dev/null; echo "  $TAG zoom-out x30: $(ocr $OUT/bound_zoomout.png)"
    for k in r r; do $MC input type $k >/dev/null; sleep 0.4; done; sleep 1
    for i in $(seq 40); do $MC input type a >/dev/null; sleep 0.25; done; sleep 2; $MC screenshot --output $OUT/bound_left.png >/dev/null; echo "  $TAG pan-left x40: $(ocr $OUT/bound_left.png)"
    for i in $(seq 40); do $MC input type w >/dev/null; sleep 0.25; done; sleep 2; $MC screenshot --output $OUT/bound_up.png >/dev/null; echo "  $TAG pan-up x40: $(ocr $OUT/bound_up.png)";;
  cfgbyte)   # cfgbyte <offset> <hex-byte> [load <rbf>]  — patch one byte of the saved status (see CONF_STR bit map)
    rsh "printf '\\x$2' | dd of=$CFG bs=1 seek=$1 conv=notrunc 2>/dev/null; xxd -p -l 8 $CFG"
    [ "${3:-}" = load ] && { rsh "echo load_core /media/fat/_Other/$4 > /dev/MiSTer_cmd"; sleep 22; };;
  shots)     # shots <tag> <count> <interval-s>  — screenshots of whatever is running, then changed-pixel counts between consecutive shots
    OUT=$DC/$1; mkdir -p $OUT; for i in $(seq -w 1 $2); do $MC screenshot --output $OUT/shot_$i.png >/dev/null; sleep $3; done
    python3 - "$OUT" <<'PY'
import sys, glob
from PIL import Image, ImageChops
fs = sorted(glob.glob(sys.argv[1] + "/shot_*.png"))
for a, b in zip(fs, fs[1:]):
    d = ImageChops.difference(Image.open(a).convert('RGB'), Image.open(b).convert('RGB'))
    print(f"{a.split('/')[-1]} -> {b.split('/')[-1]}: changed pixels {sum(1 for p in d.getdata() if p != (0,0,0))}")
PY
    ;;
  bench)     # bench <name-on-device.rbf> <label> — fresh load, enter benchmark mode (verified, retried), run all 90 scenes
    RBF=$1; LABEL=$2; OUT=$ROOT/bench_${LABEL}_$(date +%Y%m%d).json
    rsh "echo load_core /media/fat/_Other/$RBF > /dev/MiSTer_cmd"; sleep 25
    for try in 1 2 3; do
      $MC input type b >/dev/null; sleep 13; $MC screenshot --output $DC/benchcheck.png >/dev/null
      if (cd $ROOT && python3 tools/bench_decode_screenshot.py $DC/benchcheck.png 2>/dev/null | grep -q "scene=0"); then echo "  bench mode entered (try $try)"; break; fi
      echo "  bench mode not entered (try $try)"; [ $try = 3 ] && exit 1
    done
    (cd $ROOT && python3 tools/bench_run.py --host $H --no-toggle --output "$OUT" --label "$LABEL" --keep-screenshots --screenshots-dir "$CAP/bench_${LABEL}_$(date +%Y%m%d)" 2>&1 | tail -4); echo "  results: $OUT";;
  cmp)
    python3 - "$1" "$2" "$DC" <<'PY'
import sys, glob, os
from PIL import Image, ImageChops
a, b, dc = sys.argv[1:4]
for f in sorted(glob.glob(f"{dc}/{a}/*.png")):
    g = f"{dc}/{b}/{os.path.basename(f)}"
    if not os.path.exists(g): print(f"{os.path.basename(f)}: missing in {b}"); continue
    d = ImageChops.difference(Image.open(f).convert('RGB'), Image.open(g).convert('RGB'))
    print(f"{os.path.basename(f)}: differing pixels {sum(1 for p in d.getdata() if p != (0,0,0))}")
PY
    ;;
  *) echo "usage: see header"; exit 2;;
esac
