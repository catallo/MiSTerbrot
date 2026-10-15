#!/bin/bash
# Verilator regression: 6 fractal_top_ddr benches, fb_ddr3, gallery_pitch, pixel_pipeline (checksum),
# color_mapper equivalence, iter_quad.  Run from anywhere: sim/run_all.sh
export LC_ALL=C.UTF-8
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RTL="$ROOT/build_id.v $(ls $ROOT/rtl/*.v | tr '\n' ' ')"
status=0
cd $ROOT/sim/fractal_top_ddr
for tb in tb_gallery tb_gallery_flip tb_gallery_msnap tb_gallery_pal tb_mode3 tb_mode4; do
  if verilator --binary --timing -Wno-fatal -Wno-WIDTH -I$ROOT/rtl --top $tb $tb.sv $RTL -o $tb -j 6 > $tb.buildlog 2>&1 && ./obj_dir/$tb > $tb.runlog 2>&1 && grep -q "TB PASS" $tb.runlog; then
    echo "PASS $tb"
  else echo "FAIL $tb"; status=1; tail -6 $tb.runlog 2>/dev/null; grep -m3 '%Error' $tb.buildlog; fi
done
cd $ROOT/sim/fb_ddr3 && if verilator --binary --timing -Wno-fatal -Wno-WIDTH --top tb_top tb_top.sv ../../rtl/fb_ddr3.v -o tb -j 6 > build.log 2>&1 && ./obj_dir/tb > run.log 2>&1 && grep -q "TB PASS" run.log; then echo "PASS fb_ddr3"; else echo "FAIL fb_ddr3"; status=1; tail -4 run.log; fi
cd $ROOT/sim/gallery_pitch && if verilator --binary --timing -Wno-fatal -Wno-WIDTH --top tb_pitch tb_pitch.sv ../../rtl/gallery_pitch.v -o tb -j 6 > build.log 2>&1 && ./obj_dir/tb > run.log 2>&1 && grep -q "PASS" run.log; then echo "PASS gallery_pitch"; else echo "FAIL gallery_pitch"; status=1; tail -4 run.log; fi
cd $ROOT/sim/pixel_pipeline && if verilator --binary --timing -Wno-fatal -Wno-WIDTH -I../../rtl --top tb_pp tb_pp.sv ../../rtl/pixel_pipeline.v ../../rtl/iter_quad.v ../../rtl/mul_trunc64.v -o tb_pp -j 6 > build.log 2>&1 && ./obj_dir/tb_pp +scene=1 > run.log 2>&1 && grep -q "chk=025d9feda50278c4" run.log; then echo "PASS pixel_pipeline: $(grep scene= run.log)"; else echo "FAIL pixel_pipeline (checksum)"; status=1; tail -3 run.log; fi
cd $ROOT/sim/color_mapper && if verilator --binary --timing -Wno-fatal -Wno-WIDTH --top tb_cm_equiv tb_cm_equiv.sv color_mapper_old.v ../../rtl/color_mapper.v -o tb -j 6 > build.log 2>&1 && ./obj_dir/tb > run.log 2>&1 && grep -q "mismatches=0" run.log; then echo "PASS color_mapper equiv: $(grep compared= run.log)"; else echo "FAIL color_mapper equiv"; status=1; tail -3 run.log; fi
cd $ROOT/sim/iter_quad && if make -s run > run.log 2>&1 && grep -q " 0 fail" run.log; then echo "PASS iter_quad: $(grep -iE 'cases' run.log | tail -1)"; else echo "FAIL iter_quad"; status=1; tail -6 run.log; fi
exit $status
