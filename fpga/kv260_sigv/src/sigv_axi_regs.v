module sigv_axi_regs #(
    parameter integer AXI_ADDR_WIDTH = 8,
    parameter integer HW_BUILD_MODE = 0,
    parameter integer AUTO_IRQ_ENABLE = 0
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire                      s_axi_awvalid,
    output wire                      s_axi_awready,
    input  wire [31:0]               s_axi_wdata,
    input  wire [3:0]                s_axi_wstrb,
    input  wire                      s_axi_wvalid,
    output wire                      s_axi_wready,
    output reg  [1:0]                s_axi_bresp,
    output reg                       s_axi_bvalid,
    input  wire                      s_axi_bready,
    input  wire [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire                      s_axi_arvalid,
    output wire                      s_axi_arready,
    output reg  [31:0]               s_axi_rdata,
    output reg  [1:0]                s_axi_rresp,
    output reg                       s_axi_rvalid,
    input  wire                      s_axi_rready,

    output reg                       start_pulse,
    output reg                       soft_reset_pulse,
    output reg  [15:0]               message_length,
    output reg  [31:0]               requested_job_count,
    output reg  [1:0]                verify_mode,
    output reg  [7:0]                dispatch_limit,
    output reg  [31:0]               led_control,
    output reg  [31:0]               job_timeout_cycles,
    input  wire                      autonomous_irq,
    output wire                      irq,

    input  wire                      busy,
    input  wire                      done,
    input  wire                      error,
    input  wire                      result_valid,
    input  wire [7:0]                error_code,
    input  wire [255:0]              result_mask,
    input  wire [7:0]                accepted_job_count,
    input  wire [7:0]                current_job_index,
    input  wire [31:0]               jobs_started,
    input  wire [31:0]               jobs_completed,
    input  wire [31:0]               jobs_dropped,
    input  wire [31:0]               active_cycles,
    input  wire [31:0]               last_job_cycles,
    input  wire [31:0]               max_job_cycles,
    input  wire [31:0]               last_batch_cycles,
    input  wire [31:0]               batch_id,
    input  wire [31:0]               snapshot_batch_id,
    input  wire [7:0]                snapshot_accepted_job_count,
    input  wire [31:0]               snapshot_jobs_completed,
    input  wire [31:0]               snapshot_jobs_dropped,
    input  wire                      snapshot_error,
    input  wire                      snapshot_result_valid,
    input  wire [7:0]                snapshot_error_code
);
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_CONTROL              = 8'h00;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_STATUS               = 8'h04;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_MESSAGE_LEN          = 8'h08;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_JOB_COUNT            = 8'h0C;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_RESULT_MASK_WORD0    = 8'h10;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_RESULT_MASK_WORD1    = 8'h14;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_RESULT_MASK_WORD2    = 8'h18;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_RESULT_MASK_WORD3    = 8'h1C;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_RESULT_MASK_WORD4    = 8'h20;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_RESULT_MASK_WORD5    = 8'h24;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_RESULT_MASK_WORD6    = 8'h28;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_RESULT_MASK_WORD7    = 8'h2C;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_ERROR_CODE           = 8'h30;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_LED_CONTROL          = 8'h34;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_VERIFY_CFG           = 8'h38;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_DISPATCH_STATUS      = 8'h3C;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_JOBS_STARTED         = 8'h40;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_JOBS_COMPLETED       = 8'h44;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_JOBS_DROPPED         = 8'h48;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_ACTIVE_CYCLES        = 8'h4C;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_LAST_JOB_CYCLES      = 8'h50;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_MAX_JOB_CYCLES       = 8'h54;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_LAST_BATCH_CYCLES    = 8'h58;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_JOB_TIMEOUT_CYCLES   = 8'h5C;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_IRQ_CTRL_STATUS      = 8'h60;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_BATCH_ID             = 8'h64;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_SNAPSHOT_BATCH_ID    = 8'h68;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_SNAPSHOT_ACCEPTED    = 8'h6C;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_SNAPSHOT_COMPLETED   = 8'h70;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_SNAPSHOT_DROPPED     = 8'h74;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_SNAPSHOT_ERR_STATUS  = 8'h78;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_HW_MAGIC             = 8'h7C;
    localparam [AXI_ADDR_WIDTH-1:0] ADDR_HW_BUILD             = 8'h80;

    localparam [31:0] HW_MAGIC = 32'h53494756;
    localparam [7:0]  HW_API_VERSION = 8'd1;
    localparam [31:0] HW_BUILD_MODE_WORD = HW_BUILD_MODE;

    reg aw_seen;
    reg w_seen;
    reg [AXI_ADDR_WIDTH-1:0] awaddr_reg;
    reg [31:0] wdata_reg;
    reg [3:0]  wstrb_reg;

    wire aw_handshake;
    wire w_handshake;
    wire ar_handshake;
    reg [AXI_ADDR_WIDTH-1:0] write_addr;
    reg [31:0] write_data;
    reg [3:0]  write_strobe;
    reg [31:0] masked_word;
    reg launch_pending;
    reg status_clear_hold;
    reg irq_enable;
    reg irq_pending;
    reg completion_seen;
    reg config_write_ignored;

    wire status_busy;
    wire status_done;
    wire status_error;
    wire status_result_valid;
    wire completion_level;

    assign s_axi_awready = (!aw_seen) && (!s_axi_bvalid);
    assign s_axi_wready = (!w_seen) && (!s_axi_bvalid);
    assign s_axi_arready = !s_axi_rvalid;
    assign aw_handshake = s_axi_awready && s_axi_awvalid;
    assign w_handshake = s_axi_wready && s_axi_wvalid;
    assign ar_handshake = s_axi_arready && s_axi_arvalid;
    assign status_busy = busy || launch_pending;
    assign status_done = status_clear_hold ? 1'b0 : done;
    assign status_error = status_clear_hold ? 1'b0 : error;
    assign status_result_valid = status_clear_hold ? 1'b0 : result_valid;
    assign completion_level = done || error;
    assign irq = (irq_enable && irq_pending) || ((AUTO_IRQ_ENABLE != 0) && autonomous_irq);

    function [31:0] apply_wstrb;
        input [31:0] current_word;
        input [31:0] write_word;
        input [3:0]  strobe;
        integer byte_index;
        begin
            apply_wstrb = current_word;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1) begin
                if (strobe[byte_index]) begin
                    apply_wstrb[(byte_index * 8) +: 8] = write_word[(byte_index * 8) +: 8];
                end
            end
        end
    endfunction

    function [31:0] read_word;
        input [AXI_ADDR_WIDTH-1:0] addr;
        reg [AXI_ADDR_WIDTH-1:0] aligned_addr;
        begin
            aligned_addr = {addr[AXI_ADDR_WIDTH-1:2], 2'b00};
            case (aligned_addr)
                ADDR_STATUS: begin
                    read_word = {
                        25'd0,
                        busy,
                        config_write_ignored,
                        irq_pending,
                        status_result_valid,
                        status_error,
                        status_done,
                        status_busy
                    };
                end
                ADDR_MESSAGE_LEN: begin
                    read_word = {16'd0, message_length};
                end
                ADDR_JOB_COUNT: begin
                    read_word = requested_job_count;
                end
                ADDR_RESULT_MASK_WORD0: begin
                    read_word = result_mask[31:0];
                end
                ADDR_RESULT_MASK_WORD1: begin
                    read_word = result_mask[63:32];
                end
                ADDR_RESULT_MASK_WORD2: begin
                    read_word = result_mask[95:64];
                end
                ADDR_RESULT_MASK_WORD3: begin
                    read_word = result_mask[127:96];
                end
                ADDR_RESULT_MASK_WORD4: begin
                    read_word = result_mask[159:128];
                end
                ADDR_RESULT_MASK_WORD5: begin
                    read_word = result_mask[191:160];
                end
                ADDR_RESULT_MASK_WORD6: begin
                    read_word = result_mask[223:192];
                end
                ADDR_RESULT_MASK_WORD7: begin
                    read_word = result_mask[255:224];
                end
                ADDR_ERROR_CODE: begin
                    read_word = {24'd0, error_code};
                end
                ADDR_LED_CONTROL: begin
                    read_word = led_control;
                end
                ADDR_VERIFY_CFG: begin
                    read_word = {16'd0, dispatch_limit, 6'd0, verify_mode};
                end
                ADDR_DISPATCH_STATUS: begin
                    read_word = {8'd0, status_busy ? 8'd1 : 8'd0, current_job_index, accepted_job_count};
                end
                ADDR_JOBS_STARTED: begin
                    read_word = jobs_started;
                end
                ADDR_JOBS_COMPLETED: begin
                    read_word = jobs_completed;
                end
                ADDR_JOBS_DROPPED: begin
                    read_word = jobs_dropped;
                end
                ADDR_ACTIVE_CYCLES: begin
                    read_word = active_cycles;
                end
                ADDR_LAST_JOB_CYCLES: begin
                    read_word = last_job_cycles;
                end
                ADDR_MAX_JOB_CYCLES: begin
                    read_word = max_job_cycles;
                end
                ADDR_LAST_BATCH_CYCLES: begin
                    read_word = last_batch_cycles;
                end
                ADDR_JOB_TIMEOUT_CYCLES: begin
                    read_word = job_timeout_cycles;
                end
                ADDR_IRQ_CTRL_STATUS: begin
                    read_word = {30'd0, irq_pending, irq_enable};
                end
                ADDR_BATCH_ID: begin
                    read_word = batch_id;
                end
                ADDR_SNAPSHOT_BATCH_ID: begin
                    read_word = snapshot_batch_id;
                end
                ADDR_SNAPSHOT_ACCEPTED: begin
                    read_word = {24'd0, snapshot_accepted_job_count};
                end
                ADDR_SNAPSHOT_COMPLETED: begin
                    read_word = snapshot_jobs_completed;
                end
                ADDR_SNAPSHOT_DROPPED: begin
                    read_word = snapshot_jobs_dropped;
                end
                ADDR_SNAPSHOT_ERR_STATUS: begin
                    read_word = {22'd0, snapshot_result_valid, snapshot_error, snapshot_error_code};
                end
                ADDR_HW_MAGIC: begin
                    read_word = HW_MAGIC;
                end
                ADDR_HW_BUILD: begin
                    read_word = {16'd0, HW_API_VERSION, HW_BUILD_MODE_WORD[7:0]};
                end
                default: begin
                    read_word = 32'd0;
                end
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_seen <= 1'b0;
            w_seen <= 1'b0;
            awaddr_reg <= {AXI_ADDR_WIDTH{1'b0}};
            wdata_reg <= 32'd0;
            wstrb_reg <= 4'd0;
            s_axi_bresp <= 2'b00;
            s_axi_bvalid <= 1'b0;
            s_axi_rdata <= 32'd0;
            s_axi_rresp <= 2'b00;
            s_axi_rvalid <= 1'b0;
            start_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            message_length <= 16'd0;
            requested_job_count <= 32'd0;
            verify_mode <= 2'd0;
            dispatch_limit <= 8'd0;
            led_control <= 32'd0;
            job_timeout_cycles <= 32'd0;
            write_addr <= {AXI_ADDR_WIDTH{1'b0}};
            write_data <= 32'd0;
            write_strobe <= 4'd0;
            masked_word <= 32'd0;
            launch_pending <= 1'b0;
            status_clear_hold <= 1'b0;
            irq_enable <= 1'b0;
            irq_pending <= 1'b0;
            completion_seen <= 1'b0;
            config_write_ignored <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            launch_pending <= 1'b0;
            status_clear_hold <= 1'b0;

            if (completion_level && !completion_seen) begin
                irq_pending <= 1'b1;
            end
            completion_seen <= completion_level;

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end

            if (ar_handshake) begin
                s_axi_rdata <= read_word(s_axi_araddr);
                s_axi_rresp <= 2'b00;
                s_axi_rvalid <= 1'b1;
            end

            if (!s_axi_bvalid && ((aw_seen || aw_handshake) && (w_seen || w_handshake))) begin
                write_addr = aw_seen ? awaddr_reg : s_axi_awaddr;
                write_data = w_seen ? wdata_reg : s_axi_wdata;
                write_strobe = w_seen ? wstrb_reg : s_axi_wstrb;

                case ({write_addr[AXI_ADDR_WIDTH-1:2], 2'b00})
                    ADDR_CONTROL: begin
                        masked_word = apply_wstrb(32'd0, write_data, write_strobe);
                        start_pulse <= masked_word[0];
                        soft_reset_pulse <= masked_word[1];
                        launch_pending <= masked_word[0];
                        status_clear_hold <= |masked_word[1:0];
                        if (|masked_word[1:0]) begin
                            irq_pending <= 1'b0;
                            completion_seen <= 1'b0;
                            config_write_ignored <= 1'b0;
                        end
                    end

                    ADDR_MESSAGE_LEN: begin
                        if (busy) begin
                            config_write_ignored <= 1'b1;
                        end else begin
                            masked_word = apply_wstrb({16'd0, message_length}, write_data, write_strobe);
                            message_length <= masked_word[15:0];
                        end
                    end

                    ADDR_JOB_COUNT: begin
                        if (busy) begin
                            config_write_ignored <= 1'b1;
                        end else begin
                            requested_job_count <= apply_wstrb(requested_job_count, write_data, write_strobe);
                        end
                    end

                    ADDR_LED_CONTROL: begin
                        led_control <= apply_wstrb(led_control, write_data, write_strobe);
                    end

                    ADDR_VERIFY_CFG: begin
                        if (busy) begin
                            config_write_ignored <= 1'b1;
                        end else begin
                            masked_word = apply_wstrb({16'd0, dispatch_limit, 6'd0, verify_mode}, write_data, write_strobe);
                            dispatch_limit <= masked_word[15:8];
                            verify_mode <= masked_word[1:0];
                        end
                    end

                    ADDR_JOB_TIMEOUT_CYCLES: begin
                        if (busy) begin
                            config_write_ignored <= 1'b1;
                        end else begin
                            job_timeout_cycles <= apply_wstrb(job_timeout_cycles, write_data, write_strobe);
                        end
                    end

                    ADDR_IRQ_CTRL_STATUS: begin
                        if (write_strobe[0]) begin
                            irq_enable <= write_data[0];
                            if (write_data[1]) begin
                                irq_pending <= 1'b0;
                            end
                        end
                    end

                    default: begin
                    end
                endcase

                aw_seen <= 1'b0;
                w_seen <= 1'b0;
                s_axi_bresp <= 2'b00;
                s_axi_bvalid <= 1'b1;
            end else begin
                if (aw_handshake) begin
                    aw_seen <= 1'b1;
                    awaddr_reg <= s_axi_awaddr;
                end
                if (w_handshake) begin
                    w_seen <= 1'b1;
                    wdata_reg <= s_axi_wdata;
                    wstrb_reg <= s_axi_wstrb;
                end
            end
        end
    end
endmodule
