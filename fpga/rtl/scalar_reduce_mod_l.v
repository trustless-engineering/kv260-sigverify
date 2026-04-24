`include "ed25519_constants.vh"

module scalar_reduce_mod_l (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [511:0] wide_in,
    output reg          busy,
    output reg          done,
    output reg  [255:0] scalar_out
);
    localparam [256:0] L_EXT = {1'b0, `ED25519_SCALAR_L};

    reg [511:0] shift_reg;
    reg [255:0] remainder;
    reg [8:0]   bit_index;
    integer byte_index;

    reg [256:0] candidate_1bit;
    reg [257:0] candidate_minus_l;
    reg [255:0] next_remainder;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            shift_reg <= 512'd0;
            remainder <= 256'd0;
            scalar_out <= 256'd0;
            bit_index <= 9'd0;
            candidate_1bit <= 257'd0;
            candidate_minus_l <= 258'd0;
            next_remainder <= 256'd0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                if (start) begin
                    busy <= 1'b1;
                    for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1) begin
                        shift_reg[(byte_index * 8) +: 8] <= wide_in[((63 - byte_index) * 8) +: 8];
                    end
                    remainder <= 256'd0;
                    scalar_out <= 256'd0;
                    bit_index <= 9'd511;
                    candidate_1bit <= 257'd0;
                    candidate_minus_l <= 258'd0;
                    next_remainder <= 256'd0;
                end
            end else begin
                candidate_1bit = {remainder, shift_reg[511]};
                candidate_minus_l = {1'b0, candidate_1bit} - {1'b0, L_EXT};
                if (!candidate_minus_l[257]) begin
                    next_remainder = candidate_minus_l[255:0];
                end else begin
                    next_remainder = candidate_1bit[255:0];
                end

                remainder <= next_remainder;
                shift_reg <= {shift_reg[510:0], 1'b0};

                if (bit_index == 9'd0) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    scalar_out <= next_remainder;
                end else begin
                    bit_index <= bit_index - 9'd1;
                end
            end
        end
    end
endmodule
