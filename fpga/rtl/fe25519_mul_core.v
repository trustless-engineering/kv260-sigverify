`timescale 1ns/1ps
`include "ed25519_constants.vh"

module fe25519_mul_core (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [254:0] a,
    input  wire [254:0] b,
    output reg          busy,
    output reg          done,
    output reg  [254:0] result
);
    localparam integer LIMB_BITS = 15;
    localparam integer LIMBS = 17;
    localparam integer PRODUCT_LIMBS = 34;
    localparam integer MUL_LANES = 4;
    localparam [4:0] LAST_LIMB_INDEX = 5'd16;
    localparam [4:0] MUL_LANE_STEP = 5'd4;
    localparam [4:0] LAST_MUL_GROUP_START = 5'd13;
    localparam [5:0] LAST_PRODUCT_LIMB_INDEX = 6'd33;

    localparam [3:0] ST_IDLE   = 4'd0;
    localparam [3:0] ST_MUL    = 4'd1;
    localparam [3:0] ST_NORM   = 4'd2;
    localparam [3:0] ST_FOLD_1 = 4'd3;
    localparam [3:0] ST_FOLD_2 = 4'd4;
    localparam [3:0] ST_REDUCE = 4'd5;
    localparam [3:0] ST_FINISH = 4'd6;

    reg [3:0] state;

    reg [LIMB_BITS-1:0] a_limb [0:LIMBS-1];
    reg [LIMB_BITS-1:0] b_limb [0:LIMBS-1];
    reg [39:0] accum [0:PRODUCT_LIMBS-1];
    reg [4:0] mul_i;
    reg [4:0] mul_j;
    reg [5:0] norm_index;
    reg [509:0] product_reg;
    reg [259:0] fold1_reg;
    reg [255:0] fold2_reg;
    reg [255:0] fold2_minus_p_reg;
    reg         fold2_ge_p_reg;

    wire [4:0] mul_j_lane0;
    wire [4:0] mul_j_lane1;
    wire [4:0] mul_j_lane2;
    wire [4:0] mul_j_lane3;
    wire [4:0] mul_j_lane4;
    wire [4:0] mul_j_lane1_safe;
    wire [4:0] mul_j_lane2_safe;
    wire [4:0] mul_j_lane3_safe;
    wire [4:0] mul_j_lane4_safe;
    wire [5:0] mul_accum_index0;
    wire [5:0] mul_accum_index1;
    wire [5:0] mul_accum_index2;
    wire [5:0] mul_accum_index3;
    wire [5:0] mul_accum_index4;
    wire [29:0] limb_product0;
    wire [29:0] limb_product1;
    wire [29:0] limb_product2;
    wire [29:0] limb_product3;
    wire [29:0] limb_product4;
    wire [39:0] limb_product_ext0;
    wire [39:0] limb_product_ext1;
    wire [39:0] limb_product_ext2;
    wire [39:0] limb_product_ext3;
    wire [39:0] limb_product_ext4;
    wire        mul_lane1_valid;
    wire        mul_lane2_valid;
    wire        mul_lane3_valid;
    wire        mul_lane4_valid;
    wire        mul_row_done;
    wire [39:0] norm_carry_ext;

    wire [259:0] product_hi_ext;
    wire [259:0] product_lo_ext;
    wire [259:0] product_hi_times_19;
    wire [259:0] fold1_next;

    wire [255:0] fold1_lo_ext;
    wire [255:0] fold1_hi_ext;
    wire [255:0] fold1_hi_times_19;
    wire [255:0] combined_fold2_next;

    wire [255:0] field_p_ext;
    wire [255:0] fold2_minus_p;
    wire [254:0] reduced_result;

    assign mul_j_lane0 = mul_j;
    assign mul_j_lane1 = mul_j + 5'd1;
    assign mul_j_lane2 = mul_j + 5'd2;
    assign mul_j_lane3 = mul_j + 5'd3;
    assign mul_j_lane4 = mul_j + 5'd4;
    assign mul_lane1_valid = (MUL_LANES >= 2) && (mul_j < LAST_LIMB_INDEX);
    assign mul_lane2_valid = (MUL_LANES >= 3) && (mul_j <= (LAST_LIMB_INDEX - 5'd2));
    assign mul_lane3_valid = (MUL_LANES >= 4) && (mul_j <= (LAST_LIMB_INDEX - 5'd3));
    assign mul_lane4_valid = (MUL_LANES >= 5) && (mul_j <= (LAST_LIMB_INDEX - 5'd4));
    assign mul_j_lane1_safe = mul_lane1_valid ? mul_j_lane1 : 5'd0;
    assign mul_j_lane2_safe = mul_lane2_valid ? mul_j_lane2 : 5'd0;
    assign mul_j_lane3_safe = mul_lane3_valid ? mul_j_lane3 : 5'd0;
    assign mul_j_lane4_safe = mul_lane4_valid ? mul_j_lane4 : 5'd0;
    assign mul_accum_index0 = {1'b0, mul_i} + {1'b0, mul_j_lane0};
    assign mul_accum_index1 = {1'b0, mul_i} + {1'b0, mul_j_lane1_safe};
    assign mul_accum_index2 = {1'b0, mul_i} + {1'b0, mul_j_lane2_safe};
    assign mul_accum_index3 = {1'b0, mul_i} + {1'b0, mul_j_lane3_safe};
    assign mul_accum_index4 = {1'b0, mul_i} + {1'b0, mul_j_lane4_safe};
    assign limb_product0 = a_limb[mul_i] * b_limb[mul_j_lane0];
    assign limb_product1 = a_limb[mul_i] * b_limb[mul_j_lane1_safe];
    assign limb_product2 = a_limb[mul_i] * b_limb[mul_j_lane2_safe];
    assign limb_product3 = a_limb[mul_i] * b_limb[mul_j_lane3_safe];
    assign limb_product4 = a_limb[mul_i] * b_limb[mul_j_lane4_safe];
    assign limb_product_ext0 = {10'd0, limb_product0};
    assign limb_product_ext1 = {10'd0, limb_product1};
    assign limb_product_ext2 = {10'd0, limb_product2};
    assign limb_product_ext3 = {10'd0, limb_product3};
    assign limb_product_ext4 = {10'd0, limb_product4};
    assign mul_row_done = (mul_j >= LAST_MUL_GROUP_START);
    assign norm_carry_ext = accum[norm_index] >> LIMB_BITS;

    assign product_hi_ext = {5'd0, product_reg[509:255]};
    assign product_lo_ext = {5'd0, product_reg[254:0]};
    assign product_hi_times_19 =
        (product_hi_ext << 4) +
        (product_hi_ext << 1) +
        product_hi_ext;
    assign fold1_next = product_lo_ext + product_hi_times_19;

    assign fold1_lo_ext = {1'b0, fold1_reg[254:0]};
    assign fold1_hi_ext = {251'd0, fold1_reg[259:255]};
    assign fold1_hi_times_19 =
        (fold1_hi_ext << 4) +
        (fold1_hi_ext << 1) +
        fold1_hi_ext;
    assign combined_fold2_next = fold1_lo_ext + fold1_hi_times_19;

    assign field_p_ext = {1'b0, `ED25519_FIELD_P};
    assign fold2_minus_p = fold2_reg - field_p_ext;
    assign reduced_result = fold2_ge_p_reg ? fold2_minus_p_reg[254:0] : fold2_reg[254:0];

    integer reset_index;
    integer init_index;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            for (reset_index = 0; reset_index < LIMBS; reset_index = reset_index + 1) begin
                a_limb[reset_index] <= {LIMB_BITS{1'b0}};
                b_limb[reset_index] <= {LIMB_BITS{1'b0}};
            end
            for (reset_index = 0; reset_index < PRODUCT_LIMBS; reset_index = reset_index + 1) begin
                accum[reset_index] <= 40'd0;
            end
            mul_i <= 5'd0;
            mul_j <= 5'd0;
            norm_index <= 6'd0;
            product_reg <= 510'd0;
            fold1_reg <= 260'd0;
            fold2_reg <= 256'd0;
            fold2_minus_p_reg <= 256'd0;
            fold2_ge_p_reg <= 1'b0;
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
                        end
                        for (init_index = 0; init_index < PRODUCT_LIMBS; init_index = init_index + 1) begin
                            accum[init_index] <= 40'd0;
                        end
                        mul_i <= 5'd0;
                        mul_j <= 5'd0;
                        norm_index <= 6'd0;
                        product_reg <= 510'd0;
                        fold1_reg <= 260'd0;
                        fold2_reg <= 256'd0;
                        fold2_minus_p_reg <= 256'd0;
                        fold2_ge_p_reg <= 1'b0;
                        result <= `FE25519_ZERO;
                        busy <= 1'b1;
                        state <= ST_MUL;
                    end
                end

                ST_MUL: begin
                    accum[mul_accum_index0] <= accum[mul_accum_index0] + limb_product_ext0;
                    if (mul_lane1_valid) begin
                        accum[mul_accum_index1] <= accum[mul_accum_index1] + limb_product_ext1;
                    end
                    if (mul_lane2_valid) begin
                        accum[mul_accum_index2] <= accum[mul_accum_index2] + limb_product_ext2;
                    end
                    if (mul_lane3_valid) begin
                        accum[mul_accum_index3] <= accum[mul_accum_index3] + limb_product_ext3;
                    end
                    if (mul_lane4_valid) begin
                        accum[mul_accum_index4] <= accum[mul_accum_index4] + limb_product_ext4;
                    end

                    if (mul_row_done) begin
                        mul_j <= 5'd0;
                        if (mul_i == LAST_LIMB_INDEX) begin
                            norm_index <= 6'd0;
                            state <= ST_NORM;
                        end else begin
                            mul_i <= mul_i + 5'd1;
                        end
                    end else begin
                        mul_j <= mul_j + MUL_LANE_STEP;
                    end
                end

                ST_NORM: begin
                    product_reg[norm_index * LIMB_BITS +: LIMB_BITS] <= accum[norm_index][LIMB_BITS-1:0];
                    if (norm_index == LAST_PRODUCT_LIMB_INDEX) begin
                        state <= ST_FOLD_1;
                    end else begin
                        accum[norm_index + 6'd1] <= accum[norm_index + 6'd1] + norm_carry_ext;
                        norm_index <= norm_index + 6'd1;
                    end
                end

                ST_FOLD_1: begin
                    fold1_reg <= fold1_next;
                    state <= ST_FOLD_2;
                end

                ST_FOLD_2: begin
                    fold2_reg <= combined_fold2_next;
                    state <= ST_REDUCE;
                end

                ST_REDUCE: begin
                    fold2_minus_p_reg <= fold2_minus_p;
                    fold2_ge_p_reg <= (fold2_reg >= field_p_ext);
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
