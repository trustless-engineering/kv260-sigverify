module sigv_kv260_bringup_core #(
    parameter integer MESSAGE_ADDR_WIDTH = 12,
    parameter integer JOB_ADDR_WIDTH = 15,
    parameter [15:0] MAX_MESSAGE_BYTES = 16'd4096,
    parameter [6:0] JOB_BYTES = 7'd96,
    parameter [31:0] MAX_JOB_COUNT = 32'd255,
    parameter [JOB_ADDR_WIDTH+7:0] JOB_RAM_DEPTH = 23'd32768,
    parameter [31:0] HEARTBEAT_INTERVAL_CYCLES = 32'd12500000,
    parameter [31:0] HEARTBEAT_PULSE_CYCLES = 32'd5000000
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
    output reg                           heartbeat_irq,
    output reg                           heartbeat_led,

    output wire                          message_bram_en,
    output wire [MESSAGE_ADDR_WIDTH-3:0] message_bram_addr,
    input  wire [31:0]                   message_bram_dout,
    output wire                          job_bram_en,
    output wire [JOB_ADDR_WIDTH-3:0]     job_bram_addr,
    input  wire [31:0]                   job_bram_dout
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_BUSY = 2'd1;

    localparam [7:0] ERR_NONE        = 8'd0;
    localparam [7:0] ERR_MESSAGE_LEN = 8'd1;
    localparam [7:0] ERR_JOB_COUNT   = 8'd2;
    localparam [7:0] ERR_JOB_RANGE   = 8'd3;

    reg [1:0] state;
    reg [7:0] accepted_next;
    reg [7:0] dropped_next;
    reg [JOB_ADDR_WIDTH+7:0] dispatch_job_span;
    reg [31:0] heartbeat_counter;
    reg [31:0] heartbeat_pulse_count;

    assign message_bram_en = 1'b0;
    assign message_bram_addr = {(MESSAGE_ADDR_WIDTH-2){1'b0}};
    assign job_bram_en = 1'b0;
    assign job_bram_addr = {(JOB_ADDR_WIDTH-2){1'b0}};

    initial begin
        heartbeat_irq = 1'b0;
        heartbeat_led = 1'b0;
        heartbeat_counter = 32'd0;
        heartbeat_pulse_count = 32'd0;
    end

    task automatic clear_live_state;
        input clear_counters;
        begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            result_valid <= 1'b0;
            error_code <= ERR_NONE;
            result_mask <= 256'd0;
            accepted_job_count <= 8'd0;
            current_job_index <= 8'd0;
            active_cycles <= 32'd0;
            last_job_cycles <= 32'd0;
            last_batch_cycles <= 32'd0;
            if (clear_counters) begin
                jobs_started <= 32'd0;
                jobs_completed <= 32'd0;
                jobs_dropped <= 32'd0;
                max_job_cycles <= 32'd0;
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

    task automatic launch_batch;
        input clear_counters;
        reg [31:0] launch_id;
        begin
            launch_id = batch_id + 32'd1;
            batch_id <= launch_id;
            clear_live_state(clear_counters);
            accepted_next = (dispatch_limit != 8'd0 && requested_job_count[7:0] > dispatch_limit) ?
                dispatch_limit : requested_job_count[7:0];
            dropped_next = requested_job_count[7:0] - accepted_next;
            dispatch_job_span = accepted_next * JOB_BYTES;

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
                accepted_job_count <= accepted_next;
                current_job_index <= accepted_next - 8'd1;
                jobs_dropped <= clear_counters ? {24'd0, dropped_next} : (jobs_dropped + {24'd0, dropped_next});
                state <= ST_BUSY;
            end
        end
    endtask

    always @(posedge clk) begin
        if (heartbeat_pulse_count != 32'd0) begin
            heartbeat_irq <= 1'b1;
            heartbeat_pulse_count <= heartbeat_pulse_count - 32'd1;
        end else begin
            heartbeat_irq <= 1'b0;
        end

        if (heartbeat_counter == (HEARTBEAT_INTERVAL_CYCLES - 1)) begin
            heartbeat_counter <= 32'd0;
            heartbeat_led <= ~heartbeat_led;
            heartbeat_pulse_count <= HEARTBEAT_PULSE_CYCLES - 32'd1;
            heartbeat_irq <= 1'b1;
        end else begin
            heartbeat_counter <= heartbeat_counter + 32'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            batch_id <= 32'd0;
            snapshot_batch_id <= 32'd0;
            snapshot_accepted_job_count <= 8'd0;
            snapshot_jobs_completed <= 32'd0;
            snapshot_jobs_dropped <= 32'd0;
            snapshot_error <= 1'b0;
            snapshot_result_valid <= 1'b0;
            snapshot_error_code <= ERR_NONE;
            accepted_next <= 8'd0;
            dropped_next <= 8'd0;
            dispatch_job_span <= {(JOB_ADDR_WIDTH+8){1'b0}};
            clear_live_state(1'b1);
        end else begin
            if (soft_reset && start) begin
                launch_batch(1'b1);
            end else if (soft_reset) begin
                clear_live_state(1'b1);
            end else begin
                if (busy) begin
                    active_cycles <= active_cycles + 32'd1;
                end

                case (state)
                    ST_IDLE: begin
                        if (start) begin
                            launch_batch(1'b0);
                        end
                    end

                    ST_BUSY: begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        result_valid <= 1'b1;
                        error <= 1'b0;
                        error_code <= ERR_NONE;
                        result_mask <= 256'd0;
                        if (accepted_job_count != 8'd0) begin
                            result_mask[0] <= 1'b1;
                        end
                        jobs_started <= jobs_started + {24'd0, accepted_job_count};
                        jobs_completed <= jobs_completed + {24'd0, accepted_job_count};
                        last_job_cycles <= 32'd1;
                        last_batch_cycles <= 32'd1;
                        max_job_cycles <= (max_job_cycles < 32'd1) ? 32'd1 : max_job_cycles;
                        latch_snapshot(
                            batch_id,
                            accepted_job_count,
                            jobs_completed + {24'd0, accepted_job_count},
                            jobs_dropped,
                            1'b0,
                            1'b1,
                            ERR_NONE
                        );
                        state <= ST_IDLE;
                    end

                    default: begin
                        state <= ST_IDLE;
                    end
                endcase
            end
        end
    end

    wire unused_inputs = ^{verify_mode, job_timeout_cycles, message_bram_dout, job_bram_dout};
endmodule
