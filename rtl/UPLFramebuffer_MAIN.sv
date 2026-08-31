//============================================================================
//
//  UPLFramebuffer_MAIN.sv — main Z80 board: memory map, ROM banking, control
//  registers, video RAMs and the vblank IRQ.
//  Map from ninjakd2.cpp:1010 (ninjakd2_main_cpu).
//
//============================================================================

module UPLFramebuffer_MAIN
(
    input                clk,
    input                cen_cpu,        // 6.0 MHz enable (main Z80)
    input                reset,
    input                pause,

    input          [7:0] set_id,

    // ---- controls, assembled into MAME port order by the wrapper (active low)
    input          [7:0] keycoin,        // C000
    input          [7:0] pad1,           // C001
    input          [7:0] pad2,           // C002
    input          [7:0] dsw1,           // C003
    input          [7:0] dsw2,           // C004

    // ---- main CPU ROM
    output        [15:0] maincpu_addr,
    output         [3:0] maincpu_bank,
    input          [7:0] maincpu_data,

    // ---- sound board
    output         [7:0] sound_latch,
    output               sound_latch_wr,
    output               snd_reset,

    // ---- video control
    input                crt_flip,       // OSD CRT Flip, XORed into flip_screen
    output               flip_screen,
    output               sprite_overdraw,
    output        [15:0] bg_scrollx,
    output        [15:0] bg_scrolly,
    output               bg_enable,

    // ---- video-side read ports
    input         [10:0] fg_vram_addr,   output  [7:0] fg_vram_data,
    input         [10:0] bg_vram_addr,   output  [7:0] bg_vram_data,
    input         [12:0] work_addr,      output  [7:0] work_data,   // sprite RAM lives at 1A00-1FFF
    input          [9:0] pal_index,      output [15:0] pal_rgb,

    input                vblank             // from VIDEO; rising edge raises the IRQ
);

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n;

    wire mem_wr = ~mreq_n & ~wr_n;
    wire int_ack = ~m1_n & ~iorq_n;

    //-------------------------------------------------------------------------
    // Address decode. ninjakd2 (ninjakd2.cpp:1026) and mnight (:1047) relocate
    // every region, but the control-register and input low-byte offsets are the
    // same in both and each block stays zero-based at the same bit slice, so
    // only the chip selects differ. Sprite RAM sits at work+0x1A00 either way.
    //-------------------------------------------------------------------------
    wire is_mnight  = (set_id >= 8'h06) && (set_id <= 8'h08);  // mnight/mnightj/arkarea
    wire is_robokid = (set_id >= 8'h09) && (set_id <= 8'h0C);  // robokid + 3 japan sets

    wire cs_rom   = (A[15] == 1'b0);                       // 0000-7FFF fixed
    wire cs_bank  = (A[15:14] == 2'b10);                   // 8000-BFFF banked

    // robokid reads inputs and writes control at the SAME addresses (DC00-DC04);
    // cs_in only feeds the read mux and cs_ctrl only gates writes, so both assert.
    wire cs_in    = is_robokid ? ((A[15:8] == 8'hDC) && (A[7:0] < 8'd5))   // DC00-DC04
                  : is_mnight  ? ((A[15:8] == 8'hF8) && (A[7:0] < 8'd5))   // F800-F804
                               : ((A[15:8] == 8'hC0) && (A[7:0] < 8'd5));  // C000-C004
    wire cs_ctrl  = is_robokid ? (A[15:8] == 8'hDC)                        // DC00-DC03
                  : is_mnight  ? (A[15:8] == 8'hFA)                        // FA00-FA0C
                               : (A[15:8] == 8'hC2);                       // C200-C20C
    wire cs_pal   = is_robokid ? ((A >= 16'hC000) && (A < 16'hC800))       // C000-C7FF
                  : is_mnight  ? ((A >= 16'hF000) && (A < 16'hF600))       // F000-F5FF
                               : ((A >= 16'hC800) && (A < 16'hCE00));      // C800-CDFF
    wire cs_fg    = is_robokid ? (A[15:11] == 5'b11001)                    // C800-CFFF
                  : is_mnight  ? (A[15:11] == 5'b11101)                    // E800-EFFF
                               : (A[15:11] == 5'b11010);                   // D000-D7FF
    wire cs_bg    = is_robokid ? 1'b0                                      // banked, see cs_bgb
                  : is_mnight  ? (A[15:11] == 5'b11100)                    // E000-E7FF
                               : (A[15:11] == 5'b11011);                   // D800-DFFF
    wire cs_work  = is_mnight  ? (A[15:13] == 3'b110)                      // C000-DFFF
                               : (A[15:13] == 3'b111);                     // E000-FFFF (also robokid)

    // robokid's three banked bg VRAM windows, D000-D3FF / D400-D7FF / D800-DBFF.
    // Storage only -- nothing renders these yet, but the CPU must read back what it
    // wrote or the boot test fails. 0x800 per layer, one bank bit (video_init_banked(0x800)).
    wire cs_bgb   = is_robokid && (A[15:12] == 4'hD) && (A[11:10] != 2'b11);

    // robokid bg control: DD00-DD05 layer0, DE00-DE05 layer1, DF00-DF05 layer2.
    // Only the +05 bank register is implemented; scroll/enable are ignored for now.
    wire cs_bgctl = is_robokid && (A[15:10] == 6'b110111) && (A[9:8] != 2'b00);

    assign maincpu_addr = A;

    //-------------------------------------------------------------------------
    // Control registers.
    //   +00 soundlatch    +01 bit4 sound reset / bit7 flip screen
    //   +02 bank select   +03 bit0 sprite overdraw   +08..+0C bg scroll+enable
    //   base C200 on ninjakd2, FA00 on mnight/arkarea - offsets are identical.
    //-------------------------------------------------------------------------
    reg  [3:0] bank_reg    = 4'd0;
    reg        flip_reg    = 1'b0;
    reg        sndrst_reg  = 1'b0;
    reg        overdraw    = 1'b0;
    reg [15:0] scrollx     = 16'd0;
    reg [15:0] scrolly     = 16'd0;
    reg        bgen        = 1'b1;
    reg  [7:0] latch_reg   = 8'd0;
    reg        latch_wr    = 1'b0;
    reg  [2:0] bgbank      = 3'd0;   // robokid: one bank bit per bg layer

    // robokid/omegaf have a 0x50000 main ROM region (16 banks); the ninjakd2,
    // mnight and arkarea boards have 0x30000 (8 banks). MAME derives the mask
    // from the region size in machine_start (ninjakd2.cpp:1521).
    wire [3:0] bank_mask = (set_id >= 8'h09) ? 4'hF : 4'h7;

    wire ctrl_wr = cen_cpu & mem_wr & cs_ctrl;

    always_ff @(posedge clk) begin
        latch_wr <= 1'b0;
        if (reset) begin
            bank_reg <= 4'd0; flip_reg <= 1'b0; sndrst_reg <= 1'b0;
            overdraw <= 1'b0; bgen <= 1'b1; bgbank <= 3'd0;
        end else if (cen_cpu && mem_wr && cs_bgctl && (A[7:0] == 8'h05)) begin
            case (A[9:8])                            // DD05/DE05/DF05 -> layer 0/1/2
                2'd1: bgbank[0] <= cpu_dout[0];
                2'd2: bgbank[1] <= cpu_dout[0];
                default: bgbank[2] <= cpu_dout[0];
            endcase
        end else if (ctrl_wr) begin
            case (A[7:0])
                8'h00: begin latch_reg <= cpu_dout; latch_wr <= 1'b1; end
                8'h01: begin sndrst_reg <= cpu_dout[4]; flip_reg <= cpu_dout[7]; end
                8'h02: bank_reg <= cpu_dout[3:0] & bank_mask;
                8'h03: overdraw <= cpu_dout[0];
                8'h08: scrollx[7:0]  <= cpu_dout;
                8'h09: scrollx[15:8] <= cpu_dout;
                8'h0A: scrolly[7:0]  <= cpu_dout;
                8'h0B: scrolly[15:8] <= cpu_dout;
                8'h0C: bgen <= cpu_dout[0];
                default: ;
            endcase
        end
    end

    assign maincpu_bank    = bank_reg;
    assign sound_latch     = latch_reg;
    assign sound_latch_wr  = latch_wr;
    assign snd_reset       = sndrst_reg;
    assign flip_screen     = flip_reg ^ crt_flip;
    assign sprite_overdraw = overdraw;
    assign bg_scrollx      = scrollx;
    assign bg_scrolly      = scrolly;
    assign bg_enable       = bgen;

    //-------------------------------------------------------------------------
    // Palette RAM — 0x300 entries x 16 bit, big-endian bytes (RGBx_444).
    // Even byte address is the MSB, so byteena picks the high lane there.
    //-------------------------------------------------------------------------
    wire [9:0]  pal_ent  = A[10:1];
    wire        pal_wr   = cen_cpu & mem_wr & cs_pal;
    wire [15:0] pal_q_a;

    dpram_dc #(.widthad_a(10), .width_a(16)) palette_ram
    (
        .clock_a(clk), .address_a(pal_ent),
        .data_a({cpu_dout, cpu_dout}),
        .byteena_a(A[0] ? 2'b01 : 2'b10),
        .wren_a(pal_wr), .q_a(pal_q_a),
        .clock_b(clk), .address_b(pal_index),
        .data_b(16'd0), .wren_b(1'b0), .q_b(pal_rgb)
    );

    //-------------------------------------------------------------------------
    // Tilemap RAMs and work RAM. FA00-FFFF inside the work RAM is the sprite
    // list, which the video side reads through work_addr.
    //-------------------------------------------------------------------------
    wire [7:0] fg_q_a, bg_q_a, work_q_a;

    dpram_dc #(.widthad_a(11), .width_a(8)) fg_ram
    (
        .clock_a(clk), .address_a(A[10:0]), .data_a(cpu_dout),
        .wren_a(cen_cpu & mem_wr & cs_fg), .q_a(fg_q_a),
        .clock_b(clk), .address_b(fg_vram_addr), .data_b(8'd0), .wren_b(1'b0), .q_b(fg_vram_data)
    );

    dpram_dc #(.widthad_a(11), .width_a(8)) bg_ram
    (
        .clock_a(clk), .address_a(A[10:0]), .data_a(cpu_dout),
        .wren_a(cen_cpu & mem_wr & cs_bg), .q_a(bg_q_a),
        .clock_b(clk), .address_b(bg_vram_addr), .data_b(8'd0), .wren_b(1'b0), .q_b(bg_vram_data)
    );

    // D000->layer2, D400->layer1, D800->layer0 (window order is reversed vs the
    // DD/DE/DF control order), so pick the bank register accordingly.
    wire [1:0]  bgb_win  = A[11:10];
    wire        bgb_sel  = (bgb_win == 2'd0) ? bgbank[2]
                         : (bgb_win == 2'd1) ? bgbank[1] : bgbank[0];
    wire [12:0] bgb_addr = {bgb_win, bgb_sel, A[9:0]};
    wire  [7:0] bgb_q_a;

    dpram_dc #(.widthad_a(13), .width_a(8)) bgbank_ram
    (
        .clock_a(clk), .address_a(bgb_addr), .data_a(cpu_dout),
        .wren_a(cen_cpu & mem_wr & cs_bgb), .q_a(bgb_q_a),
        .clock_b(clk), .address_b(13'd0), .data_b(8'd0), .wren_b(1'b0), .q_b()
    );

    dpram_dc #(.widthad_a(13), .width_a(8)) work_ram
    (
        .clock_a(clk), .address_a(A[12:0]), .data_a(cpu_dout),
        .wren_a(cen_cpu & mem_wr & cs_work), .q_a(work_q_a),
        .clock_b(clk), .address_b(work_addr), .data_b(8'd0), .wren_b(1'b0), .q_b(work_data)
    );

    //-------------------------------------------------------------------------
    // vblank IRQ. MAME asserts HOLD_LINE on the rising edge of vblank and the
    // acknowledge returns 0xD7 = RST 10h (ninjakd2.cpp:775, :780).
    //-------------------------------------------------------------------------
    reg vbl_d = 1'b0;
    reg irq_pending = 1'b0;

    always_ff @(posedge clk) begin
        vbl_d <= vblank;
        if (reset)                        irq_pending <= 1'b0;
        else if (vblank && !vbl_d)        irq_pending <= 1'b1;
        else if (cen_cpu && int_ack)      irq_pending <= 1'b0;
    end

    //-------------------------------------------------------------------------
    // CPU read mux + Z80
    //-------------------------------------------------------------------------
    reg [7:0] cpu_din;

    always_comb begin
        if      (int_ack)  cpu_din = 8'hD7;                 // RST 10h vector
        else if (cs_rom)   cpu_din = maincpu_data;
        else if (cs_bank)  cpu_din = maincpu_data;
        else if (cs_in)    cpu_din = (A[2:0] == 3'd0) ? keycoin :
                                     (A[2:0] == 3'd1) ? pad1    :
                                     (A[2:0] == 3'd2) ? pad2    :
                                     (A[2:0] == 3'd3) ? dsw1    : dsw2;
        else if (cs_pal)   cpu_din = A[0] ? pal_q_a[7:0] : pal_q_a[15:8];
        else if (cs_fg)    cpu_din = fg_q_a;
        else if (cs_bg)    cpu_din = bg_q_a;
        else if (cs_bgb)   cpu_din = bgb_q_a;
        else if (cs_work)  cpu_din = work_q_a;
        else               cpu_din = 8'hFF;
    end

    T80s cpu
    (
        .RESET_n(~reset),
        .CLK(clk),
        .CEN(cen_cpu & ~pause),
        .WAIT_n(1'b1),
        .INT_n(~irq_pending),
        .NMI_n(1'b1),
        .BUSRQ_n(1'b1),
        .M1_n(m1_n),
        .MREQ_n(mreq_n),
        .IORQ_n(iorq_n),
        .RD_n(rd_n),
        .WR_n(wr_n),
        .A(A),
        .DI(cpu_din),
        .DO(cpu_dout)
    );

endmodule
