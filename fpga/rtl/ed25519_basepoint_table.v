`timescale 1ns/1ps

module ed25519_basepoint_table(
    input  wire [3:0]   selector,
    output reg          valid,
    output reg  [254:0] point_x,
    output reg  [254:0] point_y,
    output reg  [254:0] point_z,
    output reg  [254:0] point_t
);
    localparam [254:0] POINT_Z_AFFINE = 255'd1;

    localparam [254:0] POINT_X_01 = 255'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a;
    localparam [254:0] POINT_Y_01 = 255'h6666666666666666666666666666666666666666666666666666666666666658;
    localparam [254:0] POINT_T_01 = 255'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3;

    localparam [254:0] POINT_X_02 = 255'h36ab384c9f5a046c3d043b7d1833e7ac080d8e4515d7a45f83c5a14e2843ce0e;
    localparam [254:0] POINT_Y_02 = 255'h2260cdf3092329c21da25ee8c9a21f5697390f51643851560e5f46ae6af8a3c9;
    localparam [254:0] POINT_T_02 = 255'h2498a7850b2f68dc1de55f087303b4135d79acc9c1f72402b71a3f556d69b401;

    localparam [254:0] POINT_X_03 = 255'h67ae9c4a22928f491ff4ae743edac83a6343981981624886ac62485fd3f8e25c;
    localparam [254:0] POINT_Y_03 = 255'h1267b1d177ee69aba126a18e60269ef79f16ec176724030402c3684878f5b4d4;
    localparam [254:0] POINT_T_03 = 255'h2a4d025cb1dd9510ebef3783adb915275c27358bfb16fc4acdf908fa78b3a41a;

    localparam [254:0] POINT_X_04 = 255'h203da8db56cff1468325d4b87a3520f91a739ec193ce1547493aa657c4c9f870;
    localparam [254:0] POINT_Y_04 = 255'h47d0e827cb1595e1470eb88580d5716c4cf22832ea2f0ff0df38ab61ca32112f;
    localparam [254:0] POINT_T_04 = 255'h22783cd8d873260c7214ba6ac67c29607195e31eb6dd07ca5f8f22f6728a1358;

    localparam [254:0] POINT_X_05 = 255'h49fda73eade3587bfcef7cf7d12da5de5c2819f93e1be1a591409cc0322ef233;
    localparam [254:0] POINT_Y_05 = 255'h5f4825b298feae6fe02c6e148992466631282eca89430b5d10d21f83d676c8ed;
    localparam [254:0] POINT_T_05 = 255'h745c562c9c593d4c3160ea508736c7f9afb94e85000926bf641950bcf3e801d0;

    localparam [254:0] POINT_X_06 = 255'h4c9797ba7a45601c62aeacc0dd0a29bea1e599826c7b4427783a741a7dcbf23d;
    localparam [254:0] POINT_Y_06 = 255'h054de3fc2886d8a11db709a7fd4f7d77f9417c06944d6b60c1d27ad0f9497ef4;
    localparam [254:0] POINT_T_06 = 255'h3c32efd109aa604f82855a994fe7dcc40baf92147c7dc89bc7ced6c8b44ef1d2;

    localparam [254:0] POINT_X_07 = 255'h14568685fcf4bd4ee9e3ee194b1d810783e809f3bbf1ce955855981af50e4107;
    localparam [254:0] POINT_Y_07 = 255'h31c563e32b47d52f87ce6468dd36ad41f0882b46f7abf23d12c4c4b59f4062b8;
    localparam [254:0] POINT_T_07 = 255'h119e77b11d165e1b9be82dc589d5bab45294632a1e9aa4e410bd45565587ed1b;

    localparam [254:0] POINT_X_08 = 255'h6742e15f97d771b642862d5cf84ecf93eb3ac67b80698b993b87fdbc08a584c8;
    localparam [254:0] POINT_Y_08 = 255'h21d30600c9e573796ead6f09668af38f81783cfc621ee4931e2f5ba9fc37b9b4;
    localparam [254:0] POINT_T_08 = 255'h2c4f59ecedf7eae11608c29b38b3d99345f0ce6d344c2bf56fbef41ad41a51bf;

    localparam [254:0] POINT_X_09 = 255'h357cc970c80071651bf336e06f9422b886d80e5c2e4e0294d3e023065185715c;
    localparam [254:0] POINT_Y_09 = 255'h7f3d23c2c2dd0df4b2befce956f2d2fd1f789013236e4430c74e44845522f1c0;
    localparam [254:0] POINT_T_09 = 255'h5c70fc48ea87cbf9db6676adf747cd7417b3d4a0f770327e5c3b386f88b2f465;

    localparam [254:0] POINT_X_10 = 255'h602c797e30ca6d754470b60ed2bc8677207e8e4ed836f81444951f224877f94f;
    localparam [254:0] POINT_Y_10 = 255'h637ffcaa7a1b2477c8e44d54c898bfcf2576a6853de0e843ba8874b06ae87b2c;
    localparam [254:0] POINT_T_10 = 255'h36e05f326673529288bfd10309b4577f74f5a9f4b3b9252543e74c95035bc63e;

    localparam [254:0] POINT_X_11 = 255'h14e528b1154be417b6cf078dd6712438d381a5b2c593d552ff2fd2c1207cf3cb;
    localparam [254:0] POINT_Y_11 = 255'h2d9082313f21ab975a6f7ce340ff0fce1258591c3c9c58d4308f2dc36a033713;
    localparam [254:0] POINT_T_11 = 255'h5ae6a565800f28a239caa6bef216adbf590001dde18fc837eb85cf2edb5beed4;

    localparam [254:0] POINT_X_12 = 255'h4719e17e016e5d355ecf70e00ca249db3295bf2385c13b42ae62fe6678f0902d;
    localparam [254:0] POINT_Y_12 = 255'h4070ce608bce8022e71d6c4e637825b856487eb45273966733d281dc2e2de4f9;
    localparam [254:0] POINT_T_12 = 255'h2b344e203a4858a12067d3a831cd006f0f1ef0c48c5b13abd5ecc3128e4b1ccb;

    localparam [254:0] POINT_X_13 = 255'h107427e0d5f366ccdb33adf0282d304f8843e3e88d22b7b83780e073b7c05fed;
    localparam [254:0] POINT_Y_13 = 255'h12dbb00ded538b7478466022d2da89b83740cfb2289a272387efe1aeea401f80;
    localparam [254:0] POINT_T_13 = 255'h412806b917be6460c5c0dd61cd5623385b14aa51eb2e8efc522cdccde8de2f53;

    localparam [254:0] POINT_X_14 = 255'h205f3b42f5884aaf048c7a895ccabb15d8dee6d83e39832aa38e7353b58515b9;
    localparam [254:0] POINT_Y_14 = 255'h4e50256f50c4cb8115bad17acbb702bfa74898e819b6265c8369fd98899c2839;
    localparam [254:0] POINT_T_14 = 255'h66432d1463a87e0f8ea60abf3cbfe47971e7437fe66445e089133d2ca271c2e0;

    localparam [254:0] POINT_X_15 = 255'h4f162deaec2ec435dc5ac6f95d20419ed9631374770189cb90617f3e66a18dc1;
    localparam [254:0] POINT_Y_15 = 255'h12cbfb2d04ff22f55162f70164d29331ace5af18a19a9aa1946d4cc4ad2e5cdf;
    localparam [254:0] POINT_T_15 = 255'h5e33f00e36b77491ab24fd2241760de2fa63b68fe40ae5f5140d7f335c92bf29;

    always @(*) begin
        valid = 1'b0;
        point_x = 255'd0;
        point_y = 255'd0;
        point_z = 255'd0;
        point_t = 255'd0;

        case (selector)
            4'd1: begin
                valid = 1'b1;
                point_x = POINT_X_01;
                point_y = POINT_Y_01;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_01;
            end
            4'd2: begin
                valid = 1'b1;
                point_x = POINT_X_02;
                point_y = POINT_Y_02;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_02;
            end
            4'd3: begin
                valid = 1'b1;
                point_x = POINT_X_03;
                point_y = POINT_Y_03;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_03;
            end
            4'd4: begin
                valid = 1'b1;
                point_x = POINT_X_04;
                point_y = POINT_Y_04;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_04;
            end
            4'd5: begin
                valid = 1'b1;
                point_x = POINT_X_05;
                point_y = POINT_Y_05;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_05;
            end
            4'd6: begin
                valid = 1'b1;
                point_x = POINT_X_06;
                point_y = POINT_Y_06;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_06;
            end
            4'd7: begin
                valid = 1'b1;
                point_x = POINT_X_07;
                point_y = POINT_Y_07;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_07;
            end
            4'd8: begin
                valid = 1'b1;
                point_x = POINT_X_08;
                point_y = POINT_Y_08;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_08;
            end
            4'd9: begin
                valid = 1'b1;
                point_x = POINT_X_09;
                point_y = POINT_Y_09;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_09;
            end
            4'd10: begin
                valid = 1'b1;
                point_x = POINT_X_10;
                point_y = POINT_Y_10;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_10;
            end
            4'd11: begin
                valid = 1'b1;
                point_x = POINT_X_11;
                point_y = POINT_Y_11;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_11;
            end
            4'd12: begin
                valid = 1'b1;
                point_x = POINT_X_12;
                point_y = POINT_Y_12;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_12;
            end
            4'd13: begin
                valid = 1'b1;
                point_x = POINT_X_13;
                point_y = POINT_Y_13;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_13;
            end
            4'd14: begin
                valid = 1'b1;
                point_x = POINT_X_14;
                point_y = POINT_Y_14;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_14;
            end
            4'd15: begin
                valid = 1'b1;
                point_x = POINT_X_15;
                point_y = POINT_Y_15;
                point_z = POINT_Z_AFFINE;
                point_t = POINT_T_15;
            end
            default: begin
            end
        endcase
    end
endmodule
