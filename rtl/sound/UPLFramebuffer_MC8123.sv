//============================================================================
//
//  UPLFramebuffer_MC8123.sv - NEC MC-8123 sound CPU decryption, IN FLIGHT.
//
//  Transcribed from MAME src/devices/cpu/z80/mc8123.cpp (decrypt_internal and the
//  eight decrypt_typeN networks). Purely combinational: type/swap/param fall out of
//  XORs of the key byte, then one of eight bitswap-and-XOR chains selects the result.
//
//  Decryption runs on every sound-CPU fetch rather than once at load. `opcode` is the
//  CPU's M1 and selects the opcode key table over the data table, so the same ROM byte
//  decrypts two ways depending on how it is fetched.
//
//  Used by set_id 00 / 03 / 04 / 05 (ninjakd2, ninjakd2c, rdaction, jt104).
//  Sets 01 / 02 are bootlegs that ship a plain decrypted opcode ROM instead.
//
//============================================================================

module UPLFramebuffer_MC8123
(
    input        [7:0] val,        // byte as stored in the encrypted ROM
    input        [7:0] key,        // key[tbl_num | (opcode ? 0x0000 : 0x1000)]
    input              opcode,     // M1: opcode fetch selects the other key table
    output       [7:0] dec
);

    function automatic [7:0] t0(input [7:0] val, input [3:0] param, input [1:0] swap);
        reg [7:0] v;
        begin
            v = val;
            case (swap)
                2'd0: v = {v[7], v[5], v[3], v[1], v[2], v[0], v[6], v[4]};
                2'd1: v = {v[5], v[3], v[7], v[2], v[1], v[0], v[4], v[6]};
                2'd2: v = {v[0], v[3], v[4], v[6], v[7], v[1], v[5], v[2]};
                2'd3: v = {v[0], v[7], v[3], v[2], v[6], v[4], v[1], v[5]};
            endcase
            if (param[3] && v[7]) v = v ^ 8'h29;
            if (param[2] && v[6]) v = v ^ 8'h86;
            if (v[6]) v = v ^ 8'h80;
            if (param[1] && v[7]) v = v ^ 8'h40;
            if (v[2]) v = v ^ 8'h21;
            v = v ^ 8'h1A;
            if (param[2]) v = v ^ 8'h25;
            if (param[1]) v = v ^ 8'hC0;
            if (param[0]) v = v ^ 8'h21;
            if (param[0]) v = {v[7], v[6], v[5], v[1], v[4], v[3], v[2], v[0]};
            t0 = v;
        end
    endfunction

    function automatic [7:0] t1a(input [7:0] val, input [3:0] param, input [1:0] swap);
        reg [7:0] v;
        begin
            v = val;
            case (swap)
                2'd0: v = {v[4], v[2], v[6], v[5], v[3], v[7], v[1], v[0]};
                2'd1: v = {v[6], v[0], v[5], v[4], v[3], v[2], v[1], v[7]};
                2'd2: v = {v[2], v[3], v[6], v[1], v[4], v[0], v[7], v[5]};
                2'd3: v = {v[6], v[5], v[1], v[3], v[2], v[7], v[0], v[4]};
            endcase
            if (param[2]) v = {v[7], v[6], v[1], v[5], v[3], v[2], v[4], v[0]};
            if (v[1]) v = v ^ 8'h01;
            if (v[6]) v = v ^ 8'h08;
            if (v[7]) v = v ^ 8'h48;
            if (v[2]) v = v ^ 8'h4A;
            if (v[4]) v = v ^ 8'hC4;
            if (v[7] ^ v[2]) v = v ^ 8'h10;
            v = v ^ 8'h4B;
            if (param[3]) v = v ^ 8'h84;
            if (param[1]) v = v ^ 8'h48;
            if (param[0]) v = {v[7], v[6], v[1], v[4], v[3], v[2], v[5], v[0]};
            t1a = v;
        end
    endfunction

    function automatic [7:0] t1b(input [7:0] val, input [3:0] param, input [1:0] swap);
        reg [7:0] v;
        begin
            v = val;
            case (swap)
                2'd0: v = {v[1], v[0], v[3], v[2], v[5], v[6], v[4], v[7]};
                2'd1: v = {v[2], v[0], v[5], v[1], v[7], v[4], v[6], v[3]};
                2'd2: v = {v[6], v[4], v[7], v[2], v[0], v[5], v[1], v[3]};
                2'd3: v = {v[7], v[1], v[3], v[6], v[0], v[2], v[5], v[4]};
            endcase
            if (v[2] && v[0]) v = v ^ 8'h90;
            if (v[7]) v = v ^ 8'h04;
            if (v[5]) v = v ^ 8'h84;
            if (v[1]) v = v ^ 8'h20;
            if (v[6]) v = v ^ 8'h02;
            if (v[4]) v = v ^ 8'h60;
            if (v[0]) v = v ^ 8'h46;
            if (v[3]) v = v ^ 8'hC7;
            v = v ^ 8'h51;
            if (param[3]) v = v ^ 8'h12;
            if (param[2]) v = v ^ 8'hC9;
            if (param[1]) v = v ^ 8'h18;
            if (param[0]) v = v ^ 8'h47;
            t1b = v;
        end
    endfunction

    function automatic [7:0] t2a(input [7:0] val, input [3:0] param, input [1:0] swap);
        reg [7:0] v;
        begin
            v = val;
            case (swap)
                2'd0: v = {v[0], v[1], v[4], v[3], v[5], v[6], v[2], v[7]};
                2'd1: v = {v[6], v[3], v[0], v[5], v[7], v[4], v[1], v[2]};
                2'd2: v = {v[1], v[6], v[4], v[5], v[0], v[3], v[7], v[2]};
                2'd3: v = {v[4], v[6], v[7], v[5], v[2], v[3], v[1], v[0]};
            endcase
            if (v[3] || (param[1] && v[2])) v = {v[6], v[0], v[7], v[4], v[3], v[2], v[1], v[5]};
            if (v[5]) v = v ^ 8'h80;
            if (v[6]) v = v ^ 8'h20;
            if (v[0]) v = v ^ 8'h40;
            if (v[4]) v = v ^ 8'h09;
            if (v[1]) v = v ^ 8'h04;
            v = v ^ 8'hF2;
            if (param[2]) v = v ^ 8'h1F;
            if (param[3]) begin
                if (param[0]) v = {v[7], v[6], v[5], v[3], v[4], v[1], v[2], v[0]};
                else          v = {v[7], v[6], v[5], v[1], v[2], v[4], v[3], v[0]};
            end else if (param[0]) begin
                v = {v[7], v[6], v[5], v[2], v[1], v[3], v[4], v[0]};
            end
            t2a = v;
        end
    endfunction

    function automatic [7:0] t2b(input [7:0] val, input [3:0] param, input [1:0] swap);
        reg [7:0] v;
        begin
            v = val;
            case (swap)
                2'd0: v = {v[1], v[3], v[4], v[6], v[5], v[7], v[0], v[2]};
                2'd1: v = {v[0], v[1], v[5], v[4], v[7], v[3], v[2], v[6]};
                2'd2: v = {v[3], v[5], v[4], v[1], v[6], v[2], v[0], v[7]};
                2'd3: v = {v[5], v[2], v[3], v[0], v[4], v[7], v[6], v[1]};
            endcase
            if (v[7] && v[3]) v = v ^ 8'h51;
            if (v[7]) v = v ^ 8'h04;
            if (v[5]) v = v ^ 8'h88;
            if (v[1]) v = v ^ 8'h20;
            if (v[4]) v = v ^ 8'hAA;
            if (v[7] && v[5]) v = v ^ 8'h11;
            if (v[5] && v[1]) v = v ^ 8'h11;
            if (v[6]) v = v ^ 8'hA0;
            if (v[3]) v = v ^ 8'hE2;
            if (v[2]) v = v ^ 8'h0A;
            v = v ^ 8'h8E;
            if (param[3]) v = v ^ 8'h4A;
            if (param[2]) v = v ^ 8'hEE;   // same as the other three combined
            if (param[1]) v = v ^ 8'h80;
            if (param[0]) v = v ^ 8'h24;
            t2b = v;
        end
    endfunction

    function automatic [7:0] t3a(input [7:0] val, input [3:0] param, input [1:0] swap);
        reg [7:0] v;
        begin
            v = val;
            case (swap)
                2'd0: v = {v[5], v[3], v[1], v[7], v[0], v[2], v[6], v[4]};
                2'd1: v = {v[3], v[1], v[2], v[5], v[4], v[7], v[0], v[6]};
                2'd2: v = {v[5], v[6], v[1], v[2], v[7], v[0], v[4], v[3]};
                2'd3: v = {v[5], v[6], v[7], v[0], v[4], v[2], v[1], v[3]};
            endcase
            if (v[2]) v = v ^ 8'hB0;
            if (v[3]) v = v ^ 8'h01;
            if (param[0]) v = {v[7], v[2], v[5], v[4], v[3], v[1], v[0], v[6]};
            if (v[1]) v = v ^ 8'h41;
            if (v[3]) v = v ^ 8'h16;
            if (param[3]) v = v ^ 8'h18;
            if (v[3]) v = {v[5], v[6], v[7], v[4], v[3], v[2], v[1], v[0]};
            if (v[5]) v = v ^ 8'h06;
            v = v ^ 8'h78;
            if (param[2]) v = v ^ 8'h80;
            if (param[1]) v = v ^ 8'h10;
            if (param[0]) v = v ^ 8'h01;
            t3a = v;
        end
    endfunction

    function automatic [7:0] t3b(input [7:0] val, input [3:0] param, input [1:0] swap);
        reg [7:0] v;
        begin
            v = val;
            case (swap)
                2'd0: v = {v[3], v[7], v[5], v[4], v[0], v[6], v[2], v[1]};
                2'd1: v = {v[7], v[5], v[4], v[6], v[1], v[2], v[0], v[3]};
                2'd2: v = {v[7], v[4], v[3], v[0], v[5], v[1], v[6], v[2]};
                2'd3: v = {v[2], v[6], v[4], v[1], v[3], v[7], v[0], v[5]};
            endcase
            if (v[2]) v = v ^ 8'h80;
            if (v[7]) v = {v[7], v[6], v[3], v[4], v[5], v[2], v[1], v[0]};
            if (param[3]) v = v ^ 8'h80;
            if (v[4]) v = v ^ 8'h40;
            if (v[1]) v = v ^ 8'h54;
            if (v[7] && v[6]) v = v ^ 8'h02;
            if (v[7]) v = v ^ 8'h02;
            if (param[3]) v = v ^ 8'h80;
            if (param[2]) v = v ^ 8'h01;
            if (param[3]) v = {v[4], v[6], v[3], v[2], v[5], v[0], v[1], v[7]};
            if (v[4]) v = v ^ 8'h02;
            if (v[5]) v = v ^ 8'h10;
            if (v[7]) v = v ^ 8'h04;
            v = v ^ 8'h2C;
            if (param[1]) v = v ^ 8'h80;
            if (param[0]) v = v ^ 8'h08;
            t3b = v;
        end
    endfunction

    // The key is inverted first; an inverted-zero key (original 0xFF) means the byte
    // is not encrypted.
    wire [7:0] k = ~key;

    wire [2:0] ktype = {k[4] ^ k[5],
                        k[0] ^ k[1] ^ k[2] ^ k[4],
                        k[0] ^ k[2]};
    wire [1:0] kswap = {k[2] ^ k[3], k[0] ^ k[1]};
    wire [3:0] kparam = {k[1] ^ k[6] ^ k[7],
                         k[0] ^ k[1] ^ k[6],
                         k[0] ^ k[2] ^ k[3],
                         k[0]};

    // a data fetch flips type bit 0 and param bit 0
    wire [2:0] t = {ktype[2:1],  ktype[0]  ^ ~opcode};
    wire [3:0] p = {kparam[3:1], kparam[0] ^ ~opcode};

    reg [7:0] r;
    always_comb begin
        case (t)
            3'd0, 3'd1: r = t0(val, p, kswap);
            3'd2:       r = t1a(val, p, kswap);
            3'd3:       r = t1b(val, p, kswap);
            3'd4:       r = t2a(val, p, kswap);
            3'd5:       r = t2b(val, p, kswap);
            3'd6:       r = t3a(val, p, kswap);
            default:    r = t3b(val, p, kswap);
        endcase
    end

    assign dec = (k == 8'h00) ? val : r;

endmodule
