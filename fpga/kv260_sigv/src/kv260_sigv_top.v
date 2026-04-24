module kv260_sigv_top #(
    parameter integer AXI_ADDR_WIDTH = 8,
    parameter integer MESSAGE_ADDR_WIDTH = 12,
    parameter integer JOB_ADDR_WIDTH = 15,
    parameter integer BRINGUP_MODE = 0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ap_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI_CTRL, ASSOCIATED_RESET ap_rst_n, FREQ_HZ 99999001" *)
    input  wire                          ap_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ap_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          ap_rst_n,

    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, ADDR_WIDTH 8, DATA_WIDTH 32, HAS_BRESP 1, HAS_RRESP 1, HAS_WSTRB 1, FREQ_HZ 99999001" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL AWADDR" *)
    input  wire [AXI_ADDR_WIDTH-1:0]     s_axi_ctrl_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL AWVALID" *)
    input  wire                          s_axi_ctrl_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL AWREADY" *)
    output wire                          s_axi_ctrl_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL WDATA" *)
    input  wire [31:0]                   s_axi_ctrl_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL WSTRB" *)
    input  wire [3:0]                    s_axi_ctrl_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL WVALID" *)
    input  wire                          s_axi_ctrl_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL WREADY" *)
    output wire                          s_axi_ctrl_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL BRESP" *)
    output wire [1:0]                    s_axi_ctrl_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL BVALID" *)
    output wire                          s_axi_ctrl_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL BREADY" *)
    input  wire                          s_axi_ctrl_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL ARADDR" *)
    input  wire [AXI_ADDR_WIDTH-1:0]     s_axi_ctrl_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL ARVALID" *)
    input  wire                          s_axi_ctrl_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL ARREADY" *)
    output wire                          s_axi_ctrl_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL RDATA" *)
    output wire [31:0]                   s_axi_ctrl_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL RRESP" *)
    output wire [1:0]                    s_axi_ctrl_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL RVALID" *)
    output wire                          s_axi_ctrl_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CTRL RREADY" *)
    input  wire                          s_axi_ctrl_rready,

    (* X_INTERFACE_PARAMETER = "FREQ_HZ 99999001, ASSOCIATED_RESET message_bram_rst" *)
    output wire                          message_bram_clk,
    output wire                          message_bram_rst,
    output wire                          message_bram_en,
    output wire                          message_bram_regce,
    output wire [3:0]                    message_bram_we,
    output wire [31:0]                   message_bram_addr,
    output wire [31:0]                   message_bram_din,
    input  wire [31:0]                   message_bram_dout,

    (* X_INTERFACE_PARAMETER = "FREQ_HZ 99999001, ASSOCIATED_RESET job_bram_rst" *)
    output wire                          job_bram_clk,
    output wire                          job_bram_rst,
    output wire                          job_bram_en,
    output wire                          job_bram_regce,
    output wire [3:0]                    job_bram_we,
    output wire [31:0]                   job_bram_addr,
    output wire [31:0]                   job_bram_din,
    input  wire [31:0]                   job_bram_dout,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    output wire                          irq,
    output wire [2:0]                    debug_led
);
    wire start_pulse;
    wire soft_reset_pulse;
    wire [15:0] message_length;
    wire [31:0] requested_job_count;
    wire [1:0]  verify_mode;
    wire [7:0]  dispatch_limit;
    wire [31:0] led_control;
    wire [31:0] job_timeout_cycles;
    wire        busy;
    wire        done;
    wire        error;
    wire        result_valid;
    wire [7:0]  error_code;
    wire [255:0] result_mask;
    wire [7:0]  accepted_job_count;
    wire [7:0]  current_job_index;
    wire [31:0] jobs_started;
    wire [31:0] jobs_completed;
    wire [31:0] jobs_dropped;
    wire [31:0] active_cycles;
    wire [31:0] last_job_cycles;
    wire [31:0] max_job_cycles;
    wire [31:0] last_batch_cycles;
    wire [31:0] batch_id;
    wire [31:0] snapshot_batch_id;
    wire [7:0]  snapshot_accepted_job_count;
    wire [31:0] snapshot_jobs_completed;
    wire [31:0] snapshot_jobs_dropped;
    wire        snapshot_error;
    wire        snapshot_result_valid;
    wire [7:0]  snapshot_error_code;
    wire [MESSAGE_ADDR_WIDTH-3:0] message_bram_word_addr;
    wire [JOB_ADDR_WIDTH-3:0]     job_bram_word_addr;
    wire        axi_irq;
    wire        autonomous_irq;
    wire        autonomous_heartbeat_led;
    reg  [23:0] bringup_irq_counter;

    initial begin
        bringup_irq_counter = 24'd0;
    end

    sigv_axi_regs #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .HW_BUILD_MODE (BRINGUP_MODE),
        .AUTO_IRQ_ENABLE(BRINGUP_MODE != 0)
    ) regs_inst (
        .clk             (ap_clk),
        .rst_n           (ap_rst_n),
        .s_axi_awaddr    (s_axi_ctrl_awaddr),
        .s_axi_awvalid   (s_axi_ctrl_awvalid),
        .s_axi_awready   (s_axi_ctrl_awready),
        .s_axi_wdata     (s_axi_ctrl_wdata),
        .s_axi_wstrb     (s_axi_ctrl_wstrb),
        .s_axi_wvalid    (s_axi_ctrl_wvalid),
        .s_axi_wready    (s_axi_ctrl_wready),
        .s_axi_bresp     (s_axi_ctrl_bresp),
        .s_axi_bvalid    (s_axi_ctrl_bvalid),
        .s_axi_bready    (s_axi_ctrl_bready),
        .s_axi_araddr    (s_axi_ctrl_araddr),
        .s_axi_arvalid   (s_axi_ctrl_arvalid),
        .s_axi_arready   (s_axi_ctrl_arready),
        .s_axi_rdata     (s_axi_ctrl_rdata),
        .s_axi_rresp     (s_axi_ctrl_rresp),
        .s_axi_rvalid    (s_axi_ctrl_rvalid),
        .s_axi_rready    (s_axi_ctrl_rready),
        .start_pulse     (start_pulse),
        .soft_reset_pulse(soft_reset_pulse),
        .message_length  (message_length),
        .requested_job_count(requested_job_count),
        .verify_mode     (verify_mode),
        .dispatch_limit  (dispatch_limit),
        .led_control     (led_control),
        .job_timeout_cycles(job_timeout_cycles),
        .autonomous_irq  (autonomous_irq),
        .irq             (axi_irq),
        .busy            (busy),
        .done            (done),
        .error           (error),
        .result_valid    (result_valid),
        .error_code      (error_code),
        .result_mask     (result_mask),
        .accepted_job_count(accepted_job_count),
        .current_job_index(current_job_index),
        .jobs_started    (jobs_started),
        .jobs_completed  (jobs_completed),
        .jobs_dropped    (jobs_dropped),
        .active_cycles   (active_cycles),
        .last_job_cycles (last_job_cycles),
        .max_job_cycles  (max_job_cycles),
        .last_batch_cycles(last_batch_cycles),
        .batch_id        (batch_id),
        .snapshot_batch_id(snapshot_batch_id),
        .snapshot_accepted_job_count(snapshot_accepted_job_count),
        .snapshot_jobs_completed(snapshot_jobs_completed),
        .snapshot_jobs_dropped(snapshot_jobs_dropped),
        .snapshot_error  (snapshot_error),
        .snapshot_result_valid(snapshot_result_valid),
        .snapshot_error_code(snapshot_error_code)
    );

    generate
        if (BRINGUP_MODE != 0) begin : gen_bringup_core
            sigv_kv260_bringup_core #(
                .MESSAGE_ADDR_WIDTH(MESSAGE_ADDR_WIDTH),
                .JOB_ADDR_WIDTH    (JOB_ADDR_WIDTH)
            ) core_inst (
                .clk              (ap_clk),
                .rst_n            (ap_rst_n),
                .start            (start_pulse),
                .soft_reset       (soft_reset_pulse),
                .message_length   (message_length),
                .requested_job_count(requested_job_count),
                .verify_mode      (verify_mode),
                .dispatch_limit   (dispatch_limit),
                .job_timeout_cycles(job_timeout_cycles),
                .busy             (busy),
                .done             (done),
                .error            (error),
                .result_valid     (result_valid),
                .error_code       (error_code),
                .result_mask      (result_mask),
                .accepted_job_count(accepted_job_count),
                .current_job_index(current_job_index),
                .jobs_started     (jobs_started),
                .jobs_completed   (jobs_completed),
                .jobs_dropped     (jobs_dropped),
                .active_cycles    (active_cycles),
                .last_job_cycles  (last_job_cycles),
                .max_job_cycles   (max_job_cycles),
                .last_batch_cycles(last_batch_cycles),
                .batch_id         (batch_id),
                .snapshot_batch_id(snapshot_batch_id),
                .snapshot_accepted_job_count(snapshot_accepted_job_count),
                .snapshot_jobs_completed(snapshot_jobs_completed),
                .snapshot_jobs_dropped(snapshot_jobs_dropped),
                .snapshot_error   (snapshot_error),
                .snapshot_result_valid(snapshot_result_valid),
                .snapshot_error_code(snapshot_error_code),
                .heartbeat_irq    (autonomous_irq),
                .heartbeat_led    (autonomous_heartbeat_led),
                .message_bram_en  (message_bram_en),
                .message_bram_addr(message_bram_word_addr),
                .message_bram_dout(message_bram_dout),
                .job_bram_en      (job_bram_en),
                .job_bram_addr    (job_bram_word_addr),
                .job_bram_dout    (job_bram_dout)
            );
        end else begin : gen_full_core
            assign autonomous_irq = 1'b0;
            assign autonomous_heartbeat_led = 1'b0;
            sigv_kv260_core #(
                .MESSAGE_ADDR_WIDTH(MESSAGE_ADDR_WIDTH),
                .JOB_ADDR_WIDTH    (JOB_ADDR_WIDTH),
                .VERIFY_ENGINE_COUNT(1)
            ) core_inst (
                .clk              (ap_clk),
                .rst_n            (ap_rst_n),
                .start            (start_pulse),
                .soft_reset       (soft_reset_pulse),
                .message_length   (message_length),
                .requested_job_count(requested_job_count),
                .verify_mode      (verify_mode),
                .dispatch_limit   (dispatch_limit),
                .job_timeout_cycles(job_timeout_cycles),
                .busy             (busy),
                .done             (done),
                .error            (error),
                .result_valid     (result_valid),
                .error_code       (error_code),
                .result_mask      (result_mask),
                .accepted_job_count(accepted_job_count),
                .current_job_index(current_job_index),
                .jobs_started     (jobs_started),
                .jobs_completed   (jobs_completed),
                .jobs_dropped     (jobs_dropped),
                .active_cycles    (active_cycles),
                .last_job_cycles  (last_job_cycles),
                .max_job_cycles   (max_job_cycles),
                .last_batch_cycles(last_batch_cycles),
                .batch_id         (batch_id),
                .snapshot_batch_id(snapshot_batch_id),
                .snapshot_accepted_job_count(snapshot_accepted_job_count),
                .snapshot_jobs_completed(snapshot_jobs_completed),
                .snapshot_jobs_dropped(snapshot_jobs_dropped),
                .snapshot_error   (snapshot_error),
                .snapshot_result_valid(snapshot_result_valid),
                .snapshot_error_code(snapshot_error_code),
                .message_bram_en  (message_bram_en),
                .message_bram_addr(message_bram_word_addr),
                .message_bram_dout(message_bram_dout),
                .job_bram_en      (job_bram_en),
                .job_bram_addr    (job_bram_word_addr),
                .job_bram_dout    (job_bram_dout)
            );
        end
    endgenerate

    always @(posedge ap_clk) begin
        if (BRINGUP_MODE != 0) begin
            bringup_irq_counter <= bringup_irq_counter + 24'd1;
        end else begin
            bringup_irq_counter <= 24'd0;
        end
    end

    assign message_bram_clk = ap_clk;
    assign message_bram_rst = ~ap_rst_n;
    assign message_bram_regce = message_bram_en;
    assign message_bram_we = 4'b0000;
    assign message_bram_addr = {{(32-MESSAGE_ADDR_WIDTH){1'b0}}, message_bram_word_addr, 2'b00};
    assign message_bram_din = 32'd0;

    assign job_bram_clk = ap_clk;
    assign job_bram_rst = ~ap_rst_n;
    assign job_bram_regce = job_bram_en;
    assign job_bram_we = 4'b0000;
    assign job_bram_addr = {{(32-JOB_ADDR_WIDTH){1'b0}}, job_bram_word_addr, 2'b00};
    assign job_bram_din = 32'd0;

    assign irq = (BRINGUP_MODE != 0) ? bringup_irq_counter[23] : axi_irq;

    assign debug_led = led_control[0]
        ? led_control[3:1]
        : ((BRINGUP_MODE != 0) ? {error, autonomous_heartbeat_led, busy} : {error, busy, result_valid});
endmodule
