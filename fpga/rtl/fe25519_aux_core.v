`timescale 1ns/1ps
`include "ed25519_constants.vh"

module fe25519_aux_core (
    input  wire [2:0]   op,
    input  wire [254:0] a,
    input  wire [254:0] b,
    input  wire [255:0] raw_bytes,
    output reg  [254:0] result
);
    localparam [2:0] OP_ZERO       = 3'd0;
    localparam [2:0] OP_ADD_MOD_P  = 3'd1;
    localparam [2:0] OP_SUB_MOD_P  = 3'd2;
    localparam [2:0] OP_NEG_MOD_P  = 3'd3;
    localparam [2:0] OP_FROM_BYTES = 3'd4;
    localparam [2:0] OP_PASS_A     = 3'd5;

    wire [255:0] add_sum_ext;
    wire         add_needs_reduce;
    wire [255:0] add_reduced_ext;
    wire [255:0] sub_diff_ext;
    wire [255:0] sub_borrow_ext;
    wire [254:0] neg_result;
    wire         bytes_need_reduce;
    wire [255:0] bytes_reduced_ext;

    assign add_sum_ext = {1'b0, a} + {1'b0, b};
    assign add_needs_reduce =
        add_sum_ext[255] ||
        ((&add_sum_ext[254:5]) && (add_sum_ext[4:0] >= 5'd13));
    assign add_reduced_ext = {1'b0, a} + {1'b0, b} + 256'd19;

    assign sub_diff_ext = {1'b0, a} - {1'b0, b};
    assign sub_borrow_ext = {1'b0, a} - {1'b0, b} - 256'd19;

    assign neg_result = (~a) - 255'd18;

    assign bytes_need_reduce =
        (&raw_bytes[254:5]) && (raw_bytes[4:0] >= 5'd13);
    assign bytes_reduced_ext = {1'b0, raw_bytes[254:0]} + 256'd19;

    always @(*) begin
        result = `FE25519_ZERO;

        case (op)
            OP_ADD_MOD_P: begin
                result = add_needs_reduce ? add_reduced_ext[254:0] : add_sum_ext[254:0];
            end

            OP_SUB_MOD_P: begin
                result = sub_diff_ext[255] ? sub_borrow_ext[254:0] : sub_diff_ext[254:0];
            end

            OP_NEG_MOD_P: begin
                if (a == `FE25519_ZERO) begin
                    result = `FE25519_ZERO;
                end else begin
                    result = neg_result;
                end
            end

            OP_FROM_BYTES: begin
                result = bytes_need_reduce ? bytes_reduced_ext[254:0] : raw_bytes[254:0];
            end

            OP_PASS_A: begin
                result = a;
            end

            default: begin
                result = `FE25519_ZERO;
            end
        endcase
    end
endmodule
