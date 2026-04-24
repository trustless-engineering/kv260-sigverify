`timescale 1ns/1ps
`include "ed25519_constants.vh"

module fe25519_mul_wide_core (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [254:0] a,
    input  wire [254:0] b,
    output reg          busy,
    output reg          done,
    output reg  [254:0] result
);
    localparam integer LIMB_BITS = 51;
    localparam integer LIMBS = 5;
    localparam integer PRODUCT_LIMBS = 9;
    localparam [119:0] LIMB_MASK = (120'd1 << LIMB_BITS) - 120'd1;

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_MUL    = 3'd1;
    localparam [2:0] ST_MUL_FLUSH = 3'd2;
    localparam [2:0] ST_FOLD      = 3'd3;
    localparam [2:0] ST_CARRY     = 3'd4;
    localparam [2:0] ST_PACK      = 3'd5;
    localparam [2:0] ST_REDUCE    = 3'd6;
    localparam [2:0] ST_FINISH    = 3'd7;

    reg [2:0] state;

    reg [LIMB_BITS-1:0] a_limb [0:LIMBS-1];
    reg [LIMB_BITS-1:0] b_limb [0:LIMBS-1];
    reg [107:0] coeff [0:PRODUCT_LIMBS-1];
    reg [119:0] red [0:LIMBS-1];
    reg [3:0] diag_index;
    reg [3:0] product_diag_index;
    reg       product_valid;
    reg [101:0] product0_reg;
    reg [101:0] product1_reg;
    reg [101:0] product2_reg;
    reg [101:0] product3_reg;
    reg [101:0] product4_reg;
    reg [2:0] carry_index;
    reg [1:0] carry_pass;
    reg [254:0] candidate_reg;
    reg [255:0] candidate_minus_p_reg;
    reg         candidate_ge_p_reg;

    wire        lane0_valid;
    wire        lane1_valid;
    wire        lane2_valid;
    wire        lane3_valid;
    wire        lane4_valid;
    wire [2:0] lane0_j;
    wire [2:0] lane1_j;
    wire [2:0] lane2_j;
    wire [2:0] lane3_j;
    wire [2:0] lane4_j;
    wire [2:0] lane0_j_safe;
    wire [2:0] lane1_j_safe;
    wire [2:0] lane2_j_safe;
    wire [2:0] lane3_j_safe;
    wire [2:0] lane4_j_safe;
    wire [101:0] product0;
    wire [101:0] product1;
    wire [101:0] product2;
    wire [101:0] product3;
    wire [101:0] product4;
    wire [107:0] diag_sum_registered;
    wire [119:0] carry_value;
    wire [119:0] high_fold0;
    wire [119:0] high_fold1;
    wire [119:0] high_fold2;
    wire [119:0] high_fold3;

    wire [254:0] normalized_candidate;
    wire [255:0] candidate_ext;
    wire [255:0] field_p_ext;
    wire [255:0] candidate_minus_p;
    wire [254:0] reduced_result;

    assign lane0_valid = (diag_index <= 4'd4);
    assign lane1_valid = (diag_index >= 4'd1) && (diag_index <= 4'd5);
    assign lane2_valid = (diag_index >= 4'd2) && (diag_index <= 4'd6);
    assign lane3_valid = (diag_index >= 4'd3) && (diag_index <= 4'd7);
    assign lane4_valid = (diag_index >= 4'd4);
    assign lane0_j = diag_index[2:0];
    assign lane1_j = diag_index[2:0] - 3'd1;
    assign lane2_j = diag_index[2:0] - 3'd2;
    assign lane3_j = diag_index[2:0] - 3'd3;
    assign lane4_j = diag_index[2:0] - 3'd4;
    assign lane0_j_safe = lane0_valid ? lane0_j : 3'd0;
    assign lane1_j_safe = lane1_valid ? lane1_j : 3'd0;
    assign lane2_j_safe = lane2_valid ? lane2_j : 3'd0;
    assign lane3_j_safe = lane3_valid ? lane3_j : 3'd0;
    assign lane4_j_safe = lane4_valid ? lane4_j : 3'd0;

    assign product0 = lane0_valid ? (a_limb[0] * b_limb[lane0_j_safe]) : 102'd0;
    assign product1 = lane1_valid ? (a_limb[1] * b_limb[lane1_j_safe]) : 102'd0;
    assign product2 = lane2_valid ? (a_limb[2] * b_limb[lane2_j_safe]) : 102'd0;
    assign product3 = lane3_valid ? (a_limb[3] * b_limb[lane3_j_safe]) : 102'd0;
    assign product4 = lane4_valid ? (a_limb[4] * b_limb[lane4_j_safe]) : 102'd0;
    assign diag_sum_registered =
        {6'd0, product0_reg} +
        {6'd0, product1_reg} +
        {6'd0, product2_reg} +
        {6'd0, product3_reg} +
        {6'd0, product4_reg};

    assign carry_value = red[carry_index] >> LIMB_BITS;
    assign high_fold0 = ({12'd0, coeff[5]} << 4) + ({12'd0, coeff[5]} << 1) + {12'd0, coeff[5]};
    assign high_fold1 = ({12'd0, coeff[6]} << 4) + ({12'd0, coeff[6]} << 1) + {12'd0, coeff[6]};
    assign high_fold2 = ({12'd0, coeff[7]} << 4) + ({12'd0, coeff[7]} << 1) + {12'd0, coeff[7]};
    assign high_fold3 = ({12'd0, coeff[8]} << 4) + ({12'd0, coeff[8]} << 1) + {12'd0, coeff[8]};

    assign normalized_candidate = {
        red[4][50:0],
        red[3][50:0],
        red[2][50:0],
        red[1][50:0],
        red[0][50:0]
    };
    assign candidate_ext = {1'b0, candidate_reg};
    assign field_p_ext = {1'b0, `ED25519_FIELD_P};
    assign candidate_minus_p = candidate_ext - field_p_ext;
    assign reduced_result = candidate_ge_p_reg ? candidate_minus_p_reg[254:0] : candidate_reg;

    integer reset_index;
    integer init_index;

    always @(posedge clk) begin
        if (state == ST_MUL) begin
            product0_reg <= product0;
            product1_reg <= product1;
            product2_reg <= product2;
            product3_reg <= product3;
            product4_reg <= product4;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            for (reset_index = 0; reset_index < LIMBS; reset_index = reset_index + 1) begin
                a_limb[reset_index] <= {LIMB_BITS{1'b0}};
                b_limb[reset_index] <= {LIMB_BITS{1'b0}};
                red[reset_index] <= 120'd0;
            end
            for (reset_index = 0; reset_index < PRODUCT_LIMBS; reset_index = reset_index + 1) begin
                coeff[reset_index] <= 108'd0;
            end
            diag_index <= 4'd0;
            product_diag_index <= 4'd0;
            product_valid <= 1'b0;
            carry_index <= 3'd0;
            carry_pass <= 2'd0;
            candidate_reg <= `FE25519_ZERO;
            candidate_minus_p_reg <= 256'd0;
            candidate_ge_p_reg <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            result <= `FE25519_ZERO;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        for (init_index = 0; init_index < LIMBS; init_index = init_index + 1) begin
                            a_limb[init_index] <= a[init_index * LIMB_BITS +: LIMB_BITS];
                            b_limb[init_index] <= b[init_index * LIMB_BITS +: LIMB_BITS];
                            red[init_index] <= 120'd0;
                        end
                        for (init_index = 0; init_index < PRODUCT_LIMBS; init_index = init_index + 1) begin
                            coeff[init_index] <= 108'd0;
                        end
                        diag_index <= 4'd0;
                        product_diag_index <= 4'd0;
                        product_valid <= 1'b0;
                        carry_index <= 3'd0;
                        carry_pass <= 2'd0;
                        candidate_reg <= `FE25519_ZERO;
                        candidate_minus_p_reg <= 256'd0;
                        candidate_ge_p_reg <= 1'b0;
                        result <= `FE25519_ZERO;
                        busy <= 1'b1;
                        state <= ST_MUL;
                    end
                end

                ST_MUL: begin
                    if (product_valid) begin
                        coeff[product_diag_index] <= diag_sum_registered;
                    end
                    product_diag_index <= diag_index;
                    product_valid <= 1'b1;
                    if (diag_index == 4'd8) begin
                        state <= ST_MUL_FLUSH;
                    end else begin
                        diag_index <= diag_index + 4'd1;
                    end
                end

                ST_MUL_FLUSH: begin
                    if (product_valid) begin
                        coeff[product_diag_index] <= diag_sum_registered;
                    end
                    product_valid <= 1'b0;
                    state <= ST_FOLD;
                end

                ST_FOLD: begin
                    red[0] <= {12'd0, coeff[0]} + high_fold0;
                    red[1] <= {12'd0, coeff[1]} + high_fold1;
                    red[2] <= {12'd0, coeff[2]} + high_fold2;
                    red[3] <= {12'd0, coeff[3]} + high_fold3;
                    red[4] <= {12'd0, coeff[4]};
                    carry_index <= 3'd0;
                    carry_pass <= 2'd0;
                    state <= ST_CARRY;
                end

                ST_CARRY: begin
                    red[carry_index] <= red[carry_index] & LIMB_MASK;
                    if (carry_index == 3'd4) begin
                        red[0] <= red[0] + ((carry_value << 4) + (carry_value << 1) + carry_value);
                        carry_index <= 3'd0;
                        if (carry_pass == 2'd1) begin
                            state <= ST_PACK;
                        end else begin
                            carry_pass <= carry_pass + 2'd1;
                        end
                    end else begin
                        red[carry_index + 3'd1] <= red[carry_index + 3'd1] + carry_value;
                        carry_index <= carry_index + 3'd1;
                    end
                end

                ST_PACK: begin
                    candidate_reg <= normalized_candidate;
                    state <= ST_REDUCE;
                end

                ST_REDUCE: begin
                    candidate_minus_p_reg <= candidate_minus_p;
                    candidate_ge_p_reg <= (candidate_ext >= field_p_ext);
                    state <= ST_FINISH;
                end

                ST_FINISH: begin
                    result <= reduced_result;
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                    busy <= 1'b0;
                end
            endcase
        end
    end
endmodule
