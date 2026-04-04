//============================================================================
// MiSTerbrot Top - v0.9.0 Core Module
//
// BRAM double-buffered 320x240, DSP time-shared iter_pair iterators,
// 12-bit iteration count (up to 2048), 42 color palettes.
//
// Pipeline: input_handler -> coord_generator -> pixel_pipeline -> framebuffer
//           video_timing -> framebuffer read -> color_mapper -> VGA output
//
// Critical fix: buffer swap ONLY during VBLANK rising edge.
// Display always reads from front buffer = zero tearing.
//
// 50 MHz system clock, ce_pix pulses every 8th clock for 6.25 MHz pixel clock.
// Native 240p output (320x240 @ 15kHz). MiSTer ascaler handles upscaling.
//============================================================================

module fractal_top #(
    parameter H_RES       = 320,
    parameter V_RES       = 240,
    parameter N_ITERATORS = 8,
    parameter WIDTH       = 64,
    parameter FRAC_BITS   = 56
)(
    input  wire        clk,       // 50 MHz
    input  wire        rst_n,

    // MiSTer interface
    input  wire [15:0] joystick,
    input  wire [10:0] ps2_key,
    input  wire [127:0] status,
    input  wire [32:0] entropy_seed,

    // Video output (native 240p timing)
    output wire        ce_pix,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,

    // Status
    output wire        rendering
);

// ---- Pixel clock: 50 MHz / 8 = 6.25 MHz ----
reg [2:0] ce_pix_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) ce_pix_cnt <= 3'd0;
    else        ce_pix_cnt <= ce_pix_cnt + 3'd1;
end
assign ce_pix = (ce_pix_cnt == 3'd0);

// ---- OSD Parameter Decoding ----
wire [1:0] osd_fractal_type;
wire [5:0] osd_palette_sel;
wire [2:0] osd_iter_sel;
wire       osd_iter_changed;
wire       osd_color_cycle_enable;
wire       osd_reset;
wire       single_buffer;
wire       blank_text_enable;
wire       always_show_fps;
wire       always_show_poi;

fractal_osd #(
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS)
) u_osd (
    .clk(clk),
    .rst_n(rst_n),
    .status(status),
    .fractal_type(osd_fractal_type),
    .palette_sel(osd_palette_sel),
    .osd_iter_sel(osd_iter_sel),
    .osd_iter_changed(osd_iter_changed),
    .color_cycle_enable(osd_color_cycle_enable),
    
    .osd_reset(osd_reset),
    .single_buffer(single_buffer),
    .blank_text_enable(blank_text_enable),
    .always_show_fps(always_show_fps),
    .always_show_poi(always_show_poi)
);

// ---- Input Handler ----
wire signed [WIDTH-1:0] input_center_x;
wire signed [WIDTH-1:0] input_center_y;
wire signed [WIDTH-1:0] input_step;
wire [1:0]              input_fractal_type;
wire [5:0]              input_palette_sel;
wire                    input_palette_override;
wire [2:0]              input_iter_sel;
wire                    overlay_enable;
wire                    color_cycle_enable;
wire                    input_view_changed;
wire                    auto_zoom_toggle;
wire                    auto_zoom_deactivate;
wire                    auto_zoom_skip_next;
wire                    auto_zoom_active;
wire signed [WIDTH-1:0] az_center_x;
wire signed [WIDTH-1:0] az_center_y;
wire signed [WIDTH-1:0] az_step;
wire                    az_view_changed;
wire [5:0]              az_palette_idx;
wire [16:0]             az_fb_rd_addr;
wire                    az_fb_sampling;
wire [4:0]              az_target_idx;
reg  [4:0]              az_target_idx_prev;
reg                     az_enable;
reg                     az_enable_prev;
wire                    auto_zoom_handoff = az_enable_prev & ~az_enable;

// ---- Overlay visibility timer (6s after last input) ----
localparam [28:0] OVERLAY_SHOW_TICKS = 29'd500_000_000;  // 10s @ 50MHz
reg [28:0] overlay_timer;
reg        overlay_visible;
reg [15:0] joystick_prev;
reg        ps2_strobe_prev;
wire       overlay_wakeup = (|(joystick ^ joystick_prev)) | (ps2_key[10] != ps2_strobe_prev);

input_handler #(
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS)
) u_input (
    .clk(clk),
    .rst_n(rst_n),
    .joystick(joystick),
    .ps2_key(ps2_key),
    .step_in(input_step),
    .center_x(input_center_x),
    .center_y(input_center_y),
    .step(input_step),
    .fractal_type(input_fractal_type),
    .palette_sel(input_palette_sel),
    .palette_override_active(input_palette_override),
    .osd_iter_sel(osd_iter_sel),
    .osd_iter_changed(osd_iter_changed),
    .sync_clear_palette_override(auto_zoom_active && (az_target_idx != az_target_idx_prev)),
    .iter_sel(input_iter_sel),
    .overlay_enable(overlay_enable),
    .color_cycle_enable(color_cycle_enable),
    .view_changed(input_view_changed),
    .auto_zoom_toggle(auto_zoom_toggle),
    .auto_zoom_deactivate(auto_zoom_deactivate),
    .auto_zoom_skip_next(auto_zoom_skip_next),
    .auto_zoom_active(auto_zoom_active),
    .sync_from_auto_zoom(auto_zoom_handoff),
    .sync_center_x(az_center_x),
    .sync_center_y(az_center_y),
    .sync_step(az_step),
    .sync_palette_sel(az_palette_idx)
);

// ---- Framebuffer parameters (needed by auto_zoom and framebuffer) ----
localparam FB_ADDR_WIDTH = 17;  // ceil(log2(320*240))
localparam FB_DATA_WIDTH = 13;  // 12-bit iter + 1-bit escaped

// ---- Auto-Zoom Screensaver ----
wire [1:0]              selected_fractal_type = (|osd_fractal_type) ? osd_fractal_type : input_fractal_type;

// Enable: toggle on Z/Space press, force off on deactivate, start enabled
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        az_enable <= 1'b1;  // Auto-start screensaver
        az_enable_prev <= 1'b1;
    end else begin
        az_enable_prev <= az_enable;
        if (auto_zoom_deactivate)
        az_enable <= 1'b0;
        else if (auto_zoom_toggle)
        az_enable <= ~az_enable;
    end
end

// Forward declaration: rd_data from framebuffer (declared below)
wire [FB_DATA_WIDTH-1:0] rd_data;

auto_zoom #(
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS)
) u_auto_zoom (
    .clk(clk),
    .rst_n(rst_n),
    .enable(az_enable),
    .skip_next(auto_zoom_skip_next),
    .frame_done(vblank_rise),
    .vblank(vblank),
    .entropy_seed(entropy_seed),
    .fractal_type(selected_fractal_type),
    .fb_rd_data(rd_data),
    .fb_rd_addr(az_fb_rd_addr),
    .fb_sampling(az_fb_sampling),
    .center_x(az_center_x),
    .center_y(az_center_y),
    .step(az_step),
    .active(auto_zoom_active),
    .view_changed(az_view_changed),
    .palette_idx(az_palette_idx),
    .target_idx_out(az_target_idx)
);

// ---- Mux: auto_zoom overrides manual when active ----
wire signed [WIDTH-1:0] center_x    = auto_zoom_active ? az_center_x : input_center_x;
wire signed [WIDTH-1:0] center_y    = auto_zoom_active ? az_center_y : input_center_y;
wire signed [WIDTH-1:0] step        = auto_zoom_active ? az_step        : input_step;
wire                    view_changed = auto_zoom_active ? az_view_changed : input_view_changed;

// OSD overrides for fractal_type/palette; iterations can come from OSD or keyboard.
wire [1:0] fractal_type = selected_fractal_type;
wire       osd_palette_override = (osd_palette_sel != 6'd0);
wire [5:0] osd_palette_idx_full = osd_palette_sel - 6'd1;
wire [5:0] osd_palette_idx = osd_palette_idx_full;
wire [5:0] palette_sel  = osd_palette_override ? osd_palette_idx :
                          input_palette_override ? input_palette_sel :
                          auto_zoom_active       ? az_palette_idx  : input_palette_sel;
reg  [11:0] input_max_iter;
wire [11:0] max_iter     = input_max_iter;  // keyboard-only (unified)
reg  [1:0] fractal_type_prev;
reg  [5:0] palette_sel_prev;
reg  [11:0] max_iter_prev;
wire settings_changed = (fractal_type != fractal_type_prev) ||
                        (palette_sel != palette_sel_prev) ||
                        (max_iter != max_iter_prev);

always @(*) begin
    case (input_iter_sel)
        3'd0:    input_max_iter = 12'd128;
        3'd1:    input_max_iter = 12'd256;
        3'd2:    input_max_iter = 12'd512;
        3'd3:    input_max_iter = 12'd1024;
        default: input_max_iter = 12'd2048;
    endcase
end

// Julia set parameter: c = -0.7269 + 0.1889i (8.56 fixed-point)
wire signed [WIDTH-1:0] julia_cr = 64'shFF45A5A5A0000000;
wire signed [WIDTH-1:0] julia_ci = 64'sh003058D670000000;
localparam [24:0] FPS_SAMPLE_TICKS = 25'd25000000;

// ======================================================================
// DOUBLE-BUFFER CONTROL
// ======================================================================
// bank_sel: 0 = display A / render B, 1 = display B / render A
// Swap ONLY on VBLANK rising edge after frame completes = zero tearing.
// ======================================================================

reg  bank_sel;
reg  frame_complete;  // Latched on frame_done, cleared on swap
wire frame_done;
reg  frame_done_prev;
wire frame_done_rise;
reg [24:0] fps_tick_counter;
reg [6:0]  fps_halfsec_count;
reg [6:0]  fps_value;
wire [6:0] fps_sample_count = fps_halfsec_count + {6'd0, frame_done_rise};
wire [6:0] fps_sample_value = {fps_sample_count[5:0], 1'b0};

// VBLANK rising edge detector
reg vblank_prev;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        vblank_prev <= 1'b0;
    else
        vblank_prev <= vblank;
end
wire vblank_rise = vblank & ~vblank_prev;
assign frame_done_rise = frame_done & ~frame_done_prev;

// Bank swap state machine
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bank_sel       <= 1'b0;
        frame_complete <= 1'b0;
        frame_done_prev <= 1'b0;
    end else begin
        frame_done_prev <= frame_done;

        if (frame_done_rise)
            frame_complete <= 1'b1;

        if (vblank_rise && (frame_complete || frame_done_rise)) begin
            bank_sel       <= ~bank_sel;
            frame_complete <= 1'b0;
        end
    end
end

// ---- FPS Counter ----
// Sample completed render frames over 500 ms, then double for FPS.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fps_tick_counter  <= 25'd0;
        fps_halfsec_count <= 7'd0;
        fps_value         <= 7'd0;
    end else begin
        if (frame_done_rise)
            fps_halfsec_count <= fps_halfsec_count + 7'd1;

        if (fps_tick_counter == FPS_SAMPLE_TICKS - 25'd1) begin
            fps_tick_counter  <= 25'd0;
            fps_value         <= fps_sample_value;
            fps_halfsec_count <= frame_done_rise ? 7'd1 : 7'd0;
        end else begin
            fps_tick_counter <= fps_tick_counter + 25'd1;
        end
    end
end

// ---- Render Control ----
// State machine: IDLE -> RENDER -> WAIT_SWAP -> (RENDER or IDLE)
localparam [1:0] RS_IDLE      = 2'd0,
                 RS_RENDER    = 2'd1,
                 RS_WAIT_SWAP = 2'd2;

reg [1:0] render_state;
reg       start_render;
reg       need_rerender;  // Latches view_changed during render/wait

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        render_state <= RS_RENDER;
        start_render <= 1'b1;  // Render first frame on startup
        need_rerender <= 1'b0;
        fractal_type_prev <= 2'd0;
        az_target_idx_prev <= 5'd0;
        palette_sel_prev  <= 6'd0;
        max_iter_prev     <= 12'd512;
    end else begin
        start_render <= 1'b0;
        fractal_type_prev <= fractal_type;
        az_target_idx_prev <= az_target_idx;
        palette_sel_prev  <= palette_sel;
        max_iter_prev     <= max_iter;

        // Latch view changes during render or wait
        if ((view_changed || settings_changed) && render_state != RS_IDLE)
            need_rerender <= 1'b1;

        case (render_state)
        RS_IDLE: begin
            if (view_changed || settings_changed || need_rerender) begin
                start_render  <= 1'b1;
                need_rerender <= 1'b0;
                render_state  <= RS_RENDER;
            end
        end

        RS_RENDER: begin
            if (frame_done)
                render_state <= RS_WAIT_SWAP;
        end

        RS_WAIT_SWAP: begin
            // Wait for VBLANK swap before starting next render
            if (vblank_rise && frame_complete) begin
                if (view_changed || settings_changed || need_rerender) begin
                    start_render  <= 1'b1;
                    need_rerender <= 1'b0;
                    render_state  <= RS_RENDER;
                end else begin
                    render_state <= RS_IDLE;
                end
            end
        end

        default: render_state <= RS_IDLE;
        endcase
    end
end

assign rendering = (render_state == RS_RENDER);

// ---- Pixel Pipeline ----
wire        pipe_result_valid;
wire [10:0] pipe_result_x;
wire [9:0]  pipe_result_y;
wire [11:0] pipe_result_iter;
wire        pipe_result_escaped;

pixel_pipeline #(
    .N_ITERATORS(N_ITERATORS),
    .H_RES(H_RES),
    .V_RES(V_RES),
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS)
) u_pipeline (
    .clk(clk),
    .rst_n(rst_n),
    .start_frame(start_render),
    .frame_done(frame_done),
    .fractal_type(fractal_type),
    .julia_cr(julia_cr),
    .julia_ci(julia_ci),
    .max_iter(max_iter),
    .center_x(center_x),
    .center_y(center_y),
    .step(step),
    .result_valid(pipe_result_valid),
    .result_x(pipe_result_x),
    .result_y(pipe_result_y),
    .result_iter(pipe_result_iter),
    .result_escaped(pipe_result_escaped)
);

// ---- Framebuffer ----
// Write address: y*320 + x = (y<<8) + (y<<6) + x
wire [FB_ADDR_WIDTH-1:0] wr_y = {9'd0, pipe_result_y[7:0]};
wire [FB_ADDR_WIDTH-1:0] wr_x = {8'd0, pipe_result_x[8:0]};
wire [FB_ADDR_WIDTH-1:0] wr_addr = (wr_y << 8) + (wr_y << 6) + wr_x;
wire [FB_DATA_WIDTH-1:0] wr_data = {pipe_result_escaped, pipe_result_iter};

// Read address: native 320x240 — no pixel doubling needed
wire [10:0] vid_pixel_x;
wire [9:0]  vid_pixel_y;
wire [FB_ADDR_WIDTH-1:0] rd_y = {9'd0, vid_pixel_y[7:0]};
wire [FB_ADDR_WIDTH-1:0] rd_x = {8'd0, vid_pixel_x[8:0]};
wire [FB_ADDR_WIDTH-1:0] vid_rd_addr = (rd_y << 8) + (rd_y << 6) + rd_x;

// Mux read address: auto_zoom sampling during VBLANK, video display otherwise
wire [FB_ADDR_WIDTH-1:0] rd_addr = az_fb_sampling ? az_fb_rd_addr : vid_rd_addr;

framebuffer #(
    .DATA_WIDTH(FB_DATA_WIDTH),
    .ADDR_WIDTH(FB_ADDR_WIDTH)
) u_framebuffer (
    .clk(clk),
    .wr_en(pipe_result_valid),
    .wr_addr(wr_addr),
    .wr_data(wr_data),
    .rd_addr(rd_addr),
    .rd_data(rd_data),
    .bank_sel(bank_sel),
    .display_bank_sel(single_buffer ? ~bank_sel : bank_sel)
);

// ---- Video Timing ----
wire vid_active;
reg  vid_active_d;
reg [10:0] vid_pixel_x_d;
reg [9:0]  vid_pixel_y_d;

video_timing u_video_timing (
    .clk(clk),
    .rst_n(rst_n),
    .ce_pix(ce_pix),
    .hsync(hsync),
    .vsync(vsync),
    .hblank(hblank),
    .vblank(vblank),
    .active(vid_active),
    .pixel_x(vid_pixel_x),
    .pixel_y(vid_pixel_y)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vid_active_d  <= 1'b0;
        vid_pixel_x_d <= 11'd0;
        vid_pixel_y_d <= 10'd0;
    end else if (ce_pix) begin
        vid_active_d  <= vid_active;
        vid_pixel_x_d <= vid_pixel_x;
        vid_pixel_y_d <= vid_pixel_y;
    end
end

// ---- Color Mapping (display path) ----
wire        fb_escaped = rd_data[12];
wire [11:0] fb_iter   = rd_data[11:0];

wire [7:0] disp_r, disp_g, disp_b;
wire [7:0] overlay_r, overlay_g, overlay_b;
// Color Cycling: unified mode from keyboard (OSD also sets same values)
// 0=Auto (on during auto-zoom), 1=On, 2=Off
wire       effective_color_cycle_enable = osd_color_cycle_enable & color_cycle_enable;

color_mapper u_color_mapper (
    .clk(clk),
    .rst_n(rst_n),
    .vblank_rise(vblank_rise),
    .pixel_valid_in(vid_active_d & ce_pix),
    .iter_count(fb_iter),
    .escaped(fb_escaped),
    .palette_sel(palette_sel),
    .cycle_enable(effective_color_cycle_enable),
    .pixel_valid_out(),
    .color_r(disp_r),
    .color_g(disp_g),
    .color_b(disp_b)
);

text_overlay #(
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS)
) u_text_overlay (
    .clk(clk),
    .overlay_enable(overlay_enable),
    .overlay_visible(overlay_visible),
    .blank_text_enable(blank_text_enable),
    .always_show_fps(always_show_fps),
    .always_show_poi(always_show_poi),
    .pixel_x(vid_pixel_x_d),
    .pixel_y(vid_pixel_y_d),
    .video_active(vid_active_d),
    .fractal_type(fractal_type),
    .palette_sel(palette_sel),
    .max_iter(max_iter),
    .fps_value(fps_value),
    .center_x(center_x),
    .center_y(center_y),
    .step(step),
    .auto_zoom_active(auto_zoom_active),
    .color_cycle_active(effective_color_cycle_enable),
    .color_cycle_mode(2'd0),  // no more 3-mode display
    .target_idx(az_target_idx),
    .in_r(disp_r),
    .in_g(disp_g),
    .in_b(disp_b),
    .out_r(overlay_r),
    .out_g(overlay_g),
    .out_b(overlay_b)
);

// ---- Overlay visibility timer state machine ----
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        overlay_timer <= OVERLAY_SHOW_TICKS;
        overlay_visible <= 1'b1;
        joystick_prev <= 16'd0;
        ps2_strobe_prev <= 1'b0;
    end else begin
        joystick_prev <= joystick;
        ps2_strobe_prev <= ps2_key[10];
        if (overlay_wakeup) begin
            overlay_timer <= OVERLAY_SHOW_TICKS;
            overlay_visible <= 1'b1;
        end else if (overlay_timer != 29'd0) begin
            overlay_timer <= overlay_timer - 29'd1;
        end else if (blank_text_enable) begin
            overlay_visible <= 1'b0;
        end else begin
            overlay_visible <= 1'b1;  // blank disabled = always visible
        end
    end
end

// VGA output
assign vga_r = overlay_r;
assign vga_g = overlay_g;
assign vga_b = overlay_b;

endmodule
