//============================================================================
// Double-Buffered BRAM Framebuffer (v0.8)
//
// Two independent BRAM banks (A and B) for tear-free display:
//   - Render pipeline writes to the BACK buffer
//   - Video display reads from the FRONT buffer
//   - bank_sel swaps which is front/back (toggle during VBLANK only)
//
// bank_sel=0: front=A (display), back=B (render)
// bank_sel=1: front=B (display), back=A (render)
//
// 640x240 @ 9-bit: 153,600 entries per bank (sized for max resolution)
// ~184 M9K blocks per bank, ~368 total. In 320×240 mode only the lower
// half (76,800 entries) is addressed; upper half stays unused but the
// allocation is the same since BRAM cost is at the bank-config level.
//============================================================================

module framebuffer #(
    parameter DATA_WIDTH = 9,       // 8-bit iteration + 1-bit escaped
    parameter ADDR_WIDTH = 18       // ceil(log2(640*240)) = 18
)(
    // Dual-clock since the 100 MHz video-domain move (480P_DESIGN.md):
    // render writes in clk (clk_sys), display reads in rd_clk (clk_vid).
    // Banks strictly separate display/render, so cross-domain access to
    // the same cell only happens in single-buffer mode — where the
    // old/new nondeterminism was already accepted on one clock.
    input  wire                    clk,
    input  wire                    rd_clk,

    // Write port (render pipeline -> back buffer), clk domain
    input  wire                    wr_en,
    input  wire [ADDR_WIDTH-1:0]   wr_addr,
    input  wire [DATA_WIDTH-1:0]   wr_data,

    // Read port (video display <- front buffer), rd_clk domain
    input  wire [ADDR_WIDTH-1:0]   rd_addr,
    output wire [DATA_WIDTH-1:0]   rd_data,

    // Buffer swap control (toggle during VBLANK only!)
    // bank_sel is clk-domain; display_bank_sel must already be
    // synchronized into rd_clk by the caller.
    input  wire                    bank_sel,
    input  wire                    display_bank_sel
);

// Actual framebuffer depth. ADDR_WIDTH is still 18 so 640x240 addresses keep
// bit 17, but allocating a full 2^18 entries per bank exceeds DE10-Nano M10K.
localparam MEM_SIZE = 640 * 240; // 153600

// ---- Bank A ----
reg [DATA_WIDTH-1:0] mem_a [0:MEM_SIZE-1];
reg [DATA_WIDTH-1:0] rd_data_a;

// Write: only when bank_sel=1 (A is back buffer)
always @(posedge clk) begin
    if (wr_en & bank_sel)
        mem_a[wr_addr] <= wr_data;
end

// Read: always (for front buffer mux), video domain
always @(posedge rd_clk) begin
    rd_data_a <= mem_a[rd_addr];
end

// ---- Bank B ----
reg [DATA_WIDTH-1:0] mem_b [0:MEM_SIZE-1];
reg [DATA_WIDTH-1:0] rd_data_b;

// Write: only when bank_sel=0 (B is back buffer)
always @(posedge clk) begin
    if (wr_en & ~bank_sel)
        mem_b[wr_addr] <= wr_data;
end

// Read: always, video domain
always @(posedge rd_clk) begin
    rd_data_b <= mem_b[rd_addr];
end

// ---- Front buffer output mux ----
// bank_sel=0: front=A, bank_sel=1: front=B
assign rd_data = display_bank_sel ? rd_data_b : rd_data_a;

endmodule
