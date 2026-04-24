module scalar_wnaf4_recode (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] scalar_in,
    output reg          busy,
    output reg          done,
    output reg          digit_valid,
    output reg  [7:0]   digit_index,
    output reg  [3:0]   digit
);
    reg [256:0] scalar_work;
    reg [7:0]   bit_index;
    reg [3:0]   low_nibble;
    reg [3:0]   digit_abs_value;
    reg [3:0]   digit_value;
    reg [256:0] adjusted_scalar;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            digit_valid <= 1'b0;
            digit_index <= 8'd0;
            digit <= 4'd0;
            scalar_work <= 257'd0;
            bit_index <= 8'd0;
            low_nibble <= 4'd0;
            digit_abs_value <= 4'd0;
            digit_value <= 4'd0;
            adjusted_scalar <= 257'd0;
        end else begin
            done <= 1'b0;
            digit_valid <= 1'b0;

            if (!busy) begin
                if (start) begin
                    busy <= 1'b1;
                    scalar_work <= {1'b0, scalar_in};
                    bit_index <= 8'd0;
                end
            end else begin
                low_nibble = scalar_work[3:0];
                digit_value = 4'd0;
                digit_abs_value = 4'd0;

                if (scalar_work[0]) begin
                    case (low_nibble)
                        4'd1: begin
                            digit_value = 4'h1;
                            digit_abs_value = 4'd1;
                        end
                        4'd3: begin
                            digit_value = 4'h3;
                            digit_abs_value = 4'd3;
                        end
                        4'd5: begin
                            digit_value = 4'h5;
                            digit_abs_value = 4'd5;
                        end
                        4'd7: begin
                            digit_value = 4'h7;
                            digit_abs_value = 4'd7;
                        end
                        4'd9: begin
                            digit_value = 4'h9;
                            digit_abs_value = 4'd7;
                        end
                        4'd11: begin
                            digit_value = 4'hB;
                            digit_abs_value = 4'd5;
                        end
                        4'd13: begin
                            digit_value = 4'hD;
                            digit_abs_value = 4'd3;
                        end
                        4'd15: begin
                            digit_value = 4'hF;
                            digit_abs_value = 4'd1;
                        end
                        default: begin
                            digit_value = 4'd0;
                            digit_abs_value = 4'd0;
                        end
                    endcase

                    if (digit_value[3]) begin
                        adjusted_scalar = scalar_work + {{253{1'b0}}, digit_abs_value};
                    end else begin
                        adjusted_scalar = scalar_work - {{253{1'b0}}, digit_abs_value};
                    end
                end else begin
                    adjusted_scalar = scalar_work;
                end

                digit <= digit_value;
                digit_index <= bit_index;
                digit_valid <= 1'b1;
                scalar_work <= adjusted_scalar >> 1;

                if (bit_index == 8'd255) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    bit_index <= bit_index + 8'd1;
                end
            end
        end
    end
endmodule
