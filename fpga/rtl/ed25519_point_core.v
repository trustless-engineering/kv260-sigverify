`include "ed25519_constants.vh"

module ed25519_point_core (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [1:0]   op,
    input  wire [255:0] encoded_point,
    input  wire [254:0] point_a_x,
    input  wire [254:0] point_a_y,
    input  wire [254:0] point_a_z,
    input  wire [254:0] point_a_t,
    input  wire [254:0] point_b_x,
    input  wire [254:0] point_b_y,
    input  wire [254:0] point_b_z,
    input  wire [254:0] point_b_t,
    output reg          busy,
    output reg          done,
    output reg          flag,
    output reg  [254:0] out_x,
    output reg  [254:0] out_y,
    output reg  [254:0] out_z,
    output reg  [254:0] out_t
);
    localparam [1:0] OP_DECOMPRESS = 2'd0;
    localparam [1:0] OP_ADD        = 2'd1;
    localparam [1:0] OP_DOUBLE     = 2'd2;

    localparam [5:0] STEP_IDLE       = 6'd0;
    localparam [5:0] STEP_ADD_0      = 6'd1;
    localparam [5:0] STEP_ADD_1      = 6'd2;
    localparam [5:0] STEP_ADD_2      = 6'd3;
    localparam [5:0] STEP_ADD_3      = 6'd4;
    localparam [5:0] STEP_ADD_4      = 6'd5;
    localparam [5:0] STEP_ADD_5      = 6'd6;
    localparam [5:0] STEP_ADD_6      = 6'd7;
    localparam [5:0] STEP_ADD_7      = 6'd8;
    localparam [5:0] STEP_ADD_8      = 6'd9;
    localparam [5:0] STEP_ADD_9      = 6'd10;
    localparam [5:0] STEP_ADD_10     = 6'd11;
    localparam [5:0] STEP_ADD_11     = 6'd12;
    localparam [5:0] STEP_ADD_12     = 6'd13;
    localparam [5:0] STEP_ADD_13     = 6'd14;
    localparam [5:0] STEP_ADD_14     = 6'd15;
    localparam [5:0] STEP_ADD_15     = 6'd16;
    localparam [5:0] STEP_DEC_1      = 6'd18;
    localparam [5:0] STEP_DEC_2      = 6'd19;
    localparam [5:0] STEP_DEC_3      = 6'd20;
    localparam [5:0] STEP_DEC_4      = 6'd21;
    localparam [5:0] STEP_DEC_5      = 6'd22;
    localparam [5:0] STEP_DEC_6      = 6'd23;
    localparam [5:0] STEP_DEC_7      = 6'd24;
    localparam [5:0] STEP_DEC_8      = 6'd25;
    localparam [5:0] STEP_DEC_9      = 6'd26;
    localparam [5:0] STEP_DEC_10     = 6'd27;
    localparam [5:0] STEP_DEC_11     = 6'd28;
    localparam [5:0] STEP_DEC_12     = 6'd29;
    localparam [5:0] STEP_DEC_13     = 6'd30;
    localparam [5:0] STEP_DEC_14     = 6'd31;
    localparam [5:0] STEP_POW_DISPATCH = 6'd32;
    localparam [5:0] STEP_POW_WAIT     = 6'd33;
    localparam [5:0] STEP_DONE       = 6'd34;
    localparam [5:0] STEP_DBL_0      = 6'd35;
    localparam [5:0] STEP_DBL_1      = 6'd36;
    localparam [5:0] STEP_DBL_2      = 6'd37;
    localparam [5:0] STEP_DBL_3      = 6'd38;
    localparam [5:0] STEP_DBL_4      = 6'd39;
    localparam [5:0] STEP_DBL_5      = 6'd40;
    localparam [5:0] STEP_DBL_6      = 6'd41;
    localparam [5:0] STEP_DBL_7      = 6'd42;
    localparam [5:0] STEP_DBL_8      = 6'd43;
    localparam [5:0] STEP_DBL_9      = 6'd44;
    localparam [5:0] STEP_DBL_10     = 6'd45;
    localparam [5:0] STEP_DBL_11     = 6'd46;
    localparam [5:0] STEP_DBL_12     = 6'd47;
    localparam [5:0] STEP_DBL_13     = 6'd48;
    localparam [5:0] STEP_DBL_14     = 6'd49;
    localparam [5:0] STEP_DBL_15     = 6'd50;
    localparam [5:0] STEP_ADD_1_MUL  = 6'd51;
    localparam [5:0] STEP_ADD_3_MUL  = 6'd52;
    localparam [5:0] STEP_DBL_4_MUL  = 6'd53;
    localparam [5:0] STEP_DEC_2_MUL  = 6'd54;
    localparam [5:0] STEP_DEC_13_MUL = 6'd55;
    localparam [5:0] STEP_ADD_1_AUX  = 6'd56;
    localparam [5:0] STEP_ADD_3_AUX  = 6'd57;
    localparam [5:0] STEP_DBL_4_AUX  = 6'd58;
    localparam [5:0] STEP_DEC_2_AUX  = 6'd59;
    localparam [5:0] STEP_DEC_13_AUX = 6'd60;
    localparam [5:0] STEP_DEC_11_COMPARE = 6'd61;
    localparam [5:0] STEP_DEC_11_BRANCH  = 6'd62;

    reg [5:0] step;
    reg [4:0] pow_phase;
    reg [6:0] pow_sq_remaining;
    reg       pow_dispatch_is_square;
    reg [1:0] pow_store_sel;
    reg       encoded_sign;

    reg [254:0] p_x;
    reg [254:0] p_y;
    reg [254:0] p_z;
    reg [254:0] p_t;
    reg [254:0] q_x;
    reg [254:0] q_y;
    reg [254:0] q_z;
    reg [254:0] q_t;
    reg         add_b_affine;

    reg [254:0] t0;
    reg [254:0] t1;
    reg [254:0] t2;
    reg [254:0] t3;
    reg [254:0] t4;
    reg [254:0] t5;
    reg [254:0] t6;
    reg [254:0] t7;
    reg [254:0] t8;
    reg [254:0] aux_stage;
    reg [254:0] aux_pipe_a;
    reg [254:0] aux_pipe_b;
    reg         aux_pipe_negate;
    reg         dec_match_pos;
    reg         dec_match_neg;
    reg [254:0] pow_input;
    reg [254:0] pow_value;
    reg [254:0] pow_t1;
    reg [254:0] pow_t2;

    reg         fe_start;
    reg [254:0] fe_a;
    reg [254:0] fe_b;
    wire        fe_done;
    wire [254:0] fe_result;
    reg [2:0]   aux_op_mux;
    reg [254:0] aux_a_mux;
    reg [254:0] aux_b_mux;
    wire [254:0] aux_result;
    wire [254:0] encoded_y;
    wire         encoded_y_need_reduce;
    wire [255:0] encoded_y_reduced_ext;
    wire [254:0] encoded_y_canonical;
    wire [255:0] aux_pipe_add_sum_ext;
    wire         aux_pipe_add_needs_reduce;
    wire [255:0] aux_pipe_add_reduced_ext;
    wire [254:0] aux_pipe_add_result;
    wire [255:0] aux_pipe_sub_diff_ext;
    wire [255:0] aux_pipe_sub_borrow_ext;
    wire [254:0] aux_pipe_sub_result;
    wire [254:0] aux_pipe_neg_result;
    wire [254:0] aux_pipe_sign_result;

    localparam [2:0] AUX_OP_ZERO       = 3'd0;
    localparam [2:0] AUX_OP_ADD_MOD_P  = 3'd1;
    localparam [2:0] AUX_OP_SUB_MOD_P  = 3'd2;
    localparam [2:0] AUX_OP_NEG_MOD_P  = 3'd3;
    localparam [2:0] AUX_OP_PASS_A     = 3'd5;

    assign encoded_y = encoded_point[254:0];
    assign encoded_y_need_reduce =
        (&encoded_y[254:5]) && (encoded_y[4:0] >= 5'd13);
    assign encoded_y_reduced_ext = {1'b0, encoded_y} + 256'd19;
    assign encoded_y_canonical =
        encoded_y_need_reduce ? encoded_y_reduced_ext[254:0] : encoded_y;

    assign aux_pipe_add_sum_ext = {1'b0, aux_pipe_a} + {1'b0, aux_pipe_b};
    assign aux_pipe_add_needs_reduce =
        aux_pipe_add_sum_ext[255] ||
        ((&aux_pipe_add_sum_ext[254:5]) && (aux_pipe_add_sum_ext[4:0] >= 5'd13));
    assign aux_pipe_add_reduced_ext = {1'b0, aux_pipe_a} + {1'b0, aux_pipe_b} + 256'd19;
    assign aux_pipe_add_result =
        aux_pipe_add_needs_reduce ? aux_pipe_add_reduced_ext[254:0] : aux_pipe_add_sum_ext[254:0];
    assign aux_pipe_sub_diff_ext = {1'b0, aux_pipe_a} - {1'b0, aux_pipe_b};
    assign aux_pipe_sub_borrow_ext = {1'b0, aux_pipe_a} - {1'b0, aux_pipe_b} - 256'd19;
    assign aux_pipe_sub_result =
        aux_pipe_sub_diff_ext[255] ? aux_pipe_sub_borrow_ext[254:0] : aux_pipe_sub_diff_ext[254:0];
    assign aux_pipe_neg_result =
        (aux_pipe_a == `FE25519_ZERO) ? `FE25519_ZERO : ((~aux_pipe_a) - 255'd18);
    assign aux_pipe_sign_result = aux_pipe_negate ? aux_pipe_neg_result : aux_pipe_a;

    fe25519_mul_wide_core fe_core (
        .clk   (clk),
        .rst_n (rst_n),
        .start (fe_start),
        .a     (fe_a),
        .b     (fe_b),
        .busy  (),
        .done  (fe_done),
        .result(fe_result)
    );

    localparam [1:0] POW_STORE_VALUE = 2'd0;
    localparam [1:0] POW_STORE_T1    = 2'd1;
    localparam [1:0] POW_STORE_T2    = 2'd2;

    localparam [4:0] POW_PHASE_INIT_0 = 5'd0;
    localparam [4:0] POW_PHASE_INIT_1 = 5'd1;
    localparam [4:0] POW_PHASE_INIT_2 = 5'd2;
    localparam [4:0] POW_PHASE_INIT_3 = 5'd3;
    localparam [4:0] POW_PHASE_INIT_4 = 5'd4;
    localparam [4:0] POW_PHASE_INIT_5 = 5'd5;
    localparam [4:0] POW_PHASE_INIT_6 = 5'd6;
    localparam [4:0] POW_PHASE_10     = 5'd7;
    localparam [4:0] POW_PHASE_20     = 5'd8;
    localparam [4:0] POW_PHASE_40     = 5'd9;
    localparam [4:0] POW_PHASE_50     = 5'd10;
    localparam [4:0] POW_PHASE_100    = 5'd11;
    localparam [4:0] POW_PHASE_200    = 5'd12;
    localparam [4:0] POW_PHASE_250    = 5'd13;
    localparam [4:0] POW_PHASE_FINAL  = 5'd14;

    always @(*) begin
        aux_op_mux = AUX_OP_ZERO;
        aux_a_mux = `FE25519_ZERO;
        aux_b_mux = `FE25519_ZERO;

        case (step)
            STEP_ADD_0: begin
                aux_op_mux = AUX_OP_SUB_MOD_P;
                aux_a_mux = p_y;
                aux_b_mux = p_x;
            end

            STEP_ADD_2: begin
                aux_op_mux = AUX_OP_ADD_MOD_P;
                aux_a_mux = p_y;
                aux_b_mux = p_x;
            end

            STEP_ADD_7: begin
                aux_op_mux = AUX_OP_SUB_MOD_P;
                aux_a_mux = t1;
                aux_b_mux = t0;
            end

            STEP_ADD_6: begin
                if (add_b_affine) begin
                    aux_op_mux = AUX_OP_SUB_MOD_P;
                    aux_a_mux = t1;
                    aux_b_mux = t0;
                end
            end

            STEP_ADD_8: begin
                aux_op_mux = AUX_OP_ADD_MOD_P;
                aux_a_mux = t3;
                aux_b_mux = t3;
            end

            STEP_ADD_9: begin
                aux_op_mux = AUX_OP_SUB_MOD_P;
                aux_a_mux = t8;
                aux_b_mux = t2;
            end

            STEP_ADD_10: begin
                aux_op_mux = AUX_OP_ADD_MOD_P;
                aux_a_mux = t8;
                aux_b_mux = t2;
            end

            STEP_ADD_11: begin
                aux_op_mux = AUX_OP_ADD_MOD_P;
                aux_a_mux = t1;
                aux_b_mux = t0;
            end

            STEP_DBL_3: begin
                aux_op_mux = AUX_OP_ADD_MOD_P;
                aux_a_mux = fe_result;
                aux_b_mux = fe_result;
            end

            STEP_DBL_6: begin
                aux_op_mux = AUX_OP_SUB_MOD_P;
                aux_a_mux = t3;
                aux_b_mux = t0;
            end

            STEP_DBL_7: begin
                aux_op_mux = AUX_OP_SUB_MOD_P;
                aux_a_mux = t4;
                aux_b_mux = t1;
            end

            STEP_DBL_8: begin
                aux_op_mux = AUX_OP_SUB_MOD_P;
                aux_a_mux = t1;
                aux_b_mux = t0;
            end

            STEP_DBL_9: begin
                aux_op_mux = AUX_OP_SUB_MOD_P;
                aux_a_mux = t4;
                aux_b_mux = t2;
            end

            STEP_DBL_10: begin
                aux_op_mux = AUX_OP_ADD_MOD_P;
                aux_a_mux = t0;
                aux_b_mux = t1;
            end

            STEP_DBL_11: begin
                aux_op_mux = AUX_OP_NEG_MOD_P;
                aux_a_mux = t6;
            end

            STEP_DEC_1: begin
                aux_op_mux = AUX_OP_SUB_MOD_P;
                aux_a_mux = fe_result;
                aux_b_mux = `FE25519_ONE;
            end

            STEP_DEC_11: begin
                aux_op_mux = AUX_OP_NEG_MOD_P;
                aux_a_mux = t2;
            end

            default: begin
            end
        endcase
    end

    fe25519_aux_core aux_core (
        .op       (aux_op_mux),
        .a        (aux_a_mux),
        .b        (aux_b_mux),
        .raw_bytes(256'd0),
        .result   (aux_result)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            flag <= 1'b0;
            out_x <= `FE25519_ZERO;
            out_y <= `FE25519_ZERO;
            out_z <= `FE25519_ZERO;
            out_t <= `FE25519_ZERO;
            step <= STEP_IDLE;
            pow_phase <= POW_PHASE_INIT_0;
            pow_sq_remaining <= 7'd0;
            pow_dispatch_is_square <= 1'b0;
            pow_store_sel <= POW_STORE_VALUE;
            encoded_sign <= 1'b0;
            p_x <= `FE25519_ZERO;
            p_y <= `FE25519_ZERO;
            p_z <= `FE25519_ZERO;
            p_t <= `FE25519_ZERO;
            q_x <= `FE25519_ZERO;
            q_y <= `FE25519_ZERO;
            q_z <= `FE25519_ZERO;
            q_t <= `FE25519_ZERO;
            add_b_affine <= 1'b0;
            t0 <= `FE25519_ZERO;
            t1 <= `FE25519_ZERO;
            t2 <= `FE25519_ZERO;
            t3 <= `FE25519_ZERO;
            t4 <= `FE25519_ZERO;
            t5 <= `FE25519_ZERO;
            t6 <= `FE25519_ZERO;
            t7 <= `FE25519_ZERO;
            t8 <= `FE25519_ZERO;
            aux_stage <= `FE25519_ZERO;
            aux_pipe_a <= `FE25519_ZERO;
            aux_pipe_b <= `FE25519_ZERO;
            aux_pipe_negate <= 1'b0;
            dec_match_pos <= 1'b0;
            dec_match_neg <= 1'b0;
            pow_input <= `FE25519_ZERO;
            pow_value <= `FE25519_ZERO;
            pow_t1 <= `FE25519_ZERO;
            pow_t2 <= `FE25519_ZERO;
            fe_start <= 1'b0;
            fe_a <= `FE25519_ZERO;
            fe_b <= `FE25519_ZERO;
        end else begin
            done <= 1'b0;
            fe_start <= 1'b0;
            fe_a <= `FE25519_ZERO;
            fe_b <= `FE25519_ZERO;

            if (!busy) begin
                if (start) begin
                    busy <= 1'b1;
                    flag <= 1'b0;
                    aux_pipe_negate <= 1'b0;
                    dec_match_pos <= 1'b0;
                    dec_match_neg <= 1'b0;
                    out_x <= `FE25519_ZERO;
                    out_y <= `FE25519_ZERO;
                    out_z <= `FE25519_ZERO;
                    out_t <= `FE25519_ZERO;
                    encoded_sign <= encoded_point[255];
                    p_x <= point_a_x;
                    p_y <= point_a_y;
                    p_z <= point_a_z;
                    p_t <= point_a_t;
                    q_x <= point_b_x;
                    q_y <= point_b_y;
                    q_z <= point_b_z;
                    q_t <= point_b_t;
                    add_b_affine <= (op == OP_ADD) && (point_b_z == `FE25519_ONE);
                    if (op == OP_ADD) begin
                        step <= STEP_ADD_0;
                    end else if (op == OP_DOUBLE) begin
                        step <= STEP_DBL_0;
                    end else if (op == OP_DECOMPRESS) begin
                        t0 <= encoded_y_canonical;
                        fe_a <= encoded_y_canonical;
                        fe_b <= encoded_y_canonical;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_1;
                    end else begin
                        step <= STEP_DONE;
                    end
                end
            end else begin
                case (step)
                    STEP_ADD_0: begin
                        t8 <= aux_result;
                        step <= STEP_ADD_1;
                    end
                    STEP_ADD_1: begin
                        aux_pipe_a <= q_y;
                        aux_pipe_b <= q_x;
                        step <= STEP_ADD_1_AUX;
                    end
                    STEP_ADD_1_AUX: begin
                        aux_stage <= aux_pipe_sub_result;
                        step <= STEP_ADD_1_MUL;
                    end
                    STEP_ADD_1_MUL: begin
                        fe_a <= t8;
                        fe_b <= aux_stage;
                        fe_start <= 1'b1;
                        step <= STEP_ADD_2;
                    end
                    STEP_ADD_2: if (fe_done) begin
                        t0 <= fe_result;
                        t8 <= aux_result;
                        step <= STEP_ADD_3;
                    end
                    STEP_ADD_3: begin
                        aux_pipe_a <= q_y;
                        aux_pipe_b <= q_x;
                        step <= STEP_ADD_3_AUX;
                    end
                    STEP_ADD_3_AUX: begin
                        aux_stage <= aux_pipe_add_result;
                        step <= STEP_ADD_3_MUL;
                    end
                    STEP_ADD_3_MUL: begin
                        fe_a <= t8;
                        fe_b <= aux_stage;
                        fe_start <= 1'b1;
                        step <= STEP_ADD_4;
                    end
                    STEP_ADD_4: if (fe_done) begin
                        t1 <= fe_result;
                        fe_a <= p_t;
                        fe_b <= q_t;
                        fe_start <= 1'b1;
                        step <= STEP_ADD_5;
                    end
                    STEP_ADD_5: if (fe_done) begin
                        fe_a <= fe_result;
                        fe_b <= `ED25519_D2;
                        fe_start <= 1'b1;
                        step <= STEP_ADD_6;
                    end
                    STEP_ADD_6: if (fe_done) begin
                        t2 <= fe_result;
                        if (add_b_affine) begin
                            t3 <= p_z;
                            t4 <= aux_result;
                            step <= STEP_ADD_8;
                        end else begin
                            fe_a <= p_z;
                            fe_b <= q_z;
                            fe_start <= 1'b1;
                            step <= STEP_ADD_7;
                        end
                    end
                    STEP_ADD_7: if (fe_done) begin
                        t3 <= fe_result;
                        t4 <= aux_result;
                        step <= STEP_ADD_8;
                    end
                    STEP_ADD_8: begin
                        t8 <= aux_result;
                        step <= STEP_ADD_9;
                    end
                    STEP_ADD_9: begin
                        t5 <= aux_result;
                        step <= STEP_ADD_10;
                    end
                    STEP_ADD_10: begin
                        t6 <= aux_result;
                        step <= STEP_ADD_11;
                    end
                    STEP_ADD_11: begin
                        t7 <= aux_result;
                        fe_a <= t4;
                        fe_b <= t5;
                        fe_start <= 1'b1;
                        step <= STEP_ADD_12;
                    end
                    STEP_ADD_12: if (fe_done) begin
                        out_x <= fe_result;
                        fe_a <= t6;
                        fe_b <= t7;
                        fe_start <= 1'b1;
                        step <= STEP_ADD_13;
                    end
                    STEP_ADD_13: if (fe_done) begin
                        out_y <= fe_result;
                        fe_a <= t4;
                        fe_b <= t7;
                        fe_start <= 1'b1;
                        step <= STEP_ADD_14;
                    end
                    STEP_ADD_14: if (fe_done) begin
                        out_t <= fe_result;
                        fe_a <= t5;
                        fe_b <= t6;
                        fe_start <= 1'b1;
                        step <= STEP_ADD_15;
                    end
                    STEP_ADD_15: if (fe_done) begin
                        out_z <= fe_result;
                        flag <= 1'b1;
                        step <= STEP_DONE;
                    end

                    STEP_DBL_0: begin
                        fe_a <= p_x;
                        fe_b <= p_x;
                        fe_start <= 1'b1;
                        step <= STEP_DBL_1;
                    end
                    STEP_DBL_1: if (fe_done) begin
                        t0 <= fe_result;
                        fe_a <= p_y;
                        fe_b <= p_y;
                        fe_start <= 1'b1;
                        step <= STEP_DBL_2;
                    end
                    STEP_DBL_2: if (fe_done) begin
                        t1 <= fe_result;
                        fe_a <= p_z;
                        fe_b <= p_z;
                        fe_start <= 1'b1;
                        step <= STEP_DBL_3;
                    end
                    STEP_DBL_3: if (fe_done) begin
                        t2 <= aux_result;
                        step <= STEP_DBL_4;
                    end
                    STEP_DBL_4: begin
                        aux_pipe_a <= p_x;
                        aux_pipe_b <= p_y;
                        step <= STEP_DBL_4_AUX;
                    end
                    STEP_DBL_4_AUX: begin
                        aux_stage <= aux_pipe_add_result;
                        step <= STEP_DBL_4_MUL;
                    end
                    STEP_DBL_4_MUL: begin
                        fe_a <= aux_stage;
                        fe_b <= aux_stage;
                        fe_start <= 1'b1;
                        step <= STEP_DBL_5;
                    end
                    STEP_DBL_5: if (fe_done) begin
                        t3 <= fe_result;
                        step <= STEP_DBL_6;
                    end
                    STEP_DBL_6: begin
                        t4 <= aux_result;
                        step <= STEP_DBL_7;
                    end
                    STEP_DBL_7: begin
                        t3 <= aux_result;
                        step <= STEP_DBL_8;
                    end
                    STEP_DBL_8: begin
                        t4 <= aux_result;
                        step <= STEP_DBL_9;
                    end
                    STEP_DBL_9: begin
                        t5 <= aux_result;
                        step <= STEP_DBL_10;
                    end
                    STEP_DBL_10: begin
                        t6 <= aux_result;
                        step <= STEP_DBL_11;
                    end
                    STEP_DBL_11: begin
                        t7 <= aux_result;
                        fe_a <= t3;
                        fe_b <= t5;
                        fe_start <= 1'b1;
                        step <= STEP_DBL_12;
                    end
                    STEP_DBL_12: if (fe_done) begin
                        out_x <= fe_result;
                        fe_a <= t4;
                        fe_b <= t7;
                        fe_start <= 1'b1;
                        step <= STEP_DBL_13;
                    end
                    STEP_DBL_13: if (fe_done) begin
                        out_y <= fe_result;
                        fe_a <= t3;
                        fe_b <= t7;
                        fe_start <= 1'b1;
                        step <= STEP_DBL_14;
                    end
                    STEP_DBL_14: if (fe_done) begin
                        out_t <= fe_result;
                        fe_a <= t5;
                        fe_b <= t4;
                        fe_start <= 1'b1;
                        step <= STEP_DBL_15;
                    end
                    STEP_DBL_15: if (fe_done) begin
                        out_z <= fe_result;
                        flag <= 1'b1;
                        step <= STEP_DONE;
                    end

                    STEP_DEC_1: if (fe_done) begin
                        t1 <= fe_result;
                        t2 <= aux_result;
                        fe_a <= fe_result;
                        fe_b <= `ED25519_D;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_2;
                    end
                    STEP_DEC_2: if (fe_done) begin
                        aux_pipe_a <= fe_result;
                        aux_pipe_b <= `FE25519_ONE;
                        step <= STEP_DEC_2_AUX;
                    end
                    STEP_DEC_2_AUX: begin
                        t3 <= aux_pipe_add_result;
                        aux_stage <= aux_pipe_add_result;
                        step <= STEP_DEC_2_MUL;
                    end
                    STEP_DEC_2_MUL: begin
                        fe_a <= aux_stage;
                        fe_b <= aux_stage;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_3;
                    end
                    STEP_DEC_3: if (fe_done) begin
                        t4 <= fe_result;
                        fe_a <= fe_result;
                        fe_b <= t3;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_4;
                    end
                    STEP_DEC_4: if (fe_done) begin
                        t5 <= fe_result;
                        fe_a <= t4;
                        fe_b <= t4;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_5;
                    end
                    STEP_DEC_5: if (fe_done) begin
                        t6 <= fe_result;
                        fe_a <= t2;
                        fe_b <= t5;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_6;
                    end
                    STEP_DEC_6: if (fe_done) begin
                        t7 <= fe_result;
                        fe_a <= fe_result;
                        fe_b <= t6;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_7;
                    end
                    STEP_DEC_7: if (fe_done) begin
                        pow_input <= fe_result;
                        pow_value <= `FE25519_ZERO;
                        pow_t1 <= `FE25519_ZERO;
                        pow_t2 <= `FE25519_ZERO;
                        pow_phase <= POW_PHASE_INIT_0;
                        pow_sq_remaining <= 7'd0;
                        step <= STEP_POW_DISPATCH;
                    end
                    STEP_DEC_8: begin
                        fe_a <= t7;
                        fe_b <= pow_value;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_9;
                    end
                    STEP_DEC_9: if (fe_done) begin
                        t8 <= fe_result;
                        fe_a <= fe_result;
                        fe_b <= fe_result;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_10;
                    end
                    STEP_DEC_10: if (fe_done) begin
                        fe_a <= t3;
                        fe_b <= fe_result;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_11;
                    end
                    STEP_DEC_11: if (fe_done) begin
                        t3 <= fe_result;
                        aux_stage <= aux_result;
                        step <= STEP_DEC_11_COMPARE;
                    end
                    STEP_DEC_11_COMPARE: begin
                        dec_match_pos <= (t3 == t2);
                        dec_match_neg <= (t3 == aux_stage);
                        step <= STEP_DEC_11_BRANCH;
                    end
                    STEP_DEC_11_BRANCH: begin
                        if (dec_match_pos) begin
                            flag <= 1'b1;
                            step <= STEP_DEC_13;
                        end else if (dec_match_neg) begin
                            fe_a <= t8;
                            fe_b <= `ED25519_SQRT_M1;
                            fe_start <= 1'b1;
                            step <= STEP_DEC_12;
                        end else begin
                            flag <= 1'b0;
                            out_x <= `FE25519_ZERO;
                            out_y <= `FE25519_ZERO;
                            out_z <= `FE25519_ZERO;
                            out_t <= `FE25519_ZERO;
                            step <= STEP_DONE;
                        end
                    end
                    STEP_DEC_12: if (fe_done) begin
                        t8 <= fe_result;
                        flag <= 1'b1;
                        step <= STEP_DEC_13;
                    end
                    STEP_DEC_13: begin
                        aux_pipe_negate <= (t8[0] != encoded_sign);
                        aux_pipe_a <= t8;
                        aux_pipe_b <= `FE25519_ZERO;
                        step <= STEP_DEC_13_AUX;
                    end
                    STEP_DEC_13_AUX: begin
                        t8 <= aux_pipe_sign_result;
                        aux_stage <= aux_pipe_sign_result;
                        step <= STEP_DEC_13_MUL;
                    end
                    STEP_DEC_13_MUL: begin
                        fe_a <= aux_stage;
                        fe_b <= t0;
                        fe_start <= 1'b1;
                        step <= STEP_DEC_14;
                    end
                    STEP_DEC_14: if (fe_done) begin
                        out_x <= t8;
                        out_y <= t0;
                        out_z <= `FE25519_ONE;
                        out_t <= fe_result;
                        step <= STEP_DONE;
                    end

                    STEP_POW_DISPATCH: begin
                        case (pow_phase)
                            POW_PHASE_INIT_0: begin
                                fe_a <= pow_input;
                                fe_b <= pow_input;
                                pow_dispatch_is_square <= 1'b0;
                                pow_store_sel <= POW_STORE_VALUE;
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_INIT_1: begin
                                fe_a <= pow_value;
                                fe_b <= pow_value;
                                pow_dispatch_is_square <= 1'b0;
                                pow_store_sel <= POW_STORE_T1;
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_INIT_2: begin
                                fe_a <= pow_t1;
                                fe_b <= pow_t1;
                                pow_dispatch_is_square <= 1'b0;
                                pow_store_sel <= POW_STORE_T1;
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_INIT_3: begin
                                fe_a <= pow_input;
                                fe_b <= pow_t1;
                                pow_dispatch_is_square <= 1'b0;
                                pow_store_sel <= POW_STORE_T1;
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_INIT_4: begin
                                fe_a <= pow_value;
                                fe_b <= pow_t1;
                                pow_dispatch_is_square <= 1'b0;
                                pow_store_sel <= POW_STORE_VALUE;
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_INIT_5: begin
                                fe_a <= pow_value;
                                fe_b <= pow_value;
                                pow_dispatch_is_square <= 1'b0;
                                pow_store_sel <= POW_STORE_VALUE;
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_INIT_6: begin
                                fe_a <= pow_t1;
                                fe_b <= pow_value;
                                pow_dispatch_is_square <= 1'b0;
                                pow_store_sel <= POW_STORE_VALUE;
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_10: begin
                                if (pow_sq_remaining != 7'd0) begin
                                    if (pow_sq_remaining == 7'd5) begin
                                        fe_a <= pow_value;
                                        fe_b <= pow_value;
                                    end else begin
                                        fe_a <= pow_t1;
                                        fe_b <= pow_t1;
                                    end
                                    pow_dispatch_is_square <= 1'b1;
                                    pow_store_sel <= POW_STORE_T1;
                                end else begin
                                    fe_a <= pow_t1;
                                    fe_b <= pow_value;
                                    pow_dispatch_is_square <= 1'b0;
                                    pow_store_sel <= POW_STORE_VALUE;
                                end
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_20: begin
                                if (pow_sq_remaining != 7'd0) begin
                                    if (pow_sq_remaining == 7'd10) begin
                                        fe_a <= pow_value;
                                        fe_b <= pow_value;
                                    end else begin
                                        fe_a <= pow_t1;
                                        fe_b <= pow_t1;
                                    end
                                    pow_dispatch_is_square <= 1'b1;
                                    pow_store_sel <= POW_STORE_T1;
                                end else begin
                                    fe_a <= pow_t1;
                                    fe_b <= pow_value;
                                    pow_dispatch_is_square <= 1'b0;
                                    pow_store_sel <= POW_STORE_T1;
                                end
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_40: begin
                                if (pow_sq_remaining != 7'd0) begin
                                    if (pow_sq_remaining == 7'd20) begin
                                        fe_a <= pow_t1;
                                        fe_b <= pow_t1;
                                    end else begin
                                        fe_a <= pow_t2;
                                        fe_b <= pow_t2;
                                    end
                                    pow_dispatch_is_square <= 1'b1;
                                    pow_store_sel <= POW_STORE_T2;
                                end else begin
                                    fe_a <= pow_t2;
                                    fe_b <= pow_t1;
                                    pow_dispatch_is_square <= 1'b0;
                                    pow_store_sel <= POW_STORE_T1;
                                end
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_50: begin
                                if (pow_sq_remaining != 7'd0) begin
                                    fe_a <= pow_t1;
                                    fe_b <= pow_t1;
                                    pow_dispatch_is_square <= 1'b1;
                                    pow_store_sel <= POW_STORE_T1;
                                end else begin
                                    fe_a <= pow_t1;
                                    fe_b <= pow_value;
                                    pow_dispatch_is_square <= 1'b0;
                                    pow_store_sel <= POW_STORE_VALUE;
                                end
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_100: begin
                                if (pow_sq_remaining != 7'd0) begin
                                    if (pow_sq_remaining == 7'd50) begin
                                        fe_a <= pow_value;
                                        fe_b <= pow_value;
                                    end else begin
                                        fe_a <= pow_t1;
                                        fe_b <= pow_t1;
                                    end
                                    pow_dispatch_is_square <= 1'b1;
                                    pow_store_sel <= POW_STORE_T1;
                                end else begin
                                    fe_a <= pow_t1;
                                    fe_b <= pow_value;
                                    pow_dispatch_is_square <= 1'b0;
                                    pow_store_sel <= POW_STORE_T1;
                                end
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_200: begin
                                if (pow_sq_remaining != 7'd0) begin
                                    if (pow_sq_remaining == 7'd100) begin
                                        fe_a <= pow_t1;
                                        fe_b <= pow_t1;
                                    end else begin
                                        fe_a <= pow_t2;
                                        fe_b <= pow_t2;
                                    end
                                    pow_dispatch_is_square <= 1'b1;
                                    pow_store_sel <= POW_STORE_T2;
                                end else begin
                                    fe_a <= pow_t2;
                                    fe_b <= pow_t1;
                                    pow_dispatch_is_square <= 1'b0;
                                    pow_store_sel <= POW_STORE_T1;
                                end
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_250: begin
                                if (pow_sq_remaining != 7'd0) begin
                                    fe_a <= pow_t1;
                                    fe_b <= pow_t1;
                                    pow_dispatch_is_square <= 1'b1;
                                    pow_store_sel <= POW_STORE_T1;
                                end else begin
                                    fe_a <= pow_t1;
                                    fe_b <= pow_value;
                                    pow_dispatch_is_square <= 1'b0;
                                    pow_store_sel <= POW_STORE_VALUE;
                                end
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            POW_PHASE_FINAL: begin
                                if (pow_sq_remaining != 7'd0) begin
                                    fe_a <= pow_value;
                                    fe_b <= pow_value;
                                    pow_dispatch_is_square <= 1'b1;
                                    pow_store_sel <= POW_STORE_VALUE;
                                end else begin
                                    fe_a <= pow_value;
                                    fe_b <= pow_input;
                                    pow_dispatch_is_square <= 1'b0;
                                    pow_store_sel <= POW_STORE_VALUE;
                                end
                                fe_start <= 1'b1;
                                step <= STEP_POW_WAIT;
                            end
                            default: begin
                                step <= STEP_DONE;
                            end
                        endcase
                    end
                    STEP_POW_WAIT: if (fe_done) begin
                        case (pow_store_sel)
                            POW_STORE_VALUE: begin
                                pow_value <= fe_result;
                            end
                            POW_STORE_T1: begin
                                pow_t1 <= fe_result;
                            end
                            default: begin
                                pow_t2 <= fe_result;
                            end
                        endcase

                        if (pow_dispatch_is_square) begin
                            if (pow_sq_remaining == 7'd1) begin
                                pow_sq_remaining <= 7'd0;
                            end else begin
                                pow_sq_remaining <= pow_sq_remaining - 7'd1;
                            end
                            step <= STEP_POW_DISPATCH;
                        end else begin
                            case (pow_phase)
                                POW_PHASE_INIT_0: begin
                                    pow_phase <= POW_PHASE_INIT_1;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_INIT_1: begin
                                    pow_phase <= POW_PHASE_INIT_2;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_INIT_2: begin
                                    pow_phase <= POW_PHASE_INIT_3;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_INIT_3: begin
                                    pow_phase <= POW_PHASE_INIT_4;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_INIT_4: begin
                                    pow_phase <= POW_PHASE_INIT_5;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_INIT_5: begin
                                    pow_phase <= POW_PHASE_INIT_6;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_INIT_6: begin
                                    pow_phase <= POW_PHASE_10;
                                    pow_sq_remaining <= 7'd5;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_10: begin
                                    pow_phase <= POW_PHASE_20;
                                    pow_sq_remaining <= 7'd10;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_20: begin
                                    pow_phase <= POW_PHASE_40;
                                    pow_sq_remaining <= 7'd20;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_40: begin
                                    pow_phase <= POW_PHASE_50;
                                    pow_sq_remaining <= 7'd10;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_50: begin
                                    pow_phase <= POW_PHASE_100;
                                    pow_sq_remaining <= 7'd50;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_100: begin
                                    pow_phase <= POW_PHASE_200;
                                    pow_sq_remaining <= 7'd100;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_200: begin
                                    pow_phase <= POW_PHASE_250;
                                    pow_sq_remaining <= 7'd50;
                                    step <= STEP_POW_DISPATCH;
                                end
                                POW_PHASE_250: begin
                                    pow_phase <= POW_PHASE_FINAL;
                                    pow_sq_remaining <= 7'd2;
                                    step <= STEP_POW_DISPATCH;
                                end
                                default: begin
                                    step <= STEP_DEC_8;
                                end
                            endcase
                        end
                    end

                    STEP_DONE: begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        step <= STEP_IDLE;
                    end

                    default: begin
                        busy <= 1'b0;
                        step <= STEP_IDLE;
                    end
                endcase
            end
        end
    end
endmodule
