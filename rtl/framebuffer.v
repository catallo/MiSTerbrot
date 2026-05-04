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
// 640x240 @ 13-bit: 153,600 entries per bank (sized for max resolution)
// ~184 M9K blocks per bank, ~368 total. In 320×240 mode only the lower
// half (76,800 entries) is addressed; upper half stays unused but the
// allocation is the same since BRAM cost is at the bank-config level.
//============================================================================

module framebuffer #(
    parameter DATA_WIDTH = 13,      // 12-bit iteration + 1-bit escaped
    parameter ADDR_WIDTH = 18       // ceil(log2(640*240)) = 18
)(
    input  wire                    clk,

    // Write port (render pipeline -> back buffer)
    input  wire                    wr_en,
    input  wire [ADDR_WIDTH-1:0]   wr_addr,
    input  wire [DATA_WIDTH-1:0]   wr_data,

    // Read port (video display <- front buffer)
    input  wire [ADDR_WIDTH-1:0]   rd_addr,
    output wire [DATA_WIDTH-1:0]   rd_data,

    // Buffer swap control (toggle during VBLANK only!)
    input  wire                    bank_sel,
    input  wire                    display_bank_sel
);

// Round up to power of 2 (2^18 = 262144). Non-power-of-2 sizes can lead
// Quartus to stitch BRAMs with non-trivial address decoders that have
// aliasing across address-bit boundaries (specifically bit 17 at 131072).
// The unused upper half (153600..262143) is just empty BRAM — we never
// address it.
localparam MEM_SIZE = 1 << ADDR_WIDTH; // 262144 (2^18)

// ---- Bank A ----
reg [DATA_WIDTH-1:0] mem_a [0:MEM_SIZE-1];
reg [DATA_WIDTH-1:0] rd_data_a;

// Write: only when bank_sel=1 (A is back buffer)
always @(posedge clk) begin
    if (wr_en & bank_sel)
        mem_a[wr_addr] <= wr_data;
end

// Read: always (for front buffer mux)
always @(posedge clk) begin
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

// Read: always
always @(posedge clk) begin
    rd_data_b <= mem_b[rd_addr];
end

// ---- Front buffer output mux ----
// bank_sel=0: front=A, bank_sel=1: front=B
assign rd_data = display_bank_sel ? rd_data_b : rd_data_a;

endmodule
