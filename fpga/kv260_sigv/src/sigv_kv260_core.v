module sigv_kv260_core #(
    parameter integer MESSAGE_ADDR_WIDTH = 12,
    parameter integer JOB_ADDR_WIDTH = 15,
    parameter integer VERIFY_ENGINE_COUNT = 2,
    parameter [15:0] MAX_MESSAGE_BYTES = 16'd4096,
    parameter [6:0] JOB_BYTES = 7'd96,
    parameter [31:0] MAX_JOB_COUNT = 32'd255,
    parameter [JOB_ADDR_WIDTH+7:0] JOB_RAM_DEPTH = 23'd32768
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,
    input  wire                          soft_reset,
    input  wire [15:0]                   message_length,
    input  wire [31:0]                   requested_job_count,
    input  wire [1:0]                    verify_mode,
    input  wire [7:0]                    dispatch_limit,
    input  wire [31:0]                   job_timeout_cycles,
    output reg                           busy,
    output reg                           done,
    output reg                           error,
    output reg                           result_valid,
    output reg  [7:0]                    error_code,
    output reg  [255:0]                  result_mask,
    output reg  [7:0]                    accepted_job_count,
    output reg  [7:0]                    current_job_index,
    output reg  [31:0]                   jobs_started,
    output reg  [31:0]                   jobs_completed,
    output reg  [31:0]                   jobs_dropped,
    output reg  [31:0]                   active_cycles,
    output reg  [31:0]                   last_job_cycles,
    output reg  [31:0]                   max_job_cycles,
    output reg  [31:0]                   last_batch_cycles,
    output reg  [31:0]                   batch_id,
    output reg  [31:0]                   snapshot_batch_id,
    output reg  [7:0]                    snapshot_accepted_job_count,
    output reg  [31:0]                   snapshot_jobs_completed,
    output reg  [31:0]                   snapshot_jobs_dropped,
    output reg                           snapshot_error,
    output reg                           snapshot_result_valid,
    output reg  [7:0]                    snapshot_error_code,

    output wire                          message_bram_en,
    output wire [MESSAGE_ADDR_WIDTH-3:0] message_bram_addr,
    input  wire [31:0]                   message_bram_dout,
    output wire                          job_bram_en,
    output wire [JOB_ADDR_WIDTH-3:0]     job_bram_addr,
    input  wire [31:0]                   job_bram_dout
);
    localparam [1:0] ST_IDLE             = 2'd0;
    localparam [1:0] ST_RUN              = 2'd1;

    localparam [1:0] LD_IDLE             = 2'd0;
    localparam [1:0] LD_REQ              = 2'd1;
    localparam [1:0] LD_WAIT             = 2'd2;
    localparam [1:0] LD_CAPTURE          = 2'd3;

    localparam [7:0] ERR_NONE            = 8'd0;
    localparam [7:0] ERR_MESSAGE_LEN     = 8'd1;
    localparam [7:0] ERR_JOB_COUNT       = 8'd2;
    localparam [7:0] ERR_JOB_RANGE       = 8'd3;
    localparam [7:0] ERR_JOB_TIMEOUT     = 8'd4;

    localparam [6:0] JOB_WORDS           = JOB_BYTES >> 2;
    localparam [4:0] JOB_LAST_WORD_INDEX = JOB_WORDS[4:0] - 5'd1;
    localparam       ENGINE1_ENABLED     = (VERIFY_ENGINE_COUNT > 1);

    reg [1:0] state;
    reg [1:0] loader_state;

    // Per-engine job slots
    reg [255:0] engine0_pubkey;
    reg [255:0] engine0_sig_r;
    reg [255:0] engine0_sig_s;
    reg [7:0]   engine0_job_index;
    reg         engine0_busy_slot;
    reg         engine0_start_pulse;
    reg [31:0]  engine0_cycles;

    reg [255:0] engine1_pubkey;
    reg [255:0] engine1_sig_r;
    reg [255:0] engine1_sig_s;
    reg [7:0]   engine1_job_index;
    reg         engine1_busy_slot;
    reg         engine1_start_pulse;
    reg [31:0]  engine1_cycles;

    // Shadow load slot (one in flight on the loader at a time)
    reg [255:0] shadow_pubkey;
    reg [255:0] shadow_sig_r;
    reg [255:0] shadow_sig_s;
    reg [7:0]   shadow_job_index;
    reg         shadow_valid;

    // Loader
    reg [4:0]                load_word_index;
    reg [JOB_ADDR_WIDTH-3:0] load_word_base;

    // Batch dispatch counters
    reg [7:0]                scheduled_job_count;
    reg [7:0]                batch_completed_count;   // jobs completed in CURRENT batch (not cumulative)
    reg [7:0]                next_load_job_index;     // next job index to begin loading
    reg [JOB_ADDR_WIDTH-3:0] next_load_word_base;     // job-bram word base for next load

    reg                      verifier_abort;

    wire                          engine0_msg_rd_en;
    wire [MESSAGE_ADDR_WIDTH-1:0] engine0_msg_rd_addr;
    wire                          engine0_done;
    wire                          engine0_verified;
    wire                          engine1_msg_rd_en;
    wire [MESSAGE_ADDR_WIDTH-1:0] engine1_msg_rd_addr;
    wire                          engine1_done;
    wire                          engine1_verified;

    wire                          engine0_grant;
    wire                          engine1_grant;
    wire                          engine0_msg_rd_ready;
    wire                          engine1_msg_rd_ready;
    wire [MESSAGE_ADDR_WIDTH-1:0] muxed_msg_addr;

    wire [7:0]                requested_job_count_u8;
    wire [7:0]                dispatch_limit_effective;
    wire [7:0]                dispatch_job_count;
    wire [7:0]                dispatch_dropped_count;
    wire [JOB_ADDR_WIDTH+7:0] dispatch_job_span;
    wire [JOB_ADDR_WIDTH-3:0] job_word_stride;
    wire [JOB_ADDR_WIDTH-3:0] job_word_addr;
    wire                      loader_busy;

    // Engine 0 wins arbitration on tie; engine 1 stalls in ST_MSG_REQ until granted.
    assign engine0_grant = engine0_msg_rd_en;
    assign engine1_grant = engine1_msg_rd_en && !engine0_msg_rd_en;
    assign engine0_msg_rd_ready = engine0_grant;
    assign engine1_msg_rd_ready = engine1_grant;
    assign muxed_msg_addr = engine0_grant ? engine0_msg_rd_addr : engine1_msg_rd_addr;

    assign message_bram_en   = engine0_grant || engine1_grant;
    assign message_bram_addr = muxed_msg_addr[MESSAGE_ADDR_WIDTH-1:2];

    assign loader_busy = (loader_state != LD_IDLE);
    assign job_word_addr = load_word_base + {{(JOB_ADDR_WIDTH-7){1'b0}}, load_word_index};
    assign job_bram_en = (loader_state == LD_REQ);
    assign job_bram_addr = job_word_addr;

    assign requested_job_count_u8 = requested_job_count[7:0];
    assign dispatch_limit_effective = (dispatch_limit == 8'd0) ? MAX_JOB_COUNT[7:0] : dispatch_limit;
    assign dispatch_job_count = (requested_job_count_u8 > dispatch_limit_effective) ? dispatch_limit_effective : requested_job_count_u8;
    assign dispatch_dropped_count = requested_job_count_u8 - dispatch_job_count;
    assign dispatch_job_span = dispatch_job_count * JOB_BYTES;
    assign job_word_stride = {{(JOB_ADDR_WIDTH-7){1'b0}}, JOB_BYTES[6:2]};

    ed25519_verify_engine #(
        .MESSAGE_ADDR_WIDTH(MESSAGE_ADDR_WIDTH)
    ) verify_engine0 (
        .clk            (clk),
        .rst_n          (rst_n),
        .abort          (verifier_abort),
        .start          (engine0_start_pulse),
        .message_length (message_length),
        .pubkey_raw     (engine0_pubkey),
        .signature_r_raw(engine0_sig_r),
        .signature_s_raw(engine0_sig_s),
        .verify_mode    (verify_mode),
        .msg_rd_en      (engine0_msg_rd_en),
        .msg_rd_addr    (engine0_msg_rd_addr),
        .msg_rd_ready   (engine0_msg_rd_ready),
        .msg_rd_data    (message_bram_dout),
        .busy           (),
        .done           (engine0_done),
        .verified       (engine0_verified)
    );

    generate
        if (ENGINE1_ENABLED) begin : gen_verify_engine1
            ed25519_verify_engine #(
                .MESSAGE_ADDR_WIDTH(MESSAGE_ADDR_WIDTH)
            ) verify_engine1 (
                .clk            (clk),
                .rst_n          (rst_n),
                .abort          (verifier_abort),
                .start          (engine1_start_pulse),
                .message_length (message_length),
                .pubkey_raw     (engine1_pubkey),
                .signature_r_raw(engine1_sig_r),
                .signature_s_raw(engine1_sig_s),
                .verify_mode    (verify_mode),
                .msg_rd_en      (engine1_msg_rd_en),
                .msg_rd_addr    (engine1_msg_rd_addr),
                .msg_rd_ready   (engine1_msg_rd_ready),
                .msg_rd_data    (message_bram_dout),
                .busy           (),
                .done           (engine1_done),
                .verified       (engine1_verified)
            );
        end else begin : gen_no_verify_engine1
            assign engine1_msg_rd_en = 1'b0;
            assign engine1_msg_rd_addr = {MESSAGE_ADDR_WIDTH{1'b0}};
            assign engine1_done = 1'b0;
            assign engine1_verified = 1'b0;
        end
    endgenerate

    task automatic clear_live_state;
        input clear_counters;
        begin
            state <= ST_IDLE;
            loader_state <= LD_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            result_valid <= 1'b0;
            error_code <= ERR_NONE;
            result_mask <= 256'd0;
            accepted_job_count <= 8'd0;
            current_job_index <= 8'd0;
            active_cycles <= 32'd0;
            engine0_pubkey <= 256'd0;
            engine0_sig_r <= 256'd0;
            engine0_sig_s <= 256'd0;
            engine0_job_index <= 8'd0;
            engine0_busy_slot <= 1'b0;
            engine0_start_pulse <= 1'b0;
            engine0_cycles <= 32'd0;
            engine1_pubkey <= 256'd0;
            engine1_sig_r <= 256'd0;
            engine1_sig_s <= 256'd0;
            engine1_job_index <= 8'd0;
            engine1_busy_slot <= 1'b0;
            engine1_start_pulse <= 1'b0;
            engine1_cycles <= 32'd0;
            shadow_pubkey <= 256'd0;
            shadow_sig_r <= 256'd0;
            shadow_sig_s <= 256'd0;
            shadow_job_index <= 8'd0;
            shadow_valid <= 1'b0;
            load_word_index <= 5'd0;
            load_word_base <= {(JOB_ADDR_WIDTH-2){1'b0}};
            scheduled_job_count <= 8'd0;
            batch_completed_count <= 8'd0;
            next_load_job_index <= 8'd0;
            next_load_word_base <= {(JOB_ADDR_WIDTH-2){1'b0}};
            if (clear_counters) begin
                jobs_started <= 32'd0;
                jobs_completed <= 32'd0;
                jobs_dropped <= 32'd0;
                last_job_cycles <= 32'd0;
                max_job_cycles <= 32'd0;
                last_batch_cycles <= 32'd0;
            end
        end
    endtask

    task automatic latch_snapshot;
        input [31:0] batch_id_in;
        input [7:0]  accepted_job_count_in;
        input [31:0] jobs_completed_in;
        input [31:0] jobs_dropped_in;
        input        final_error_in;
        input        final_result_valid_in;
        input [7:0]  final_error_code_in;
        begin
            snapshot_batch_id <= batch_id_in;
            snapshot_accepted_job_count <= accepted_job_count_in;
            snapshot_jobs_completed <= jobs_completed_in;
            snapshot_jobs_dropped <= jobs_dropped_in;
            snapshot_error <= final_error_in;
            snapshot_result_valid <= final_result_valid_in;
            snapshot_error_code <= final_error_code_in;
        end
    endtask

    task automatic kick_loader;
        input [JOB_ADDR_WIDTH-3:0] word_base;
        begin
            load_word_base <= word_base;
            load_word_index <= 5'd0;
            loader_state <= LD_REQ;
            shadow_pubkey <= 256'd0;
            shadow_sig_r  <= 256'd0;
            shadow_sig_s  <= 256'd0;
        end
    endtask

    task automatic finalize_batch;
        input        final_error_in;
        input        final_result_valid_in;
        input [7:0]  final_error_code_in;
        input [31:0] jobs_completed_in;
        begin
            busy <= 1'b0;
            done <= 1'b1;
            error <= final_error_in;
            result_valid <= final_result_valid_in;
            error_code <= final_error_code_in;
            last_batch_cycles <= active_cycles + 32'd1;
            active_cycles <= 32'd0;
            engine0_cycles <= 32'd0;
            engine1_cycles <= 32'd0;
            engine0_busy_slot <= 1'b0;
            engine1_busy_slot <= 1'b0;
            shadow_valid <= 1'b0;
            loader_state <= LD_IDLE;
            state <= ST_IDLE;
            latch_snapshot(
                batch_id,
                accepted_job_count,
                jobs_completed_in,
                jobs_dropped,
                final_error_in,
                final_result_valid_in,
                final_error_code_in
            );
        end
    endtask

    task automatic launch_batch;
        input clear_counters;
        reg [31:0] launch_id;
        begin
            launch_id = batch_id + 32'd1;
            batch_id <= launch_id;
            clear_live_state(clear_counters);
            if (message_length > MAX_MESSAGE_BYTES) begin
                done <= 1'b1;
                error <= 1'b1;
                error_code <= ERR_MESSAGE_LEN;
                latch_snapshot(launch_id, 8'd0, 32'd0, 32'd0, 1'b1, 1'b0, ERR_MESSAGE_LEN);
            end else if ((requested_job_count == 32'd0) || (requested_job_count > MAX_JOB_COUNT)) begin
                done <= 1'b1;
                error <= 1'b1;
                error_code <= ERR_JOB_COUNT;
                latch_snapshot(launch_id, 8'd0, 32'd0, 32'd0, 1'b1, 1'b0, ERR_JOB_COUNT);
            end else if (dispatch_job_span > JOB_RAM_DEPTH) begin
                done <= 1'b1;
                error <= 1'b1;
                error_code <= ERR_JOB_RANGE;
                latch_snapshot(launch_id, 8'd0, 32'd0, 32'd0, 1'b1, 1'b0, ERR_JOB_RANGE);
            end else begin
                busy <= 1'b1;
                accepted_job_count <= dispatch_job_count;
                current_job_index <= 8'd0;
                scheduled_job_count <= dispatch_job_count;
                next_load_job_index <= 8'd1;
                next_load_word_base <= job_word_stride;
                jobs_dropped <= clear_counters ? {24'd0, dispatch_dropped_count} : (jobs_dropped + {24'd0, dispatch_dropped_count});
                kick_loader({(JOB_ADDR_WIDTH-2){1'b0}});
                shadow_job_index <= 8'd0;
                state <= ST_RUN;
            end
        end
    endtask

    integer load_word_offset;
    reg engine0_done_evt;
    reg engine1_done_evt;
    reg [31:0] engine0_done_cycles;
    reg [31:0] engine1_done_cycles;
    reg [31:0] post_completed;            // cumulative jobs_completed for this cycle
    reg [7:0]  post_batch_completed;      // batch_completed_count for this cycle
    reg [31:0] new_max_job_cycles;
    reg engine0_freed_this_cycle;
    reg engine1_freed_this_cycle;
    reg dispatch_happened;
    reg engine0_timeout;
    reg engine1_timeout;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            verifier_abort <= 1'b0;
            batch_id <= 32'd0;
            snapshot_batch_id <= 32'd0;
            snapshot_accepted_job_count <= 8'd0;
            snapshot_jobs_completed <= 32'd0;
            snapshot_jobs_dropped <= 32'd0;
            snapshot_error <= 1'b0;
            snapshot_result_valid <= 1'b0;
            snapshot_error_code <= ERR_NONE;
            clear_live_state(1'b1);
        end else begin
            verifier_abort <= 1'b0;
            engine0_start_pulse <= 1'b0;
            engine1_start_pulse <= 1'b0;

            if (soft_reset && start) begin
                verifier_abort <= 1'b1;
                launch_batch(1'b1);
            end else if (soft_reset) begin
                verifier_abort <= 1'b1;
                clear_live_state(1'b1);
            end else begin
                if (busy) begin
                    active_cycles <= active_cycles + 32'd1;
                end
                if (engine0_busy_slot) begin
                    engine0_cycles <= engine0_cycles + 32'd1;
                end
                if (ENGINE1_ENABLED && engine1_busy_slot) begin
                    engine1_cycles <= engine1_cycles + 32'd1;
                end

                // ----- Loader -----
                case (loader_state)
                    LD_REQ: begin
                        loader_state <= LD_WAIT;
                    end

                    LD_WAIT: begin
                        loader_state <= LD_CAPTURE;
                    end

                    LD_CAPTURE: begin
                        load_word_offset = load_word_index * 32;
                        if (load_word_index < 5'd8) begin
                            shadow_pubkey[load_word_offset +: 32] <= job_bram_dout;
                        end else if (load_word_index < 5'd16) begin
                            shadow_sig_r[(load_word_offset - (8 * 32)) +: 32] <= job_bram_dout;
                        end else begin
                            shadow_sig_s[(load_word_offset - (16 * 32)) +: 32] <= job_bram_dout;
                        end

                        if (load_word_index == JOB_LAST_WORD_INDEX) begin
                            loader_state <= LD_IDLE;
                            shadow_valid <= 1'b1;
                        end else begin
                            load_word_index <= load_word_index + 5'd1;
                            loader_state <= LD_REQ;
                        end
                    end

                    default: begin
                    end
                endcase

                case (state)
                    ST_IDLE: begin
                        if (start) begin
                            launch_batch(1'b0);
                        end
                    end

                    ST_RUN: begin
                        // Engine completion handling
                        engine0_done_evt = engine0_busy_slot && engine0_done;
                        engine1_done_evt = ENGINE1_ENABLED && engine1_busy_slot && engine1_done;
                        engine0_done_cycles = engine0_cycles + 32'd1;
                        engine1_done_cycles = engine1_cycles + 32'd1;
                        engine0_freed_this_cycle = 1'b0;
                        engine1_freed_this_cycle = 1'b0;
                        post_completed = jobs_completed;
                        post_batch_completed = batch_completed_count;
                        new_max_job_cycles = max_job_cycles;

                        if (engine0_done_evt) begin
                            result_mask[engine0_job_index] <= engine0_verified;
                            engine0_busy_slot <= 1'b0;
                            engine0_cycles <= 32'd0;
                            engine0_freed_this_cycle = 1'b1;
                            post_completed = post_completed + 32'd1;
                            post_batch_completed = post_batch_completed + 8'd1;
                            last_job_cycles <= engine0_done_cycles;
                            if (engine0_done_cycles > new_max_job_cycles) begin
                                new_max_job_cycles = engine0_done_cycles;
                            end
                        end
                        if (engine1_done_evt) begin
                            result_mask[engine1_job_index] <= engine1_verified;
                            engine1_busy_slot <= 1'b0;
                            engine1_cycles <= 32'd0;
                            engine1_freed_this_cycle = 1'b1;
                            post_completed = post_completed + 32'd1;
                            post_batch_completed = post_batch_completed + 8'd1;
                            last_job_cycles <= engine1_done_cycles;
                            if (engine1_done_cycles > new_max_job_cycles) begin
                                new_max_job_cycles = engine1_done_cycles;
                            end
                        end
                        jobs_completed <= post_completed;
                        batch_completed_count <= post_batch_completed;
                        max_job_cycles <= new_max_job_cycles;

                        // Per-job watchdog (only when timeout is configured)
                        engine0_timeout = (job_timeout_cycles != 32'd0) &&
                                          engine0_busy_slot && !engine0_done_evt &&
                                          (engine0_done_cycles >= job_timeout_cycles);
                        engine1_timeout = ENGINE1_ENABLED &&
                                          (job_timeout_cycles != 32'd0) &&
                                          engine1_busy_slot && !engine1_done_evt &&
                                          (engine1_done_cycles >= job_timeout_cycles);
                        if (engine0_timeout || engine1_timeout) begin
                            if (engine0_timeout) begin
                                last_job_cycles <= engine0_done_cycles;
                                if (engine0_done_cycles > new_max_job_cycles) begin
                                    max_job_cycles <= engine0_done_cycles;
                                end
                            end else if (engine1_timeout) begin
                                last_job_cycles <= engine1_done_cycles;
                                if (engine1_done_cycles > new_max_job_cycles) begin
                                    max_job_cycles <= engine1_done_cycles;
                                end
                            end
                            verifier_abort <= 1'b1;
                            finalize_batch(1'b1, 1'b1, ERR_JOB_TIMEOUT, post_completed);
                        end else if (post_batch_completed == scheduled_job_count) begin
                            finalize_batch(1'b0, 1'b1, ERR_NONE, post_completed);
                        end else begin
                            // Hand shadow → free engine if both available
                            dispatch_happened = 1'b0;
                            if (shadow_valid) begin
                                if (!engine0_busy_slot || engine0_freed_this_cycle) begin
                                    engine0_pubkey <= shadow_pubkey;
                                    engine0_sig_r  <= shadow_sig_r;
                                    engine0_sig_s  <= shadow_sig_s;
                                    engine0_job_index <= shadow_job_index;
                                    engine0_busy_slot <= 1'b1;
                                    engine0_start_pulse <= 1'b1;
                                    engine0_cycles <= 32'd0;
                                    dispatch_happened = 1'b1;
                                end else if (ENGINE1_ENABLED && (!engine1_busy_slot || engine1_freed_this_cycle)) begin
                                    engine1_pubkey <= shadow_pubkey;
                                    engine1_sig_r  <= shadow_sig_r;
                                    engine1_sig_s  <= shadow_sig_s;
                                    engine1_job_index <= shadow_job_index;
                                    engine1_busy_slot <= 1'b1;
                                    engine1_start_pulse <= 1'b1;
                                    engine1_cycles <= 32'd0;
                                    dispatch_happened = 1'b1;
                                end

                                if (dispatch_happened) begin
                                    shadow_valid <= 1'b0;
                                    jobs_started <= jobs_started + 32'd1;
                                    current_job_index <= shadow_job_index;
                                    if (next_load_job_index < scheduled_job_count) begin
                                        kick_loader(next_load_word_base);
                                        shadow_job_index <= next_load_job_index;
                                        next_load_job_index <= next_load_job_index + 8'd1;
                                        next_load_word_base <= next_load_word_base + job_word_stride;
                                    end
                                end
                            end
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                    end
                endcase
            end
        end
    end
endmodule
