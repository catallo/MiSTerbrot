//============================================================================
//
//  MiSTerbrot - EMU Module (v0.9.0)
//
//  320×240 native 240p output (15kHz). MiSTer ascaler handles upscaling.
//  BRAM double-buffered framebuffer. 8 DSP time-shared iterators.
//  12-bit iteration count (max 2048). 50 MHz system clock.
//
//  Based on Template_MiSTer by Sorgelig
//
//============================================================================

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,
	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,
	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,
	inout   [3:0] ADC_BUS,
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,
	input         OSD_STATUS
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
// DDRAM_* driven by fractal_top's fb_ddr3 (Track B 640x480i framebuffer)
assign DDRAM_CLK = clk_sys;
wire core_ddram_underrun;

wire core_f1;
wire core_interlaced;
wire core_480p;
wire core_new_vmode;

assign VGA_F1 = core_f1;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
// core_rendering is clk_sys; the framework consumes HDMI_FREEZE in the
// video clock domain — 2FF since the 100 MHz video move.
reg [1:0] freeze_sync;
always @(posedge clk_iter) freeze_sync <= {freeze_sync[0], core_rendering};
assign HDMI_FREEZE = freeze_sync[1];
assign HDMI_BLACKOUT = 0;
// 480i ships with the field flag suppressed (former Deinterlace=Off,
// now the only behavior): the scaler scales each field as an
// independent progressive half-picture — no combing, no bob shimmer.
assign HDMI_BOB_DEINT = 1'b0;
assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;
assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"MiSTerbrot;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[10:4],Palette,Auto,Rainbow,Fire,Ocean,Electric,Neon,Pastel,Oil Slick,Sunset,Aurora,Deep Sea,Candy,Matrix,Toxic,Frozen,Lava,Earth,Indigo,70s Retro,90s Rave,C64,Miami,Gold,Starlight,Nebula,Silver,Akihabara,Colorado,XTC,Psilocybin,HDR,THC,Barbie World,Skittles,Papagaio,Bubblegum,Synthwave,Pop Art,Tropical,Vaporwave,Acid,Morning Sun,Cloudy,Aurora Borealis,Cream,Palladium Silver,Complementary,Migraine Aura,Radioactive Glass,Cathedral Window,CRT Phosphor,Deep Sea Bioluminescence,Rust & Copper,Cyberpunk Noir,Bone & Ink,Solar Flare,Arctic Plasma,Toxic Candy,Old Terminal Amber,Alien Coral Reef,Black Hole Accretion,Infrared Camera,Pearlescent,Data Center Night,Lava Lamp,Monochrome Brutalist,Event Horizon,Psychedelic Circuit,Desert Mirage,Blood Moon,Quantum Foam,Hypernova Candy,Cyber Dragon,Laser Carnival,Glitch Prism,Plasma Rave,Game Boy,NES Castlevania,Embers,ZX Spectrum,CGA Magenta,Strobe Police,Halloween Strobe,Traffic Lights,SMPTE Color Bars,Pixel Sprite,Vintage Poster,Casino Slots,Neon Tubes,Stained Glass Hard,Disco Floor;",
	"O[14:12],Iterations,Auto,512,128,256,1024,2048;",
	"O[19],Blank Text,On,Off;",
	"O[20],Always Show FPS,Off,On;",
	"O[21],Always Show POI/Palette,On,Off;",
	"O[56:54],Resolution,320x240,640x240,320x480i,640x480i,640x480p,1920x1080;",
	"d0O[59],Gallery Live Render,On,Off;",
	"O[23],Overlay BG,Transparent,Dimmed;",
	"O[17:15],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	// Mariani-Silver was on the Optimisations page but had an intermittent
	// hang and the diagnosed fix breaks HDMI. MS dropped from the shipping
	// core. See docs/MR16_HANG_REPORT_V2.md and MR16_HANG_CHATGPT_PRO_V2.md.
	"O[18],Buffer,Double,Single;",
	"O[36],Limit Colours to,262K (Recommended),16.7M;",
	"O[26:25],P3 Bulb Precheck,Auto,On,Off;",
	"O[51],Periodicity Check,On,Off;",
	"P2,Color Cycling;",
	"P2O[24],Color Cycling,On,Off;",
	"P2O[40:37],Speed,9600 baud (Default),Teletype,300 baud,1200 baud,2400 baud,14.4k,28.8k,33.6k,ISDN,DSL,Fiber;",
	"P2O[42:41],Direction,Forward,Reverse,Ping-Pong;",
	"P2O[43],Blending,Smooth,Hard-step;",
	"P2O[45:44],Iter Band Mix,Off,Low Slow,Low Fast,Counter;",
	"P2O[47:46],Palette Transition,Crossfade,Instant,Slow Crossfade;",
	"P1,Attract Mode;",
	"D0P1O[29],Zoom In,On,Off;",
	"D0P1O[30],Zoom Out,On,Off;",
	"P1O[35:31],Wait on POI,10s,1s,2s,3s,4s,5s,6s,7s,8s,9s,15s,1 cycle,20s,30s,2 cycles,3 cycles,1m,4 cycles,5 cycles,2m,10 cycles,5m;",
	"D0P1O[48],Zoom Pacing,Cinematic,Constant;",
	"D0P1O[50:49],Zoom Speed,Normal,Slow,Fast,Very Fast;",
	"P1O[52],Randomize CC+Zoom Speed,On,Off;",
		"-;",
	"-, Arrows/WASD/D-Pad: Pan;",
	"-, +/-/PgUp/PgDn: Zoom;",
	"-, P/B: Cycle Palette;",
	"-, I: Cycle Iterations;",
	"-, C: Color Cycling (On/Off);",
	"-, Space/Start: Auto-Zoom Toggle;",
	"-, N: Next POI;",
	"-, M: Snap to next POI canonical zoom;",
	"-, B: Benchmark mode toggle;",
	"-, V: Benchmark next scene;",
	"-, S/A: Mariani-Silver On/Off;",
	"-, G/H: Overlay BG Dim On/Off;",
	"-, K/L: Overlay Blanking On/Off;",
	"-, Y/R/Home: Reset View;",
	"J1,Palette,Color Cycle,Iterations,Next POI,Zoom Out,Zoom In,Overlay,Auto-Zoom;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [15:0] joystick_0;
wire  [32:0] TIMESTAMP;
wire  [21:0] gamma_bus;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	// [0]: gallery selected — greys the zoom-related Attract rows
	// (inert in gallery, user spec) and enables the gallery-only
	// Live Render row.  Keyed to the SELECTION, not the post-grace
	// gallery_mode, so the OSD reflects the choice immediately.
	.status_menumask({15'd0, status[56:54] == 3'd5}),
	.new_vmode(core_new_vmode),
	.TIMESTAMP(TIMESTAMP),
	.ps2_key(ps2_key),
	.joystick_0(joystick_0)
);

wire clk_sys;
wire clk_iter;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_iter)
);

wire reset = RESET | status[0] | buttons[1];
wire rst_n = ~reset;

wire       ce_pix;
wire       core_hsync, core_vsync, core_hblank, core_vblank;
wire [7:0] core_r, core_g, core_b;
wire       core_rendering;
wire       av_ce;
wire [7:0] av_r, av_g, av_b;
wire       av_hs, av_vs, av_de;
wire [1:0] av_sl;

fractal_top #(
	.H_RES(320),
	.V_RES(240),
	.N_ITERATORS(24),	// 4 quads x 6 contexts/quad
	.WIDTH(64),
	.FRAC_BITS(56)
) u_fractal_top (
	.clk(clk_sys),
	.clk_iter(clk_iter),
	.clk_vid(clk_iter),
	.rst_n(rst_n),
	.joystick(joystick_0),
	.ps2_key(ps2_key),
	.status(status),
		.entropy_seed(TIMESTAMP),
	.ce_pix(ce_pix),
	.hsync(core_hsync),
	.vsync(core_vsync),
	.hblank(core_hblank),
	.vblank(core_vblank),
	.vga_f1(core_f1),
	.vga_interlaced(core_interlaced),
	.vga_mode_480p(core_480p),
	.new_vmode(core_new_vmode),
	.vga_r(core_r),
	.vga_g(core_g),
	.vga_b(core_b),
	.ddram_addr(DDRAM_ADDR),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_busy(DDRAM_BUSY),
	.ddram_dout(DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY),
	.ddram_rd(DDRAM_RD),
	.ddram_din(DDRAM_DIN),
	.ddram_be(DDRAM_BE),
	.ddram_we(DDRAM_WE),
	.ddram_underrun(core_ddram_underrun),
`ifdef MISTER_FB
	.gal_fb_en(FB_EN),
	.gal_fb_format(FB_FORMAT),
	.gal_fb_width(FB_WIDTH),
	.gal_fb_height(FB_HEIGHT),
	.gal_fb_base(FB_BASE),
	.gal_fb_stride(FB_STRIDE),
	.gal_fb_force_blank(FB_FORCE_BLANK),
`ifdef MISTER_FB_PALETTE
	.gal_pal_clk(FB_PAL_CLK),
	.gal_pal_addr(FB_PAL_ADDR),
	.gal_pal_dout(FB_PAL_DOUT),
	.gal_pal_wr(FB_PAL_WR),
`endif
`endif
	.rendering(core_rendering)
);

// WIDTH sized for max resolution (640) — line buffer absorbs unused space in 320 mode.
// Video runs in the 100 MHz domain since the 480p domain move (clk_iter output).
arcade_video #(.WIDTH(640), .DW(24)) u_arcade_video
(
	.clk_video(clk_iter),
	.ce_pix(ce_pix),
	.RGB_in({core_r, core_g, core_b}),
	.HBlank(core_hblank),
	.VBlank(core_vblank),
	.HSync(core_hsync),
	.VSync(core_vsync),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(av_ce),
	.VGA_R(av_r),
	.VGA_G(av_g),
	.VGA_B(av_b),
	.VGA_HS(av_hs),
	.VGA_VS(av_vs),
	.VGA_DE(av_de),
	.VGA_SL(av_sl),

	.fx((core_interlaced | core_480p) ? 3'b000 : status[17:15]),
	.forced_scandoubler(forced_scandoubler & ~core_interlaced & ~core_480p),
	.gamma_bus(gamma_bus)
);

// ---- 480i direct video path (PSX-style, 2026-07-09) ----
// video_mixer's freezer/sync_lock stage regenerates vsync edges on a
// learned period — that destroys the 262/263-line half-line interlace
// cadence, so the analog CRT cannot lock (HDMI survived because the
// ascal only needs the F1 toggle).  Interlaced video therefore bypasses
// arcade_video entirely, exactly like the PSX core: raw core timing to
// the framework, which handles polarity (sync_fix) itself.  The 240p
// paths keep the arcade_video chain (scandoubler fx etc.) unchanged.
reg        dvid_ce;
reg [7:0]  dvid_r, dvid_g, dvid_b;
reg        dvid_hs, dvid_vs, dvid_de;
reg        d_oldvid_ce;
always @(posedge clk_iter) begin
	d_oldvid_ce <= ce_pix;
	dvid_ce     <= ce_pix & ~d_oldvid_ce;
	if (ce_pix) begin
		dvid_r  <= core_r;
		dvid_g  <= core_g;
		dvid_b  <= core_b;
		dvid_hs <= core_hsync;
		dvid_vs <= core_vsync;
		dvid_de <= ~(core_hblank | core_vblank);
	end
end

// Direct path for interlaced AND 480p output: both bypass the
// arcade_video chain (the mixer's sync_lock broke the 480i half-line
// cadence on the CRT, and 480p is already 31 kHz — nothing to double).
wire direct_video = core_interlaced | core_480p;
assign CE_PIXEL = direct_video ? dvid_ce : av_ce;
assign VGA_R    = direct_video ? dvid_r  : av_r;
assign VGA_G    = direct_video ? dvid_g  : av_g;
assign VGA_B    = direct_video ? dvid_b  : av_b;
assign VGA_HS   = direct_video ? dvid_hs : av_hs;
assign VGA_VS   = direct_video ? dvid_vs : av_vs;
assign VGA_DE   = direct_video ? dvid_de : av_de;
assign VGA_SL   = direct_video ? 2'd0 : av_sl;

// User LED doubles as the DDR3 line-fetch underrun alarm during Track B
// bring-up: solid ON = sticky underrun (must never happen, 16x budget
// margin); otherwise it shows render activity as before.
assign LED_USER = core_ddram_underrun | core_rendering;

endmodule
