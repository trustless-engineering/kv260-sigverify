`include "ed25519_constants.vh"

module ed25519_verify_engine #(
    parameter integer MESSAGE_ADDR_WIDTH = 11
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          abort,
    input  wire                          start,
    input  wire [15:0]                   message_length,
    input  wire [255:0]                  pubkey_raw,
    input  wire [255:0]                  signature_r_raw,
    input  wire [255:0]                  signature_s_raw,
    input  wire [1:0]                    verify_mode,
    output wire                          msg_rd_en,
    output wire [MESSAGE_ADDR_WIDTH-1:0] msg_rd_addr,
    input  wire                          msg_rd_ready,
    input  wire [31:0]                   msg_rd_data,
    output reg                           busy,
    output reg                           done,
    output reg                           verified,
    output reg [31:0]                    perf_total_cycles,
    output reg [31:0]                    perf_control_cycles,
    output reg [31:0]                    perf_decode_cycles,
    output reg [31:0]                    perf_hash_cycles,
    output reg [31:0]                    perf_reduce_cycles,
    output reg [31:0]                    perf_precompute_cycles,
    output reg [31:0]                    perf_joint_cycles,
    output reg [31:0]                    perf_finalize_cycles
);
    localparam [1:0] VERIFY_MODE_STRICT      = 2'd0;
    localparam [1:0] VERIFY_MODE_AGAVE_ZEBRA = 2'd1;

    localparam [5:0] ST_IDLE                 = 6'd0;
    localparam [5:0] ST_DEC_A_START          = 6'd1;
    localparam [5:0] ST_DEC_A_WAIT           = 6'd2;
    localparam [5:0] ST_DEC_R_START          = 6'd3;
    localparam [5:0] ST_DEC_R_WAIT           = 6'd4;
    localparam [5:0] ST_HASH_START           = 6'd5;
    localparam [5:0] ST_HASH_WAIT            = 6'd6;
    localparam [5:0] ST_REDUCE_START         = 6'd7;
    localparam [5:0] ST_REDUCE_WAIT          = 6'd8;
    localparam [5:0] ST_RECODE_S_START           = 6'd9;
    localparam [5:0] ST_RECODE_S_WAIT            = 6'd10;
    localparam [5:0] ST_RECODE_K_START           = 6'd11;
    localparam [5:0] ST_RECODE_K_WAIT            = 6'd12;
    localparam [5:0] ST_ODD_A2_DBL_START         = 6'd13;
    localparam [5:0] ST_ODD_A2_DBL_WAIT          = 6'd14;
    localparam [5:0] ST_ODD_A3_ADD_START         = 6'd15;
    localparam [5:0] ST_ODD_A3_ADD_WAIT          = 6'd16;
    localparam [5:0] ST_ODD_A5_ADD_START         = 6'd17;
    localparam [5:0] ST_ODD_A5_ADD_WAIT          = 6'd18;
    localparam [5:0] ST_ODD_A7_ADD_START         = 6'd19;
    localparam [5:0] ST_ODD_A7_ADD_WAIT          = 6'd20;
    localparam [5:0] ST_JOINT_INIT               = 6'd21;
    localparam [5:0] ST_JOINT_DBL_START          = 6'd22;
    localparam [5:0] ST_JOINT_DBL_WAIT           = 6'd23;
    localparam [5:0] ST_JOINT_ADD_A_START        = 6'd24;
    localparam [5:0] ST_JOINT_ADD_A_WAIT         = 6'd25;
    localparam [5:0] ST_JOINT_ADD_B_START        = 6'd26;
    localparam [5:0] ST_JOINT_ADD_B_WAIT         = 6'd27;
    localparam [5:0] ST_JOINT_NEXT               = 6'd28;
    localparam [5:0] ST_FINAL_EQ_START           = 6'd29;
    localparam [5:0] ST_FINAL_EQ_WAIT            = 6'd30;
    localparam [5:0] ST_FINAL_COF_DBL_START      = 6'd31;
    localparam [5:0] ST_FINAL_COF_DBL_WAIT       = 6'd32;
    localparam [5:0] ST_DONE                     = 6'd33;

    localparam [2:0] PHASE_NONE                  = 3'd0;
    localparam [2:0] PHASE_CONTROL               = 3'd1;
    localparam [2:0] PHASE_DECODE                = 3'd2;
    localparam [2:0] PHASE_HASH                  = 3'd3;
    localparam [2:0] PHASE_REDUCE                = 3'd4;
    localparam [2:0] PHASE_PRECOMPUTE            = 3'd5;
    localparam [2:0] PHASE_JOINT                 = 3'd6;
    localparam [2:0] PHASE_FINALIZE              = 3'd7;

    reg [5:0] state;

    wire      point_done;
    wire      point_flag;
    wire [254:0] point_out_x;
    wire [254:0] point_out_y;
    wire [254:0] point_out_z;
    wire [254:0] point_out_t;

    wire      hash_done;
    wire      hash_error;
    wire [511:0] hash_digest;

    wire      reduce_done;
    wire [255:0] reduced_scalar;

    reg [255:0] pubkey_reg;
    reg [255:0] sig_r_reg;
    reg [255:0] s_scalar;
    reg [255:0] k_scalar;
    reg [1:0]   cofactor_double_count;
    reg [3:0]   base_window_value;

    reg [254:0] a_x;
    reg [254:0] a_y;
    reg [254:0] a_z;
    reg [254:0] a_t;
    reg [254:0] a2_x;
    reg [254:0] a2_y;
    reg [254:0] a2_z;
    reg [254:0] a2_t;
    reg [254:0] a3_x;
    reg [254:0] a3_y;
    reg [254:0] a3_z;
    reg [254:0] a3_t;
    reg [254:0] a5_x;
    reg [254:0] a5_y;
    reg [254:0] a5_z;
    reg [254:0] a5_t;
    reg [254:0] a7_x;
    reg [254:0] a7_y;
    reg [254:0] a7_z;
    reg [254:0] a7_t;
    reg [254:0] r_x;
    reg [254:0] r_y;
    reg [254:0] r_z;
    reg [254:0] r_t;
    reg [254:0] work_x;
    reg [254:0] work_y;
    reg [254:0] work_z;
    reg [254:0] work_t;
    reg [254:0] acc_x;
    reg [254:0] acc_y;
    reg [254:0] acc_z;
    reg [254:0] acc_t;
    reg [1023:0] s_wnaf_packed;
    reg [1023:0] k_wnaf_packed;
    reg [7:0]   joint_bit_index;
    reg [3:0]   current_s_digit;
    reg [3:0]   current_k_digit;

    reg         point_start_reg;
    reg [1:0]   point_op_reg;
    reg [255:0] point_encoded_reg;
    reg [254:0] point_a_x_reg;
    reg [254:0] point_a_y_reg;
    reg [254:0] point_a_z_reg;
    reg [254:0] point_a_t_reg;
    reg [254:0] point_b_x_reg;
    reg [254:0] point_b_y_reg;
    reg [254:0] point_b_z_reg;
    reg [254:0] point_b_t_reg;
    reg         hash_start_reg;
    reg         reduce_start_reg;
    reg         recode_start_reg;
    reg [255:0] recode_scalar_reg;

    wire verify_mode_agave_zebra;
    wire verify_mode_strict;
    wire [254:0] basepoint_x;
    wire [254:0] basepoint_y;
    wire [254:0] basepoint_z;
    wire [254:0] basepoint_t;
    wire         engine_rst_n;
    wire [2:0]   active_phase;
    wire [2:0]   counted_phase;
    wire [3:0]   next_s_digit;
    wire [3:0]   next_k_digit;
    wire         recode_done;
    wire         recode_digit_valid;
    wire [7:0]   recode_digit_index;
    wire [3:0]   recode_digit;
    wire [3:0]   current_s_abs;
    wire [3:0]   current_k_abs;
    wire         next_s_nonzero;
    wire         next_k_nonzero;
    wire         current_s_nonzero;
    wire         current_k_nonzero;
    wire         current_s_negative;
    wire         current_k_negative;
    reg [254:0] reg_sel_base_x;
    reg [254:0] reg_sel_base_y;
    reg [254:0] reg_sel_base_z;
    reg [254:0] reg_sel_base_t;
    reg [254:0] reg_sel_a_x;
    reg [254:0] reg_sel_a_y;
    reg [254:0] reg_sel_a_z;
    reg [254:0] reg_sel_a_t;
    reg  [2:0]   last_active_phase;

    assign engine_rst_n = rst_n && !abort;

    function [254:0] fe_neg_mod_p;
        input [254:0] a_in;
        begin
            if (a_in == `FE25519_ZERO) begin
                fe_neg_mod_p = `FE25519_ZERO;
            end else begin
                fe_neg_mod_p = `ED25519_FIELD_P - a_in;
            end
        end
    endfunction

    function [3:0] unpack_wnaf_digit;
        input [1023:0] packed_digits;
        input [7:0]    bit_index;
        begin
            unpack_wnaf_digit = packed_digits[{bit_index, 2'b00} +: 4];
        end
    endfunction

    function [3:0] digit_abs;
        input [3:0] digit_in;
        begin
            if (digit_in[3]) begin
                digit_abs = (~digit_in) + 4'd1;
            end else begin
                digit_abs = digit_in;
            end
        end
    endfunction

    function [255:0] canonicalize_encoded_point;
        input [255:0] encoded_in;
        reg [255:0] y_value;
        begin
            y_value = {1'b0, encoded_in[254:0]};
            if (y_value >= {1'b0, `ED25519_FIELD_P}) begin
                y_value = y_value - {1'b0, `ED25519_FIELD_P};
            end
            canonicalize_encoded_point = {encoded_in[255], y_value[254:0]};
        end
    endfunction

    function point_encoding_is_small_order;
        input [255:0] encoded_in;
        reg [255:0] canonical_encoded;
        begin
            canonical_encoded = canonicalize_encoded_point(encoded_in);
            case (canonical_encoded)
                256'h0000000000000000000000000000000000000000000000000000000000000001,
                256'h7a03ac9277fdc74ec6cc392cfa53202a0f67100d760b3cba4fd84d3d706a17c7,
                256'h8000000000000000000000000000000000000000000000000000000000000000,
                256'h05fc536d880238b13933c6d305acdfd5f098eff289f4c345b027b2c28f95e826,
                256'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffec,
                256'h85fc536d880238b13933c6d305acdfd5f098eff289f4c345b027b2c28f95e826,
                256'h0000000000000000000000000000000000000000000000000000000000000000,
                256'hfa03ac9277fdc74ec6cc392cfa53202a0f67100d760b3cba4fd84d3d706a17c7: begin
                    point_encoding_is_small_order = 1'b1;
                end
                default: begin
                    point_encoding_is_small_order = 1'b0;
                end
            endcase
        end
    endfunction

    function point_is_identity;
        input [254:0] x_in;
        input [254:0] y_in;
        input [254:0] z_in;
        input [254:0] t_in;
        begin
            point_is_identity =
                (x_in == `FE25519_ZERO) &&
                (t_in == `FE25519_ZERO) &&
                (y_in == z_in);
        end
    endfunction

    function [2:0] phase_for_state;
        input [5:0] state_in;
        begin
            case (state_in)
                ST_DEC_A_START,
                ST_DEC_A_WAIT,
                ST_DEC_R_START,
                ST_DEC_R_WAIT: begin
                    phase_for_state = PHASE_DECODE;
                end
                ST_HASH_START,
                ST_HASH_WAIT: begin
                    phase_for_state = PHASE_HASH;
                end
                ST_REDUCE_START,
                ST_REDUCE_WAIT,
                ST_RECODE_S_START,
                ST_RECODE_S_WAIT,
                ST_RECODE_K_START,
                ST_RECODE_K_WAIT: begin
                    phase_for_state = PHASE_REDUCE;
                end
                ST_ODD_A2_DBL_START,
                ST_ODD_A2_DBL_WAIT,
                ST_ODD_A3_ADD_START,
                ST_ODD_A3_ADD_WAIT,
                ST_ODD_A5_ADD_START,
                ST_ODD_A5_ADD_WAIT,
                ST_ODD_A7_ADD_START,
                ST_ODD_A7_ADD_WAIT: begin
                    phase_for_state = PHASE_PRECOMPUTE;
                end
                ST_JOINT_INIT,
                ST_JOINT_DBL_START,
                ST_JOINT_DBL_WAIT,
                ST_JOINT_ADD_A_START,
                ST_JOINT_ADD_A_WAIT,
                ST_JOINT_ADD_B_START,
                ST_JOINT_ADD_B_WAIT,
                ST_JOINT_NEXT: begin
                    phase_for_state = PHASE_JOINT;
                end
                ST_FINAL_EQ_START,
                ST_FINAL_EQ_WAIT,
                ST_FINAL_COF_DBL_START,
                ST_FINAL_COF_DBL_WAIT: begin
                    phase_for_state = PHASE_FINALIZE;
                end
                default: begin
                    phase_for_state = PHASE_NONE;
                end
            endcase
        end
    endfunction

    assign verify_mode_agave_zebra = (verify_mode == VERIFY_MODE_AGAVE_ZEBRA);
    assign verify_mode_strict = !verify_mode_agave_zebra;
    assign active_phase = phase_for_state(state);
    assign counted_phase = (state == ST_DONE) ?
        ((last_active_phase == PHASE_NONE) ? PHASE_CONTROL : last_active_phase) :
        active_phase;

    ed25519_point_core point_core (
        .clk          (clk),
        .rst_n        (engine_rst_n),
        .start        (point_start_reg),
        .op           (point_op_reg),
        .encoded_point(point_encoded_reg),
        .point_a_x    (point_a_x_reg),
        .point_a_y    (point_a_y_reg),
        .point_a_z    (point_a_z_reg),
        .point_a_t    (point_a_t_reg),
        .point_b_x    (point_b_x_reg),
        .point_b_y    (point_b_y_reg),
        .point_b_z    (point_b_z_reg),
        .point_b_t    (point_b_t_reg),
        .busy         (),
        .done         (point_done),
        .flag         (point_flag),
        .out_x        (point_out_x),
        .out_y        (point_out_y),
        .out_z        (point_out_z),
        .out_t        (point_out_t)
    );

    ed25519_basepoint_table basepoint_table (
        .selector(base_window_value),
        .valid   (),
        .point_x (basepoint_x),
        .point_y (basepoint_y),
        .point_z (basepoint_z),
        .point_t (basepoint_t)
    );

    assign next_s_digit = unpack_wnaf_digit(s_wnaf_packed, joint_bit_index);
    assign next_k_digit = unpack_wnaf_digit(k_wnaf_packed, joint_bit_index);
    assign current_s_abs = digit_abs(current_s_digit);
    assign current_k_abs = digit_abs(current_k_digit);
    assign next_s_nonzero = (next_s_digit != 4'd0);
    assign next_k_nonzero = (next_k_digit != 4'd0);
    assign current_s_nonzero = (current_s_digit != 4'd0);
    assign current_k_nonzero = (current_k_digit != 4'd0);
    assign current_s_negative = current_s_digit[3];
    assign current_k_negative = current_k_digit[3];

    wire [3:0]   next_k_abs;
    wire         next_k_negative;
    wire         next_s_negative_w;

    assign next_k_abs = digit_abs(next_k_digit);
    assign next_k_negative = next_k_digit[3];
    assign next_s_negative_w = next_s_digit[3];

    sha512_stream_engine #(
        .MESSAGE_ADDR_WIDTH(MESSAGE_ADDR_WIDTH)
    ) hash_engine (
        .clk           (clk),
        .rst_n         (engine_rst_n),
        .start         (hash_start_reg),
        .prefix0       (sig_r_reg),
        .prefix1       (pubkey_reg),
        .message_length(message_length),
        .msg_rd_en     (msg_rd_en),
        .msg_rd_addr   (msg_rd_addr),
        .msg_rd_ready  (msg_rd_ready),
        .msg_rd_data   (msg_rd_data),
        .busy          (),
        .done          (hash_done),
        .error         (hash_error),
        .digest_out    (hash_digest)
    );

    scalar_reduce_mod_l reduce_engine (
        .clk       (clk),
        .rst_n     (engine_rst_n),
        .start     (reduce_start_reg),
        .wide_in   (hash_digest),
        .busy      (),
        .done      (reduce_done),
        .scalar_out(reduced_scalar)
    );

    scalar_wnaf4_recode recode_engine (
        .clk         (clk),
        .rst_n       (engine_rst_n),
        .start       (recode_start_reg),
        .scalar_in   (recode_scalar_reg),
        .busy        (),
        .done        (recode_done),
        .digit_valid (recode_digit_valid),
        .digit_index (recode_digit_index),
        .digit       (recode_digit)
    );

    always @(posedge clk or negedge engine_rst_n) begin
        if (!engine_rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            verified <= 1'b0;
            perf_total_cycles <= 32'd0;
            perf_control_cycles <= 32'd0;
            perf_decode_cycles <= 32'd0;
            perf_hash_cycles <= 32'd0;
            perf_reduce_cycles <= 32'd0;
            perf_precompute_cycles <= 32'd0;
            perf_joint_cycles <= 32'd0;
            perf_finalize_cycles <= 32'd0;
            pubkey_reg <= 256'd0;
            sig_r_reg <= 256'd0;
            s_scalar <= 256'd0;
            k_scalar <= 256'd0;
            cofactor_double_count <= 2'd0;
            base_window_value <= 4'd0;
            a_x <= `FE25519_ZERO;
            a_y <= `FE25519_ZERO;
            a_z <= `FE25519_ZERO;
            a_t <= `FE25519_ZERO;
            a2_x <= `FE25519_ZERO;
            a2_y <= `FE25519_ZERO;
            a2_z <= `FE25519_ZERO;
            a2_t <= `FE25519_ZERO;
            a3_x <= `FE25519_ZERO;
            a3_y <= `FE25519_ZERO;
            a3_z <= `FE25519_ZERO;
            a3_t <= `FE25519_ZERO;
            a5_x <= `FE25519_ZERO;
            a5_y <= `FE25519_ZERO;
            a5_z <= `FE25519_ZERO;
            a5_t <= `FE25519_ZERO;
            a7_x <= `FE25519_ZERO;
            a7_y <= `FE25519_ZERO;
            a7_z <= `FE25519_ZERO;
            a7_t <= `FE25519_ZERO;
            r_x <= `FE25519_ZERO;
            r_y <= `FE25519_ZERO;
            r_z <= `FE25519_ZERO;
            r_t <= `FE25519_ZERO;
            work_x <= `FE25519_ZERO;
            work_y <= `FE25519_ZERO;
            work_z <= `FE25519_ZERO;
            work_t <= `FE25519_ZERO;
            acc_x <= `FE25519_ZERO;
            acc_y <= `FE25519_ONE;
            acc_z <= `FE25519_ONE;
            acc_t <= `FE25519_ZERO;
            s_wnaf_packed <= 1024'd0;
            k_wnaf_packed <= 1024'd0;
            joint_bit_index <= 8'd0;
            current_s_digit <= 4'd0;
            current_k_digit <= 4'd0;
            point_start_reg <= 1'b0;
            point_op_reg <= 2'd0;
            point_encoded_reg <= 256'd0;
            point_a_x_reg <= `FE25519_ZERO;
            point_a_y_reg <= `FE25519_ONE;
            point_a_z_reg <= `FE25519_ONE;
            point_a_t_reg <= `FE25519_ZERO;
            point_b_x_reg <= `FE25519_ZERO;
            point_b_y_reg <= `FE25519_ONE;
            point_b_z_reg <= `FE25519_ONE;
            point_b_t_reg <= `FE25519_ZERO;
            hash_start_reg <= 1'b0;
            reduce_start_reg <= 1'b0;
            recode_start_reg <= 1'b0;
            recode_scalar_reg <= 256'd0;
            last_active_phase <= PHASE_NONE;
            reg_sel_base_x <= `FE25519_ZERO;
            reg_sel_base_y <= `FE25519_ONE;
            reg_sel_base_z <= `FE25519_ONE;
            reg_sel_base_t <= `FE25519_ZERO;
            reg_sel_a_x <= `FE25519_ZERO;
            reg_sel_a_y <= `FE25519_ONE;
            reg_sel_a_z <= `FE25519_ONE;
            reg_sel_a_t <= `FE25519_ZERO;
        end else begin
            done <= 1'b0;
            point_start_reg <= 1'b0;
            hash_start_reg <= 1'b0;
            reduce_start_reg <= 1'b0;
            recode_start_reg <= 1'b0;

            if (state != ST_IDLE) begin
                perf_total_cycles <= perf_total_cycles + 32'd1;
                case (counted_phase)
                    PHASE_CONTROL: begin
                        perf_control_cycles <= perf_control_cycles + 32'd1;
                    end
                    PHASE_DECODE: begin
                        perf_decode_cycles <= perf_decode_cycles + 32'd1;
                    end
                    PHASE_HASH: begin
                        perf_hash_cycles <= perf_hash_cycles + 32'd1;
                    end
                    PHASE_REDUCE: begin
                        perf_reduce_cycles <= perf_reduce_cycles + 32'd1;
                    end
                    PHASE_PRECOMPUTE: begin
                        perf_precompute_cycles <= perf_precompute_cycles + 32'd1;
                    end
                    PHASE_JOINT: begin
                        perf_joint_cycles <= perf_joint_cycles + 32'd1;
                    end
                    PHASE_FINALIZE: begin
                        perf_finalize_cycles <= perf_finalize_cycles + 32'd1;
                    end
                    default: begin
                    end
                endcase
            end

            if (active_phase != PHASE_NONE) begin
                last_active_phase <= active_phase;
            end

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        busy <= 1'b1;
                        verified <= 1'b0;
                        perf_total_cycles <= 32'd0;
                        perf_control_cycles <= 32'd0;
                        perf_decode_cycles <= 32'd0;
                        perf_hash_cycles <= 32'd0;
                        perf_reduce_cycles <= 32'd0;
                        perf_precompute_cycles <= 32'd0;
                        perf_joint_cycles <= 32'd0;
                        perf_finalize_cycles <= 32'd0;
                        last_active_phase <= PHASE_NONE;
                        base_window_value <= 4'd0;
                        s_wnaf_packed <= 1024'd0;
                        k_wnaf_packed <= 1024'd0;
                        joint_bit_index <= 8'd0;
                        current_s_digit <= 4'd0;
                        current_k_digit <= 4'd0;
                        pubkey_reg <= pubkey_raw;
                        sig_r_reg <= signature_r_raw;
                        if (signature_s_raw >= `ED25519_SCALAR_L) begin
                            state <= ST_DONE;
                        end else if (verify_mode_strict &&
                                     (point_encoding_is_small_order(pubkey_raw) ||
                                      point_encoding_is_small_order(signature_r_raw))) begin
                            state <= ST_DONE;
                        end else begin
                            s_scalar <= signature_s_raw;
                            state <= ST_DEC_A_START;
                        end
                    end
                end

                ST_DEC_A_START: begin
                    point_op_reg <= 2'd0;
                    point_encoded_reg <= pubkey_reg;
                    point_start_reg <= 1'b1;
                    state <= ST_DEC_A_WAIT;
                end
                ST_DEC_A_WAIT: if (point_done) begin
                    if (!point_flag) begin
                        verified <= 1'b0;
                        state <= ST_DONE;
                    end else begin
                        a_x <= point_out_x;
                        a_y <= point_out_y;
                        a_z <= point_out_z;
                        a_t <= point_out_t;
                        state <= ST_DEC_R_START;
                    end
                end

                ST_DEC_R_START: begin
                    point_op_reg <= 2'd0;
                    point_encoded_reg <= sig_r_reg;
                    point_start_reg <= 1'b1;
                    state <= ST_DEC_R_WAIT;
                end
                ST_DEC_R_WAIT: if (point_done) begin
                    if (!point_flag) begin
                        verified <= 1'b0;
                        state <= ST_DONE;
                    end else begin
                        r_x <= point_out_x;
                        r_y <= point_out_y;
                        r_z <= point_out_z;
                        r_t <= point_out_t;
                        state <= ST_HASH_START;
                    end
                end

                ST_HASH_START: begin
                    hash_start_reg <= 1'b1;
                    state <= ST_HASH_WAIT;
                end
                ST_HASH_WAIT: if (hash_done) begin
                    if (hash_error) begin
                        verified <= 1'b0;
                        state <= ST_DONE;
                    end else begin
                        state <= ST_REDUCE_START;
                    end
                end

                ST_REDUCE_START: begin
                    reduce_start_reg <= 1'b1;
                    state <= ST_REDUCE_WAIT;
                end
                ST_REDUCE_WAIT: if (reduce_done) begin
                    k_scalar <= reduced_scalar;
                    state <= ST_RECODE_S_START;
                end

                ST_RECODE_S_START: begin
                    recode_scalar_reg <= s_scalar;
                    recode_start_reg <= 1'b1;
                    state <= ST_RECODE_S_WAIT;
                end
                ST_RECODE_S_WAIT: begin
                    if (recode_digit_valid) begin
                        s_wnaf_packed[{recode_digit_index, 2'b00} +: 4] <= recode_digit;
                    end
                    if (recode_done) begin
                        state <= ST_RECODE_K_START;
                    end
                end

                ST_RECODE_K_START: begin
                    recode_scalar_reg <= k_scalar;
                    recode_start_reg <= 1'b1;
                    state <= ST_RECODE_K_WAIT;
                end
                ST_RECODE_K_WAIT: begin
                    if (recode_digit_valid) begin
                        k_wnaf_packed[{recode_digit_index, 2'b00} +: 4] <= recode_digit;
                    end
                    if (recode_done) begin
                        state <= ST_ODD_A2_DBL_START;
                    end
                end

                ST_ODD_A2_DBL_START: begin
                    point_op_reg <= 2'd2;
                    point_a_x_reg <= a_x;
                    point_a_y_reg <= a_y;
                    point_a_z_reg <= a_z;
                    point_a_t_reg <= a_t;
                    point_b_x_reg <= a_x;
                    point_b_y_reg <= a_y;
                    point_b_z_reg <= a_z;
                    point_b_t_reg <= a_t;
                    point_start_reg <= 1'b1;
                    state <= ST_ODD_A2_DBL_WAIT;
                end
                ST_ODD_A2_DBL_WAIT: if (point_done) begin
                    a2_x <= point_out_x;
                    a2_y <= point_out_y;
                    a2_z <= point_out_z;
                    a2_t <= point_out_t;
                    state <= ST_ODD_A3_ADD_START;
                end

                ST_ODD_A3_ADD_START: begin
                    point_op_reg <= 2'd1;
                    point_a_x_reg <= a2_x;
                    point_a_y_reg <= a2_y;
                    point_a_z_reg <= a2_z;
                    point_a_t_reg <= a2_t;
                    point_b_x_reg <= a_x;
                    point_b_y_reg <= a_y;
                    point_b_z_reg <= a_z;
                    point_b_t_reg <= a_t;
                    point_start_reg <= 1'b1;
                    state <= ST_ODD_A3_ADD_WAIT;
                end
                ST_ODD_A3_ADD_WAIT: if (point_done) begin
                    a3_x <= point_out_x;
                    a3_y <= point_out_y;
                    a3_z <= point_out_z;
                    a3_t <= point_out_t;
                    state <= ST_ODD_A5_ADD_START;
                end

                ST_ODD_A5_ADD_START: begin
                    point_op_reg <= 2'd1;
                    point_a_x_reg <= a3_x;
                    point_a_y_reg <= a3_y;
                    point_a_z_reg <= a3_z;
                    point_a_t_reg <= a3_t;
                    point_b_x_reg <= a2_x;
                    point_b_y_reg <= a2_y;
                    point_b_z_reg <= a2_z;
                    point_b_t_reg <= a2_t;
                    point_start_reg <= 1'b1;
                    state <= ST_ODD_A5_ADD_WAIT;
                end
                ST_ODD_A5_ADD_WAIT: if (point_done) begin
                    a5_x <= point_out_x;
                    a5_y <= point_out_y;
                    a5_z <= point_out_z;
                    a5_t <= point_out_t;
                    state <= ST_ODD_A7_ADD_START;
                end

                ST_ODD_A7_ADD_START: begin
                    point_op_reg <= 2'd1;
                    point_a_x_reg <= a5_x;
                    point_a_y_reg <= a5_y;
                    point_a_z_reg <= a5_z;
                    point_a_t_reg <= a5_t;
                    point_b_x_reg <= a2_x;
                    point_b_y_reg <= a2_y;
                    point_b_z_reg <= a2_z;
                    point_b_t_reg <= a2_t;
                    point_start_reg <= 1'b1;
                    state <= ST_ODD_A7_ADD_WAIT;
                end
                ST_ODD_A7_ADD_WAIT: if (point_done) begin
                    a7_x <= point_out_x;
                    a7_y <= point_out_y;
                    a7_z <= point_out_z;
                    a7_t <= point_out_t;
                    state <= ST_JOINT_INIT;
                end

                ST_JOINT_INIT: begin
                    acc_x <= `FE25519_ZERO;
                    acc_y <= `FE25519_ONE;
                    acc_z <= `FE25519_ONE;
                    acc_t <= `FE25519_ZERO;
                    joint_bit_index <= 8'd255;
                    current_s_digit <= 4'd0;
                    current_k_digit <= 4'd0;
                    base_window_value <= 4'd0;
                    state <= ST_JOINT_DBL_START;
                end
                ST_JOINT_DBL_START: begin
                    point_op_reg <= 2'd2;
                    point_a_x_reg <= acc_x;
                    point_a_y_reg <= acc_y;
                    point_a_z_reg <= acc_z;
                    point_a_t_reg <= acc_t;
                    point_b_x_reg <= acc_x;
                    point_b_y_reg <= acc_y;
                    point_b_z_reg <= acc_z;
                    point_b_t_reg <= acc_t;
                    point_start_reg <= 1'b1;
                    base_window_value <= digit_abs(next_s_digit);
                    state <= ST_JOINT_DBL_WAIT;
                end
                ST_JOINT_DBL_WAIT: begin
                    reg_sel_base_x <= next_s_negative_w ? fe_neg_mod_p(basepoint_x) : basepoint_x;
                    reg_sel_base_y <= basepoint_y;
                    reg_sel_base_z <= basepoint_z;
                    reg_sel_base_t <= next_s_negative_w ? fe_neg_mod_p(basepoint_t) : basepoint_t;

                    reg_sel_a_x <=
                        (next_k_abs == 4'd1) ? (next_k_negative ? a_x : fe_neg_mod_p(a_x)) :
                        (next_k_abs == 4'd3) ? (next_k_negative ? a3_x : fe_neg_mod_p(a3_x)) :
                        (next_k_abs == 4'd5) ? (next_k_negative ? a5_x : fe_neg_mod_p(a5_x)) :
                        (next_k_abs == 4'd7) ? (next_k_negative ? a7_x : fe_neg_mod_p(a7_x)) :
                        `FE25519_ZERO;
                    reg_sel_a_y <=
                        (next_k_abs == 4'd1) ? a_y :
                        (next_k_abs == 4'd3) ? a3_y :
                        (next_k_abs == 4'd5) ? a5_y :
                        (next_k_abs == 4'd7) ? a7_y :
                        `FE25519_ONE;
                    reg_sel_a_z <=
                        (next_k_abs == 4'd1) ? a_z :
                        (next_k_abs == 4'd3) ? a3_z :
                        (next_k_abs == 4'd5) ? a5_z :
                        (next_k_abs == 4'd7) ? a7_z :
                        `FE25519_ONE;
                    reg_sel_a_t <=
                        (next_k_abs == 4'd1) ? (next_k_negative ? a_t : fe_neg_mod_p(a_t)) :
                        (next_k_abs == 4'd3) ? (next_k_negative ? a3_t : fe_neg_mod_p(a3_t)) :
                        (next_k_abs == 4'd5) ? (next_k_negative ? a5_t : fe_neg_mod_p(a5_t)) :
                        (next_k_abs == 4'd7) ? (next_k_negative ? a7_t : fe_neg_mod_p(a7_t)) :
                        `FE25519_ZERO;

                    if (point_done) begin
                        acc_x <= point_out_x;
                        acc_y <= point_out_y;
                        acc_z <= point_out_z;
                        acc_t <= point_out_t;
                        current_s_digit <= next_s_digit;
                        current_k_digit <= next_k_digit;
                        if (next_k_nonzero) begin
                            state <= ST_JOINT_ADD_A_START;
                        end else if (next_s_nonzero) begin
                            state <= ST_JOINT_ADD_B_START;
                        end else begin
                            state <= ST_JOINT_NEXT;
                        end
                    end
                end
                ST_JOINT_ADD_A_START: begin
                    point_op_reg <= 2'd1;
                    point_a_x_reg <= acc_x;
                    point_a_y_reg <= acc_y;
                    point_a_z_reg <= acc_z;
                    point_a_t_reg <= acc_t;
                    point_b_x_reg <= reg_sel_a_x;
                    point_b_y_reg <= reg_sel_a_y;
                    point_b_z_reg <= reg_sel_a_z;
                    point_b_t_reg <= reg_sel_a_t;
                    point_start_reg <= 1'b1;
                    state <= ST_JOINT_ADD_A_WAIT;
                end
                ST_JOINT_ADD_A_WAIT: if (point_done) begin
                    acc_x <= point_out_x;
                    acc_y <= point_out_y;
                    acc_z <= point_out_z;
                    acc_t <= point_out_t;
                    if (current_s_nonzero) begin
                        state <= ST_JOINT_ADD_B_START;
                    end else begin
                        state <= ST_JOINT_NEXT;
                    end
                end
                ST_JOINT_ADD_B_START: begin
                    point_op_reg <= 2'd1;
                    point_a_x_reg <= acc_x;
                    point_a_y_reg <= acc_y;
                    point_a_z_reg <= acc_z;
                    point_a_t_reg <= acc_t;
                    point_b_x_reg <= reg_sel_base_x;
                    point_b_y_reg <= reg_sel_base_y;
                    point_b_z_reg <= reg_sel_base_z;
                    point_b_t_reg <= reg_sel_base_t;
                    point_start_reg <= 1'b1;
                    state <= ST_JOINT_ADD_B_WAIT;
                end
                ST_JOINT_ADD_B_WAIT: if (point_done) begin
                    acc_x <= point_out_x;
                    acc_y <= point_out_y;
                    acc_z <= point_out_z;
                    acc_t <= point_out_t;
                    state <= ST_JOINT_NEXT;
                end
                ST_JOINT_NEXT: begin
                    if (joint_bit_index == 8'd0) begin
                        work_x <= acc_x;
                        work_y <= acc_y;
                        work_z <= acc_z;
                        work_t <= acc_t;
                        state <= ST_FINAL_EQ_START;
                    end else begin
                        joint_bit_index <= joint_bit_index - 8'd1;
                        state <= ST_JOINT_DBL_START;
                    end
                end

                ST_FINAL_EQ_START: begin
                    point_op_reg <= 2'd1;
                    point_a_x_reg <= work_x;
                    point_a_y_reg <= work_y;
                    point_a_z_reg <= work_z;
                    point_a_t_reg <= work_t;
                    point_b_x_reg <= fe_neg_mod_p(r_x);
                    point_b_y_reg <= r_y;
                    point_b_z_reg <= r_z;
                    point_b_t_reg <= fe_neg_mod_p(r_t);
                    point_start_reg <= 1'b1;
                    state <= ST_FINAL_EQ_WAIT;
                end
                ST_FINAL_EQ_WAIT: if (point_done) begin
                    if (verify_mode_agave_zebra) begin
                        work_x <= point_out_x;
                        work_y <= point_out_y;
                        work_z <= point_out_z;
                        work_t <= point_out_t;
                        cofactor_double_count <= 2'd0;
                        state <= ST_FINAL_COF_DBL_START;
                    end else begin
                        verified <= point_is_identity(point_out_x, point_out_y, point_out_z, point_out_t);
                        state <= ST_DONE;
                    end
                end

                ST_FINAL_COF_DBL_START: begin
                    point_op_reg <= 2'd2;
                    point_a_x_reg <= work_x;
                    point_a_y_reg <= work_y;
                    point_a_z_reg <= work_z;
                    point_a_t_reg <= work_t;
                    point_b_x_reg <= work_x;
                    point_b_y_reg <= work_y;
                    point_b_z_reg <= work_z;
                    point_b_t_reg <= work_t;
                    point_start_reg <= 1'b1;
                    state <= ST_FINAL_COF_DBL_WAIT;
                end
                ST_FINAL_COF_DBL_WAIT: if (point_done) begin
                    work_x <= point_out_x;
                    work_y <= point_out_y;
                    work_z <= point_out_z;
                    work_t <= point_out_t;
                    if (cofactor_double_count == 2'd2) begin
                        verified <= point_is_identity(point_out_x, point_out_y, point_out_z, point_out_t);
                        state <= ST_DONE;
                    end else begin
                        cofactor_double_count <= cofactor_double_count + 2'd1;
                        state <= ST_FINAL_COF_DBL_START;
                    end
                end

                ST_DONE: begin
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
