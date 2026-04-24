module sha512_stream_engine #(
    parameter integer MESSAGE_ADDR_WIDTH = 11,
    parameter integer MAX_MESSAGE_BYTES = (1 << MESSAGE_ADDR_WIDTH)
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,
    input  wire [255:0]                  prefix0,
    input  wire [255:0]                  prefix1,
    input  wire [15:0]                   message_length,
    output reg                           msg_rd_en,
    output reg  [MESSAGE_ADDR_WIDTH-1:0] msg_rd_addr,
    input  wire                          msg_rd_ready,
    input  wire [31:0]                   msg_rd_data,
    output reg                           busy,
    output reg                           done,
    output reg                           error,
    output reg  [511:0]                  digest_out
);
    localparam [3:0] ST_IDLE      = 4'd0;
    localparam [3:0] ST_PREFIX0   = 4'd1;
    localparam [3:0] ST_PREFIX1   = 4'd2;
    localparam [3:0] ST_MSG_REQ   = 4'd3;
    localparam [3:0] ST_MSG_WAIT  = 4'd4;
    localparam [3:0] ST_MSG_READ  = 4'd5;
    localparam [3:0] ST_PAD80     = 4'd6;
    localparam [3:0] ST_PAD_ZERO  = 4'd7;
    localparam [3:0] ST_LENGTH    = 4'd8;
    localparam [3:0] ST_COMPRESS  = 4'd9;
    localparam [3:0] ST_MSG_LATCH = 4'd10;

    localparam [511:0] SHA512_IV = {
        64'h6a09e667f3bcc908,
        64'hbb67ae8584caa73b,
        64'h3c6ef372fe94f82b,
        64'ha54ff53a5f1d36f1,
        64'h510e527fade682d1,
        64'h9b05688c2b3e6c1f,
        64'h1f83d9abfb41bd6b,
        64'h5be0cd19137e2179
    };

    reg [3:0]    state;
    reg [3:0]    resume_state;
    reg [31:0]   total_padded_bytes;
    reg [31:0]   blocks_remaining;
    reg [6:0]    block_byte_index;
    reg [1023:0] block_buffer;
    reg [511:0]  hash_state;
    reg          block_start;
    reg [255:0]  prefix_shift;
    reg [5:0]    prefix_bytes_left;
    reg [15:0]   message_bytes_left;
    reg [31:0]   zero_pad_bytes_left;
    reg [63:0]   length_shift;
    reg [3:0]    length_bytes_left;
    reg [MESSAGE_ADDR_WIDTH-1:0] message_addr;
    reg [31:0]   padded_total_calc;
    reg [31:0]   raw_total_calc;
    reg [31:0]   msg_word_buf;
    reg [1:0]    msg_byte_sel;
    wire         block_done;
    wire [511:0] block_hash_out;
    wire [7:0]   msg_current_byte;

    assign msg_current_byte = msg_word_buf[{msg_byte_sel, 3'b000} +: 8];

    sha512_compress_core block_core (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (block_start),
        .h_in    (hash_state),
        .block_in(block_buffer),
        .busy    (),
        .done    (block_done),
        .h_out   (block_hash_out)
    );

    always @(*) begin
        raw_total_calc = 32'd64 + {16'd0, message_length};
        padded_total_calc = {raw_total_calc[31:7], 7'd0};
        if (raw_total_calc[6:0] <= 7'd111) begin
            padded_total_calc = padded_total_calc + 32'd128;
        end else begin
            padded_total_calc = padded_total_calc + 32'd256;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            resume_state <= ST_IDLE;
            total_padded_bytes <= 32'd0;
            blocks_remaining <= 32'd0;
            block_byte_index <= 7'd0;
            block_buffer <= 1024'd0;
            hash_state <= SHA512_IV;
            block_start <= 1'b0;
            prefix_shift <= 256'd0;
            prefix_bytes_left <= 6'd0;
            message_bytes_left <= 16'd0;
            zero_pad_bytes_left <= 32'd0;
            length_shift <= 64'd0;
            length_bytes_left <= 4'd0;
            message_addr <= {MESSAGE_ADDR_WIDTH{1'b0}};
            msg_rd_en <= 1'b0;
            msg_rd_addr <= {MESSAGE_ADDR_WIDTH{1'b0}};
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            digest_out <= 512'd0;
            msg_word_buf <= 32'd0;
            msg_byte_sel <= 2'd0;
        end else begin
            block_start <= 1'b0;
            msg_rd_en <= 1'b0;
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        if (({16'd0, message_length} > MAX_MESSAGE_BYTES) ||
                            ({16'd0, message_length} > (1 << MESSAGE_ADDR_WIDTH))) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            error <= 1'b1;
                            digest_out <= 512'd0;
                            state <= ST_IDLE;
                        end else begin
                            total_padded_bytes <= padded_total_calc;
                            blocks_remaining <= padded_total_calc >> 7;
                            block_byte_index <= 7'd0;
                            block_buffer <= 1024'd0;
                            hash_state <= SHA512_IV;
                            prefix_shift <= prefix0;
                            prefix_bytes_left <= 6'd32;
                            message_bytes_left <= message_length;
                            zero_pad_bytes_left <= padded_total_calc - raw_total_calc - 32'd9;
                            length_shift <= (64'd64 + {48'd0, message_length}) << 3;
                            length_bytes_left <= 4'd8;
                            message_addr <= {MESSAGE_ADDR_WIDTH{1'b0}};
                            busy <= 1'b1;
                            error <= 1'b0;
                            msg_word_buf <= 32'd0;
                            msg_byte_sel <= 2'd0;
                            state <= ST_PREFIX0;
                        end
                    end
                end

                ST_PREFIX0: begin
                    prefix_shift <= {8'd0, prefix_shift[255:8]};
                    block_buffer <= {block_buffer[1015:0], prefix_shift[7:0]};
                    if (prefix_bytes_left == 6'd1) begin
                        prefix_shift <= prefix1;
                        prefix_bytes_left <= 6'd32;
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_PREFIX1;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                            state <= ST_PREFIX1;
                        end
                    end else begin
                        prefix_bytes_left <= prefix_bytes_left - 6'd1;
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_PREFIX0;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                        end
                    end
                end

                ST_PREFIX1: begin
                    prefix_shift <= {8'd0, prefix_shift[255:8]};
                    block_buffer <= {block_buffer[1015:0], prefix_shift[7:0]};
                    if (prefix_bytes_left == 6'd1) begin
                        if (message_bytes_left != 16'd0) begin
                            if (block_byte_index == 7'd127) begin
                                block_start <= 1'b1;
                                resume_state <= ST_MSG_REQ;
                                state <= ST_COMPRESS;
                            end else begin
                                block_byte_index <= block_byte_index + 7'd1;
                                state <= ST_MSG_REQ;
                            end
                        end else begin
                            if (block_byte_index == 7'd127) begin
                                block_start <= 1'b1;
                                resume_state <= ST_PAD80;
                                state <= ST_COMPRESS;
                            end else begin
                                block_byte_index <= block_byte_index + 7'd1;
                                state <= ST_PAD80;
                            end
                        end
                    end else begin
                        prefix_bytes_left <= prefix_bytes_left - 6'd1;
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_PREFIX1;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                        end
                    end
                end

                ST_MSG_REQ: begin
                    msg_rd_en <= 1'b1;
                    msg_rd_addr <= message_addr;
                    if (msg_rd_ready) begin
                        state <= ST_MSG_WAIT;
                    end
                end

                ST_MSG_WAIT: begin
                    state <= ST_MSG_LATCH;
                end

                ST_MSG_LATCH: begin
                    msg_word_buf <= msg_rd_data;
                    block_buffer <= {block_buffer[1015:0], msg_rd_data[{message_addr[1:0], 3'b000} +: 8]};
                    message_addr <= message_addr + {{(MESSAGE_ADDR_WIDTH-1){1'b0}}, 1'b1};
                    message_bytes_left <= message_bytes_left - 16'd1;
                    msg_byte_sel <= message_addr[1:0] + 2'd1;
                    if (message_bytes_left == 16'd1) begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_PAD80;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                            state <= ST_PAD80;
                        end
                    end else begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_MSG_READ;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                            state <= ST_MSG_READ;
                        end
                    end
                end

                ST_MSG_READ: begin
                    block_buffer <= {block_buffer[1015:0], msg_current_byte};
                    message_addr <= message_addr + {{(MESSAGE_ADDR_WIDTH-1){1'b0}}, 1'b1};
                    message_bytes_left <= message_bytes_left - 16'd1;
                    msg_byte_sel <= msg_byte_sel + 2'd1;
                    if (message_bytes_left == 16'd1) begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_PAD80;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                            state <= ST_PAD80;
                        end
                    end else begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            if (msg_byte_sel == 2'd3) begin
                                resume_state <= ST_MSG_REQ;
                            end else begin
                                resume_state <= ST_MSG_READ;
                            end
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                            if (msg_byte_sel == 2'd3) begin
                                state <= ST_MSG_REQ;
                            end
                        end
                    end
                end

                ST_PAD80: begin
                    block_buffer <= {block_buffer[1015:0], 8'h80};
                    if (zero_pad_bytes_left != 32'd0) begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_PAD_ZERO;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                            state <= ST_PAD_ZERO;
                        end
                    end else begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_LENGTH;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                            state <= ST_LENGTH;
                        end
                    end
                end

                ST_PAD_ZERO: begin
                    block_buffer <= {block_buffer[1015:0], 8'h00};
                    zero_pad_bytes_left <= zero_pad_bytes_left - 32'd1;
                    if (zero_pad_bytes_left == 32'd1) begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_LENGTH;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                            state <= ST_LENGTH;
                        end
                    end else begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_PAD_ZERO;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                        end
                    end
                end

                ST_LENGTH: begin
                    block_buffer <= {block_buffer[1015:0], length_shift[63:56]};
                    length_shift <= {length_shift[55:0], 8'd0};
                    length_bytes_left <= length_bytes_left - 4'd1;
                    if (length_bytes_left == 4'd1) begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_IDLE;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                            state <= ST_IDLE;
                        end
                    end else begin
                        if (block_byte_index == 7'd127) begin
                            block_start <= 1'b1;
                            resume_state <= ST_LENGTH;
                            state <= ST_COMPRESS;
                        end else begin
                            block_byte_index <= block_byte_index + 7'd1;
                        end
                    end
                end

                ST_COMPRESS: begin
                    if (block_done) begin
                        hash_state <= block_hash_out;
                        block_buffer <= 1024'd0;
                        block_byte_index <= 7'd0;
                        if (blocks_remaining == 32'd1) begin
                            digest_out <= block_hash_out;
                            busy <= 1'b0;
                            done <= 1'b1;
                            error <= 1'b0;
                            state <= ST_IDLE;
                        end else begin
                            blocks_remaining <= blocks_remaining - 32'd1;
                            state <= resume_state;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                    busy <= 1'b0;
                end
            endcase
        end
    end
endmodule
