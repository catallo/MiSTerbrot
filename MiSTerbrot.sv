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
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = core_rendering;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
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
	"O[9:4],Palette,Auto,Rainbow,Fire,Ocean,Electric,Neon,Pastel,Grayscale,Sunset,Aurora,Deep Sea,Candy,Matrix,Toxic,Frozen,Lava,Earth,Indigo,70s Retro,90s Rave,C64,Miami,Gold,Starlight,Nebula,Silver,Akihabara,Colorado,XTC,Psilocybin,HDR,THC,Barbie World,Skittles,Papagaio,Bubblegum,Synthwave,Pop Art,Tropical,Vaporwave,Acid,Morning Sun,Cloudy,Aurora Borealis,Cream,Palladium Silver,Complementary,Migraine Aura;",
	"O[10],Color Cycling,On,Off;",
	"O[14:12],Iterations,512,128,256,1024,2048;",
	"O[18],Buffer,Double,Single;",
	"O[19],Blank Text,On,Off;",
	"O[20],Always Show FPS,Off,On;",
	"O[21],Always Show POI/Palette,On,Off;",
	"O[17:15],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
		"-;",
	"-, Arrows/WASD/D-Pad: Pan;",
	"-, +/-/PgUp/PgDn: Zoom;",
	"-, P/B: Cycle Palette;",
	"-, I: Cycle Iterations;",
	"-, C: Color Cycling (On/Off);",
	"-, Space/Start: Auto-Zoom Toggle;",
	"-, N: Next POI;",
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
	.status_menumask(1'b0),
	.TIMESTAMP(TIMESTAMP),
	.ps2_key(ps2_key),
	.joystick_0(joystick_0)
);

wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset = RESET | status[0] | buttons[1];
wire rst_n = ~reset;

wire       ce_pix;
wire       core_hsync, core_vsync, core_hblank, core_vblank;
wire [7:0] core_r, core_g, core_b;
wire       core_rendering;

fractal_top #(
	.H_RES(320),
	.V_RES(240),
	.N_ITERATORS(8),
	.WIDTH(64),
	.FRAC_BITS(56)
) u_fractal_top (
	.clk(clk_sys),
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
	.vga_r(core_r),
	.vga_g(core_g),
	.vga_b(core_b),
	.rendering(core_rendering)
);

arcade_video #(.WIDTH(320), .DW(24)) u_arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in({core_r, core_g, core_b}),
	.HBlank(core_hblank),
	.VBlank(core_vblank),
	.HSync(core_hsync),
	.VSync(core_vsync),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.VGA_SL(VGA_SL),

	.fx(status[17:15]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

assign LED_USER = core_rendering;

endmodule
