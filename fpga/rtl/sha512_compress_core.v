module sha512_compress_core (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    input  wire [511:0]  h_in,
    input  wire [1023:0] block_in,
    output reg           busy,
    output reg           done,
    output reg  [511:0]  h_out
);
    reg [6:0] round_index;
    reg [63:0] a_reg;
    reg [63:0] b_reg;
    reg [63:0] c_reg;
    reg [63:0] d_reg;
    reg [63:0] e_reg;
    reg [63:0] f_reg;
    reg [63:0] g_reg;
    reg [63:0] h_reg;
    reg [63:0] w_mem [0:15];

    reg [63:0] w_t;
    reg [63:0] w_new;
    reg [63:0] temp1;
    reg [63:0] temp2;
    reg [63:0] next_a;
    reg [63:0] next_b;
    reg [63:0] next_c;
    reg [63:0] next_d;
    reg [63:0] next_e;
    reg [63:0] next_f;
    reg [63:0] next_g;
    reg [63:0] next_h;
    reg [3:0]  w_idx;
    integer    load_index;

    function [63:0] rotr64;
        input [63:0] value;
        input integer amount;
        begin
            rotr64 = (value >> amount) | (value << (64 - amount));
        end
    endfunction

    function [63:0] ch64;
        input [63:0] x;
        input [63:0] y;
        input [63:0] z;
        begin
            ch64 = (x & y) ^ (~x & z);
        end
    endfunction

    function [63:0] maj64;
        input [63:0] x;
        input [63:0] y;
        input [63:0] z;
        begin
            maj64 = (x & y) ^ (x & z) ^ (y & z);
        end
    endfunction

    function [63:0] big_sigma0;
        input [63:0] x;
        begin
            big_sigma0 = rotr64(x, 28) ^ rotr64(x, 34) ^ rotr64(x, 39);
        end
    endfunction

    function [63:0] big_sigma1;
        input [63:0] x;
        begin
            big_sigma1 = rotr64(x, 14) ^ rotr64(x, 18) ^ rotr64(x, 41);
        end
    endfunction

    function [63:0] small_sigma0;
        input [63:0] x;
        begin
            small_sigma0 = rotr64(x, 1) ^ rotr64(x, 8) ^ (x >> 7);
        end
    endfunction

    function [63:0] small_sigma1;
        input [63:0] x;
        begin
            small_sigma1 = rotr64(x, 19) ^ rotr64(x, 61) ^ (x >> 6);
        end
    endfunction

    function [63:0] round_constant;
        input [6:0] index;
        begin
            case (index)
                7'd0: round_constant = 64'h428a2f98d728ae22;
                7'd1: round_constant = 64'h7137449123ef65cd;
                7'd2: round_constant = 64'hb5c0fbcfec4d3b2f;
                7'd3: round_constant = 64'he9b5dba58189dbbc;
                7'd4: round_constant = 64'h3956c25bf348b538;
                7'd5: round_constant = 64'h59f111f1b605d019;
                7'd6: round_constant = 64'h923f82a4af194f9b;
                7'd7: round_constant = 64'hab1c5ed5da6d8118;
                7'd8: round_constant = 64'hd807aa98a3030242;
                7'd9: round_constant = 64'h12835b0145706fbe;
                7'd10: round_constant = 64'h243185be4ee4b28c;
                7'd11: round_constant = 64'h550c7dc3d5ffb4e2;
                7'd12: round_constant = 64'h72be5d74f27b896f;
                7'd13: round_constant = 64'h80deb1fe3b1696b1;
                7'd14: round_constant = 64'h9bdc06a725c71235;
                7'd15: round_constant = 64'hc19bf174cf692694;
                7'd16: round_constant = 64'he49b69c19ef14ad2;
                7'd17: round_constant = 64'hefbe4786384f25e3;
                7'd18: round_constant = 64'h0fc19dc68b8cd5b5;
                7'd19: round_constant = 64'h240ca1cc77ac9c65;
                7'd20: round_constant = 64'h2de92c6f592b0275;
                7'd21: round_constant = 64'h4a7484aa6ea6e483;
                7'd22: round_constant = 64'h5cb0a9dcbd41fbd4;
                7'd23: round_constant = 64'h76f988da831153b5;
                7'd24: round_constant = 64'h983e5152ee66dfab;
                7'd25: round_constant = 64'ha831c66d2db43210;
                7'd26: round_constant = 64'hb00327c898fb213f;
                7'd27: round_constant = 64'hbf597fc7beef0ee4;
                7'd28: round_constant = 64'hc6e00bf33da88fc2;
                7'd29: round_constant = 64'hd5a79147930aa725;
                7'd30: round_constant = 64'h06ca6351e003826f;
                7'd31: round_constant = 64'h142929670a0e6e70;
                7'd32: round_constant = 64'h27b70a8546d22ffc;
                7'd33: round_constant = 64'h2e1b21385c26c926;
                7'd34: round_constant = 64'h4d2c6dfc5ac42aed;
                7'd35: round_constant = 64'h53380d139d95b3df;
                7'd36: round_constant = 64'h650a73548baf63de;
                7'd37: round_constant = 64'h766a0abb3c77b2a8;
                7'd38: round_constant = 64'h81c2c92e47edaee6;
                7'd39: round_constant = 64'h92722c851482353b;
                7'd40: round_constant = 64'ha2bfe8a14cf10364;
                7'd41: round_constant = 64'ha81a664bbc423001;
                7'd42: round_constant = 64'hc24b8b70d0f89791;
                7'd43: round_constant = 64'hc76c51a30654be30;
                7'd44: round_constant = 64'hd192e819d6ef5218;
                7'd45: round_constant = 64'hd69906245565a910;
                7'd46: round_constant = 64'hf40e35855771202a;
                7'd47: round_constant = 64'h106aa07032bbd1b8;
                7'd48: round_constant = 64'h19a4c116b8d2d0c8;
                7'd49: round_constant = 64'h1e376c085141ab53;
                7'd50: round_constant = 64'h2748774cdf8eeb99;
                7'd51: round_constant = 64'h34b0bcb5e19b48a8;
                7'd52: round_constant = 64'h391c0cb3c5c95a63;
                7'd53: round_constant = 64'h4ed8aa4ae3418acb;
                7'd54: round_constant = 64'h5b9cca4f7763e373;
                7'd55: round_constant = 64'h682e6ff3d6b2b8a3;
                7'd56: round_constant = 64'h748f82ee5defb2fc;
                7'd57: round_constant = 64'h78a5636f43172f60;
                7'd58: round_constant = 64'h84c87814a1f0ab72;
                7'd59: round_constant = 64'h8cc702081a6439ec;
                7'd60: round_constant = 64'h90befffa23631e28;
                7'd61: round_constant = 64'ha4506cebde82bde9;
                7'd62: round_constant = 64'hbef9a3f7b2c67915;
                7'd63: round_constant = 64'hc67178f2e372532b;
                7'd64: round_constant = 64'hca273eceea26619c;
                7'd65: round_constant = 64'hd186b8c721c0c207;
                7'd66: round_constant = 64'heada7dd6cde0eb1e;
                7'd67: round_constant = 64'hf57d4f7fee6ed178;
                7'd68: round_constant = 64'h06f067aa72176fba;
                7'd69: round_constant = 64'h0a637dc5a2c898a6;
                7'd70: round_constant = 64'h113f9804bef90dae;
                7'd71: round_constant = 64'h1b710b35131c471b;
                7'd72: round_constant = 64'h28db77f523047d84;
                7'd73: round_constant = 64'h32caab7b40c72493;
                7'd74: round_constant = 64'h3c9ebe0a15c9bebc;
                7'd75: round_constant = 64'h431d67c49c100d4c;
                7'd76: round_constant = 64'h4cc5d4becb3e42b6;
                7'd77: round_constant = 64'h597f299cfc657e2a;
                7'd78: round_constant = 64'h5fcb6fab3ad6faec;
                default: round_constant = 64'h6c44198c4a475817;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            h_out <= 512'd0;
            round_index <= 7'd0;
            a_reg <= 64'd0;
            b_reg <= 64'd0;
            c_reg <= 64'd0;
            d_reg <= 64'd0;
            e_reg <= 64'd0;
            f_reg <= 64'd0;
            g_reg <= 64'd0;
            h_reg <= 64'd0;
            for (load_index = 0; load_index < 16; load_index = load_index + 1) begin
                w_mem[load_index] <= 64'd0;
            end
        end else begin
            done <= 1'b0;

            if (!busy) begin
                if (start) begin
                    busy <= 1'b1;
                    round_index <= 7'd0;
                    a_reg <= h_in[511:448];
                    b_reg <= h_in[447:384];
                    c_reg <= h_in[383:320];
                    d_reg <= h_in[319:256];
                    e_reg <= h_in[255:192];
                    f_reg <= h_in[191:128];
                    g_reg <= h_in[127:64];
                    h_reg <= h_in[63:0];
                    for (load_index = 0; load_index < 16; load_index = load_index + 1) begin
                        w_mem[load_index] <= block_in[1023 - (load_index * 64) -: 64];
                    end
                end
            end else begin
                w_idx = round_index[3:0];
                if (round_index < 7'd16) begin
                    w_t = w_mem[w_idx];
                end else begin
                    w_new =
                        small_sigma1(w_mem[(w_idx + 4'd14) & 4'hf]) +
                        w_mem[(w_idx + 4'd9) & 4'hf] +
                        small_sigma0(w_mem[(w_idx + 4'd1) & 4'hf]) +
                        w_mem[w_idx];
                    w_mem[w_idx] <= w_new;
                    w_t = w_new;
                end

                temp1 = h_reg + big_sigma1(e_reg) + ch64(e_reg, f_reg, g_reg) + round_constant(round_index) + w_t;
                temp2 = big_sigma0(a_reg) + maj64(a_reg, b_reg, c_reg);

                next_a = temp1 + temp2;
                next_b = a_reg;
                next_c = b_reg;
                next_d = c_reg;
                next_e = d_reg + temp1;
                next_f = e_reg;
                next_g = f_reg;
                next_h = g_reg;

                if (round_index == 7'd79) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    h_out[511:448] <= h_in[511:448] + next_a;
                    h_out[447:384] <= h_in[447:384] + next_b;
                    h_out[383:320] <= h_in[383:320] + next_c;
                    h_out[319:256] <= h_in[319:256] + next_d;
                    h_out[255:192] <= h_in[255:192] + next_e;
                    h_out[191:128] <= h_in[191:128] + next_f;
                    h_out[127:64]  <= h_in[127:64]  + next_g;
                    h_out[63:0]    <= h_in[63:0]    + next_h;
                end else begin
                    round_index <= round_index + 7'd1;
                    a_reg <= next_a;
                    b_reg <= next_b;
                    c_reg <= next_c;
                    d_reg <= next_d;
                    e_reg <= next_e;
                    f_reg <= next_f;
                    g_reg <= next_g;
                    h_reg <= next_h;
                end
            end
        end
    end
endmodule
