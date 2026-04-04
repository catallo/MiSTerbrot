//============================================================================
// Auto-Zoom Screensaver (v0.10.0)
//
// Cycles through 25 interesting Mandelbrot coordinates.
// Starts on reset, Z key toggles. Target/palette order is shuffled once per
// core reset using Fisher-Yates with LFSR-driven rejection sampling.
//============================================================================

module auto_zoom #(
    parameter WIDTH     = 64,
    parameter FRAC_BITS = 56,
    parameter [9:0] MAX_DWELL_FRAMES = 10'd600  // 10s at 60fps
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    enable,
    input  wire                    skip_next,
    input  wire                    frame_done,
    input  wire                    vblank,
    input  wire [32:0]             entropy_seed,
    input  wire [1:0]              fractal_type,

    // BRAM framebuffer sampling (held inactive in deterministic zoom mode)
    input  wire [12:0]             fb_rd_data,
    output wire [16:0]             fb_rd_addr,
    output wire                    fb_sampling,

    output reg  signed [WIDTH-1:0] center_x,
    output reg  signed [WIDTH-1:0] center_y,
    output reg  signed [WIDTH-1:0] step,
    output reg                     active,
    output reg                     view_changed,
    output reg  [5:0]              palette_idx,
    output wire [4:0]              target_idx_out
);

localparam signed [WIDTH-1:0] DEFAULT_STEP = 64'sh0003333333333333;
localparam signed [WIDTH-1:0] MIN_STEP     = 64'sh0000000000000010;
localparam N_TARGETS = 25;
localparam N_PALETTES = 47;
localparam IDX_BITS  = 5;
localparam PAL_BITS  = 6;
localparam [IDX_BITS-1:0] TARGET_LAST_IDX = N_TARGETS - 1;
localparam [PAL_BITS-1:0] PALETTE_LAST_IDX = N_PALETTES - 1;
localparam [2:0] S_IDLE=3'd0, S_ZOOM_IN=3'd1, S_ZOOM_OUT=3'd2, S_NEXT=3'd3,
                 S_SHUFFLE=3'd4, S_LOAD=3'd5;

reg [2:0] state;
reg [IDX_BITS-1:0] target_idx;
wire is_julia = 1'b0;  // Julia removed
reg [15:0] zoom_steps;
reg [9:0] dwell_count;
reg [15:0] free_counter;
reg [15:0] target_lfsr;
reg [15:0] palette_lfsr;
reg [4:0] target_playlist [0:N_TARGETS-1];
reg [5:0] palette_playlist [0:N_PALETTES-1];
reg [4:0] target_playlist_pos;
reg [5:0] palette_playlist_pos;
reg       shuffle_phase;
reg [5:0] shuffle_idx;
reg       zoom_out_final_pending;
reg       seed_pending;
integer   i;

reg signed [WIDTH-1:0] rom_cx, rom_cy;
always @(*) begin
    if (is_julia) begin
        case (target_idx)
            5'd0:  begin rom_cx=64'sh0000000000000000; rom_cy=64'sh0000000000000000; end
            5'd1:  begin rom_cx=64'shFF80000000000000; rom_cy=64'sh0000000000000000; end
            5'd2:  begin rom_cx=64'sh0080000000000000; rom_cy=64'sh0000000000000000; end
            5'd3:  begin rom_cx=64'sh0000000000000000; rom_cy=64'sh0080000000000000; end
            5'd4:  begin rom_cx=64'sh0000000000000000; rom_cy=64'shFF80000000000000; end
            5'd5:  begin rom_cx=64'shFF40000000000000; rom_cy=64'sh0040000000000000; end
            5'd6:  begin rom_cx=64'shFF40000000000000; rom_cy=64'shFFC0000000000000; end
            5'd7:  begin rom_cx=64'sh0040000000000000; rom_cy=64'sh0040000000000000; end
            5'd8:  begin rom_cx=64'sh0040000000000000; rom_cy=64'shFFC0000000000000; end
            5'd9:  begin rom_cx=64'sh00C0000000000000; rom_cy=64'sh0000000000000000; end
            5'd10: begin rom_cx=64'shFF00000000000000; rom_cy=64'sh0000000000000000; end
            5'd11: begin rom_cx=64'sh0000000000000000; rom_cy=64'sh00C0000000000000; end
            5'd12: begin rom_cx=64'sh0000000000000000; rom_cy=64'shFF40000000000000; end
            5'd13: begin rom_cx=64'sh0080000000000000; rom_cy=64'sh0080000000000000; end
            5'd14: begin rom_cx=64'sh0000000000000000; rom_cy=64'sh0000000000000000; end
            5'd15: begin rom_cx=64'shFF80000000000000; rom_cy=64'sh0000000000000000; end
            5'd16: begin rom_cx=64'sh0080000000000000; rom_cy=64'sh0000000000000000; end
            5'd17: begin rom_cx=64'sh0000000000000000; rom_cy=64'sh0080000000000000; end
            5'd18: begin rom_cx=64'sh0000000000000000; rom_cy=64'shFF80000000000000; end
            5'd19: begin rom_cx=64'shFF40000000000000; rom_cy=64'sh0040000000000000; end
            5'd20: begin rom_cx=64'shFF40000000000000; rom_cy=64'shFFC0000000000000; end
            5'd21: begin rom_cx=64'sh0040000000000000; rom_cy=64'sh0040000000000000; end
            5'd22: begin rom_cx=64'sh0040000000000000; rom_cy=64'shFFC0000000000000; end
            5'd23: begin rom_cx=64'sh00C0000000000000; rom_cy=64'sh0000000000000000; end
            5'd24: begin rom_cx=64'shFF00000000000000; rom_cy=64'sh0000000000000000; end
            default: begin rom_cx=64'sh0000000000000000; rom_cy=64'sh0000000000000000; end
        endcase
    end else begin
        case (target_idx)
            5'd0:  begin rom_cx=64'shFF40000000000000; rom_cy=64'sh001999999999999A; end
            5'd1:  begin rom_cx=64'sh0040000000000000; rom_cy=64'sh0000000000000000; end
            5'd2:  begin rom_cx=64'sh0000000000000000; rom_cy=64'sh0100000000000000; end
            5'd3:  begin rom_cx=64'shFF40F27BB2FEC570; rom_cy=64'sh001C36113404EA4B; end
            5'd4:  begin rom_cx=64'shFFE61E4F765FD8AE; rom_cy=64'sh00F4D013A92A3058; end
            5'd5:  begin rom_cx=64'shFE994DE7EA5F84D0; rom_cy=64'sh0000000000000000; end
            5'd6:  begin rom_cx=64'shFF412BA16E7A3120; rom_cy=64'sh001CEE2867275686; end
            5'd7:  begin rom_cx=64'shFE3B3D07C84B5DD0; rom_cy=64'sh00007357E670E2C1; end
            5'd8:  begin rom_cx=64'shFFF46DC5D638865A; rom_cy=64'sh00FC9EECBFB15B58; end
            5'd9:  begin rom_cx=64'shFF404189374BC6A8; rom_cy=64'sh00083126E978D4FE; end
            5'd10: begin rom_cx=64'shFE3B645A1CAC0830; rom_cy=64'sh00004189374BC6A8; end
            5'd11: begin rom_cx=64'shFFD70A3D70A3D70A; rom_cy=64'sh010A5E353F7CED90; end
            5'd12: begin rom_cx=64'sh0040000000000000; rom_cy=64'sh0000068DB8BAC711; end
            5'd13: begin rom_cx=64'shFF41A08DA9A14E98; rom_cy=64'sh0021BF5799440944; end
            5'd14: begin rom_cx=64'shFE404189374BC6A8; rom_cy=64'sh0000000000000000; end
            5'd15: begin rom_cx=64'shFFD73EAB367A0F91; rom_cy=64'sh01081D7DBF487FCC; end
            5'd16: begin rom_cx=64'shFE03D70A3D70A3D7; rom_cy=64'sh0000000000000000; end
            5'd17: begin rom_cx=64'shFFD8E219652BD3C3; rom_cy=64'sh010A29C779A6B50B; end
            5'd18: begin rom_cx=64'shFF4083126E978D50; rom_cy=64'sh001999999999999A; end
            5'd19: begin rom_cx=64'shFFE6666666666666; rom_cy=64'sh00A6A7EF9DB22D0E; end
            5'd20: begin rom_cx=64'shFFF3126E978D4FDF; rom_cy=64'sh00FC7E28240B7803; end
            5'd21: begin rom_cx=64'shFEBFD4BF0995AAF8; rom_cy=64'sh0005269595FEDA66; end
            5'd22: begin rom_cx=64'shFF3D097C80841EDE; rom_cy=64'shFFEA4D31E1FA5B7B; end
            5'd23: begin rom_cx=64'sh0048F5C28F5C28F6; rom_cy=64'sh00028F5C28F5C28F; end
            5'd24: begin rom_cx=64'shFFA04143C66D260D; rom_cy=64'sh00A8E823D5C81E11; end
            default: begin rom_cx=64'shFF40000000000000; rom_cy=64'sh001999999999999A; end
        endcase
    end
end

wire signed [WIDTH-1:0] step_shift = step >>> 9;
wire signed [WIDTH-1:0] step_delta = (step_shift == {WIDTH{1'b0}}) ? {{(WIDTH-1){1'b0}}, 1'b1} : step_shift;

function [15:0] lfsr_advance;
    input [15:0] state_in;
    begin
        lfsr_advance = {state_in[14:0], state_in[15] ^ state_in[13] ^ state_in[12] ^ state_in[10]};
    end
endfunction

function [5:0] next_shuffle_candidate;
    input [31:0] rand_state;
    input [5:0] max_idx;
    reg   [5:0] c0, c1, c2, c3, c4;
    begin
        c0 = rand_state[5:0];
        c1 = rand_state[11:6];
        c2 = rand_state[17:12];
        c3 = rand_state[23:18];
        c4 = rand_state[29:24];

        if (c0 <= max_idx)
            next_shuffle_candidate = c0;
        else if (c1 <= max_idx)
            next_shuffle_candidate = c1;
        else if (c2 <= max_idx)
            next_shuffle_candidate = c2;
        else if (c3 <= max_idx)
            next_shuffle_candidate = c3;
        else if (c4 <= max_idx)
            next_shuffle_candidate = c4;
        else
            next_shuffle_candidate = 6'h3F;
    end
endfunction

function [1:0] nibble_msb;
    input [3:0] nibble;
    begin
        casez (nibble)
            4'b1???: nibble_msb = 2'd3;
            4'b01??: nibble_msb = 2'd2;
            4'b001?: nibble_msb = 2'd1;
            default: nibble_msb = 2'd0;
        endcase
    end
endfunction

reg [5:0] step_msb;
always @(*) begin
    if (step[63:60] != 4'd0)      step_msb = 6'd60 + {4'd0, nibble_msb(step[63:60])};
    else if (step[59:56] != 4'd0) step_msb = 6'd56 + {4'd0, nibble_msb(step[59:56])};
    else if (step[55:52] != 4'd0) step_msb = 6'd52 + {4'd0, nibble_msb(step[55:52])};
    else if (step[51:48] != 4'd0) step_msb = 6'd48 + {4'd0, nibble_msb(step[51:48])};
    else if (step[47:44] != 4'd0) step_msb = 6'd44 + {4'd0, nibble_msb(step[47:44])};
    else if (step[43:40] != 4'd0) step_msb = 6'd40 + {4'd0, nibble_msb(step[43:40])};
    else if (step[39:36] != 4'd0) step_msb = 6'd36 + {4'd0, nibble_msb(step[39:36])};
    else if (step[35:32] != 4'd0) step_msb = 6'd32 + {4'd0, nibble_msb(step[35:32])};
    else if (step[31:28] != 4'd0) step_msb = 6'd28 + {4'd0, nibble_msb(step[31:28])};
    else if (step[27:24] != 4'd0) step_msb = 6'd24 + {4'd0, nibble_msb(step[27:24])};
    else if (step[23:20] != 4'd0) step_msb = 6'd20 + {4'd0, nibble_msb(step[23:20])};
    else if (step[19:16] != 4'd0) step_msb = 6'd16 + {4'd0, nibble_msb(step[19:16])};
    else if (step[15:12] != 4'd0) step_msb = 6'd12 + {4'd0, nibble_msb(step[15:12])};
    else if (step[11:8] != 4'd0)  step_msb = 6'd8  + {4'd0, nibble_msb(step[11:8])};
    else if (step[7:4] != 4'd0)   step_msb = 6'd4  + {4'd0, nibble_msb(step[7:4])};
    else                           step_msb = {4'd0, nibble_msb(step[3:0])};
end

wire [5:0] zoom_exp = (step >= DEFAULT_STEP) ? 6'd0 : (6'd49 - step_msb);

// Fractional zoom (tenths) for precise target comparison
wire [63:0] step_norm_az = step << (6'd63 - step_msb);
wire [3:0]  frac_nibble_az = step_norm_az[62:59];
reg  [3:0]  zoom_frac_tenth_az;
always @(*) begin
    if (step >= DEFAULT_STEP)         zoom_frac_tenth_az = 4'd0;
    else if (frac_nibble_az >= 4'd14) zoom_frac_tenth_az = 4'd0;
    else if (frac_nibble_az >= 4'd13) zoom_frac_tenth_az = 4'd1;
    else if (frac_nibble_az >= 4'd11) zoom_frac_tenth_az = 4'd2;
    else if (frac_nibble_az >= 4'd9)  zoom_frac_tenth_az = 4'd3;
    else if (frac_nibble_az >= 4'd7)  zoom_frac_tenth_az = 4'd4;
    else if (frac_nibble_az >= 4'd6)  zoom_frac_tenth_az = 4'd5;
    else if (frac_nibble_az >= 4'd4)  zoom_frac_tenth_az = 4'd6;
    else if (frac_nibble_az >= 4'd3)  zoom_frac_tenth_az = 4'd7;
    else if (frac_nibble_az >= 4'd1)  zoom_frac_tenth_az = 4'd8;
    else                              zoom_frac_tenth_az = 4'd9;
end

wire [9:0] zoom_level_x10 = zoom_exp * 4'd10 + {6'd0, zoom_frac_tenth_az};
reg  [9:0] target_max_zoom_x10;
always @(*) begin
    case (target_idx)
        5'd0: target_max_zoom_x10 = 10'd105; // Seahorse Entry 10.5
        5'd1: target_max_zoom_x10 = 10'd80; // Cardioid Interior 8.0
        5'd2: target_max_zoom_x10 = 10'd100; // Upper Boundary 10.0
        5'd3: target_max_zoom_x10 = 10'd140; // Seahorse Valley 14.0
        5'd4: target_max_zoom_x10 = 10'd180; // Upper Dendrite 18.0
        5'd5: target_max_zoom_x10 = 10'd165; // Period-2 Neck 16.5
        5'd6: target_max_zoom_x10 = 10'd200; // Deep Seahorse 20.0
        5'd7: target_max_zoom_x10 = 10'd130; // Elephant Edge 13.0
        5'd8: target_max_zoom_x10 = 10'd170; // Filament Crown
        5'd9: target_max_zoom_x10 = 10'd110; // Needle Corridor 11.0
        5'd10: target_max_zoom_x10 = 10'd120; // Deep Elephant
        5'd11: target_max_zoom_x10 = 10'd120; // Halo Filaments 12.0
        5'd12: target_max_zoom_x10 = 10'd80; // Cardioid Edge 8.0
        5'd13: target_max_zoom_x10 = 10'd190; // Spiral Valley 19.0
        5'd14: target_max_zoom_x10 = 10'd180; // Mini-Brot
        5'd15: target_max_zoom_x10 = 10'd93; // Double Spiral 9.3
        5'd16: target_max_zoom_x10 = 10'd120; // Antenna Tip 12.0
        5'd17: target_max_zoom_x10 = 10'd170; // Baby Mandelbrot
        5'd18: target_max_zoom_x10 = 10'd156; // Seahorse Tail 15.6
        5'd19: target_max_zoom_x10 = 10'd105; // Elephant Trunk 10.5
        5'd20: target_max_zoom_x10 = 10'd180; // Triple Spiral 18.0
        5'd21: target_max_zoom_x10 = 10'd170; // Dendrite Junction
        5'd22: target_max_zoom_x10 = 10'd190; // Swirl
        5'd23: target_max_zoom_x10 = 10'd120; // Lightning 12.0
        5'd24: target_max_zoom_x10 = 10'd160; // Starfish
        default: target_max_zoom_x10 = 10'd150;
    endcase
end

reg enable_prev;
wire enable_rise = enable & ~enable_prev;
reg next_loaded;
wire unused_ok = &{1'b0, vblank, fb_rd_data[12:0]};
wire [15:0] target_seed_mix = entropy_seed[15:0] ^ entropy_seed[31:16] ^ {15'd0, entropy_seed[32]};
wire [15:0] palette_seed_mix = {entropy_seed[23:8]} ^ {entropy_seed[7:0], entropy_seed[31:24]} ^ {15'd0, entropy_seed[32]};
wire [15:0] next_target_lfsr = lfsr_advance(target_lfsr ^ free_counter);
wire [15:0] next_target_lfsr2 = lfsr_advance(next_target_lfsr ^ {free_counter[7:0], free_counter[15:8]});
wire [15:0] next_palette_lfsr = lfsr_advance(palette_lfsr ^ {free_counter[7:0], free_counter[15:8]});
wire [15:0] next_palette_lfsr2 = lfsr_advance(next_palette_lfsr ^ free_counter);
wire [31:0] target_rand_pool = {next_target_lfsr2, next_target_lfsr};
wire [31:0] palette_rand_pool = {next_palette_lfsr2, next_palette_lfsr};
wire [5:0] shuffle_target_j = next_shuffle_candidate(target_rand_pool, shuffle_idx);
wire [5:0] shuffle_palette_j = next_shuffle_candidate(palette_rand_pool, shuffle_idx);
wire target_shuffle_accept = (shuffle_target_j <= shuffle_idx);
wire palette_shuffle_accept = (shuffle_palette_j <= shuffle_idx);
wire [4:0] target_hi_val = target_playlist[shuffle_idx[4:0]];
wire [4:0] target_lo_val = target_shuffle_accept ? target_playlist[shuffle_target_j[4:0]] : 5'd0;
wire [5:0] palette_hi_val = palette_playlist[shuffle_idx];
wire [5:0] palette_lo_val = palette_shuffle_accept ? palette_playlist[shuffle_palette_j] : 6'd0;
wire [5:0] palette_first_val = (shuffle_idx == 6'd1 && shuffle_palette_j == 6'd0) ? palette_hi_val : palette_playlist[0];

assign fb_rd_addr = 17'd0;
assign fb_sampling = 1'b0;
assign target_idx_out = target_idx;

wire dwell_done = (dwell_count >= (MAX_DWELL_FRAMES - 10'd1));

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_SHUFFLE; active <= 1'b1; view_changed <= 1'b1;
        center_x <= 64'shFF40000000000000; center_y <= 64'sh001999999999999A;
        step <= DEFAULT_STEP; target_idx <= 5'd0;
        palette_idx <= 6'd0; enable_prev <= 1'b0; next_loaded <= 1'b0;
        zoom_steps <= 16'd0;
        dwell_count <= 10'd0;
        free_counter <= 16'h0001;
        target_lfsr <= 16'hA5C3;
        palette_lfsr <= 16'h5E31;
        target_playlist_pos <= 5'd1;
        palette_playlist_pos <= 6'd1;
        shuffle_phase <= 1'b0;
        shuffle_idx <= TARGET_LAST_IDX;
        zoom_out_final_pending <= 1'b0;
        seed_pending <= 1'b1;
        for (i = 0; i < N_TARGETS; i = i + 1)
            target_playlist[i] <= i[4:0];
        for (i = 0; i < N_PALETTES; i = i + 1)
            palette_playlist[i] <= i[5:0];
    end else begin
        if (unused_ok) begin end
        free_counter <= free_counter + 16'd1;
        enable_prev <= enable; view_changed <= 1'b0;
        if (seed_pending) begin
            target_lfsr <= 16'hA5C3 ^ target_seed_mix;
            palette_lfsr <= 16'h5E31 ^ palette_seed_mix;
            seed_pending <= 1'b0;
        end else case (state)
        S_SHUFFLE: begin
            active <= 1'b0;
            if (!shuffle_phase) begin
                target_lfsr <= next_target_lfsr2;
                if (target_shuffle_accept) begin
                    target_playlist[shuffle_idx[4:0]] <= target_lo_val;
                    target_playlist[shuffle_target_j[4:0]] <= target_hi_val;
                    if (shuffle_idx == 6'd1) begin
                        shuffle_phase <= 1'b1;
                        shuffle_idx <= PALETTE_LAST_IDX;
                    end else begin
                        shuffle_idx <= shuffle_idx - 6'd1;
                    end
                end
            end else begin
                palette_lfsr <= next_palette_lfsr2;
                if (palette_shuffle_accept) begin
                    palette_playlist[shuffle_idx] <= palette_lo_val;
                    palette_playlist[shuffle_palette_j] <= palette_hi_val;
                    if (shuffle_idx == 6'd1) begin
                        target_idx <= target_playlist[0];
                        palette_idx <= palette_first_val;
                        target_playlist_pos <= 5'd1;
                        palette_playlist_pos <= 6'd1;
                        state <= S_LOAD;
                    end else begin
                        shuffle_idx <= shuffle_idx - 6'd1;
                    end
                end
            end
        end
        S_LOAD: begin
            if (!enable) begin
                active <= 1'b0;
                state <= S_IDLE;
            end else begin
                center_x <= rom_cx;
                center_y <= rom_cy;
                step <= DEFAULT_STEP;
                zoom_steps <= 16'd0;
                dwell_count <= 10'd0;
                active <= 1'b1;
                view_changed <= 1'b1;
                next_loaded <= 1'b0;
                zoom_out_final_pending <= 1'b0;
                state <= S_ZOOM_IN;
            end
        end
        S_IDLE: begin
            active <= 1'b0;
            if (enable_rise) begin
                center_x<=rom_cx; center_y<=rom_cy; step<=DEFAULT_STEP;
                zoom_steps<=16'd0; dwell_count<=8'd0;
                active<=1'b1; view_changed<=1'b1; zoom_out_final_pending<=1'b0; state<=S_ZOOM_IN;
            end
        end
        S_ZOOM_IN: begin
            if (!enable) begin active<=1'b0; state<=S_IDLE; dwell_count<=10'd0; zoom_out_final_pending<=1'b0; end
            else if (skip_next) begin dwell_count<=10'd0; next_loaded<=1'b0; state<=S_NEXT; end
            else if (frame_done) begin
                if ((step <= MIN_STEP) || (zoom_level_x10 >= target_max_zoom_x10)) begin
                    if (dwell_done) begin
                        dwell_count <= 10'd0;
                        zoom_out_final_pending <= 1'b0;
                        state <= S_ZOOM_OUT;
                    end else begin
                        dwell_count <= dwell_count + 10'd1;
                    end
                end else begin
                    dwell_count <= 10'd0;
                    step <= step - step_delta;
                    zoom_steps <= zoom_steps + 16'd1;
                    view_changed <= 1'b1;
                end
            end
        end
        S_ZOOM_OUT: begin
            if (!enable) begin active<=1'b0; state<=S_IDLE; dwell_count<=10'd0; zoom_out_final_pending<=1'b0; end
            else if (skip_next) begin dwell_count<=10'd0; next_loaded<=1'b0; zoom_out_final_pending<=1'b0; state<=S_NEXT; end
            else if (frame_done) begin
                if (zoom_out_final_pending) begin
                    zoom_out_final_pending <= 1'b0;
                    next_loaded <= 1'b0;
                    dwell_count <= 10'd0;
                    state <= S_NEXT;
                end else if (zoom_steps == 16'd0) begin
                    step <= DEFAULT_STEP;
                    view_changed <= 1'b1;
                    zoom_out_final_pending <= 1'b1;
                end else begin
                    step <= step + step_delta;
                    zoom_steps <= zoom_steps - 16'd1;
                    view_changed <= 1'b1;
                end
            end
        end
        S_NEXT: begin
            if (!enable) begin active<=1'b0; state<=S_IDLE; dwell_count<=8'd0; end
            else if (!next_loaded) begin
                target_idx <= target_playlist[target_playlist_pos];
                palette_idx <= palette_playlist[palette_playlist_pos];
                target_playlist_pos <= (target_playlist_pos == TARGET_LAST_IDX) ? 5'd0 : (target_playlist_pos + 5'd1);
                palette_playlist_pos <= (palette_playlist_pos == PALETTE_LAST_IDX) ? 6'd0 : (palette_playlist_pos + 6'd1);
                next_loaded <= 1'b1;
            end else begin
                center_x<=rom_cx; center_y<=rom_cy; step<=DEFAULT_STEP;
                zoom_steps<=16'd0; dwell_count<=8'd0;
                view_changed<=1'b1; state<=S_ZOOM_IN;
            end
        end
        default: state <= S_IDLE;
        endcase
    end
end

endmodule
