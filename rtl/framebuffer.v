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
// 320x240 @ 13-bit: 76,800 entries per bank
// ~92 M9K blocks per bank, ~184 total (of 553 available on 5CSEBA6U23I7)
//============================================================================

module framebuffer #(
    parameter DATA_WIDTH = 13,      // 12-bit iteration + 1-bit escaped
    parameter ADDR_WIDTH = 17       // ceil(log2(320*240)) = 17
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

localparam MEM_SIZE = 320 * 240; // 76800

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
