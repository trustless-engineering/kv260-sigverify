module sigv_byte_ram #(
    parameter integer ADDR_WIDTH = 11,
    parameter integer DEPTH = 2048
) (
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [7:0]            wr_data,
    input  wire                  rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [7:0]            rd_data
);
    (* ram_style = "block" *) reg [7:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
        if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end
endmodule
