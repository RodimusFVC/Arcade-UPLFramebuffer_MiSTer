//============================================================================
//
//  UPLFramebuffer_SPRITE.sv — sprite framebuffer engine.
//
//  Sprites render into a persistent 256x256 framebuffer rather than per scanline,
//  so disabling the clear leaves trails. Rendering runs during vblank. Contents are
//  {colour[3:0], pen[3:0]}; the video side adds the 0x100 sprite palette base and
//  pen 0xf marks empty. ninjakd2.cpp reference points:
//    draw_sprites()   — 96 16x16 sprites per frame, a big (32x32) one counting as 4,
//                       a disabled sprite still counting as 1
//    erase_sprites()  — clear to 0xf, or with overdraw only where the stencil hits
//    stencil_*        — ninjakd2 (pal&0xf0)==0xf0, robokid <0xe0, omegaf always true
//
//============================================================================

module UPLFramebuffer_SPRITE
(
    input               clk,
    input               reset,

    input               flip_screen,
    input               gfx_robokid,      // col-aligned gfx, swapped big-sprite quadrants, own stencil
    input               is_omegaf,        // stencil is unconditional -- overdraw clears everything
    input               overdraw,        // c203 bit0
    input               draw_window,     // high through the vblank rendering window

    // ---- sprite RAM: MAIN's work RAM, sprites at offset 0x1A00 (cpu 0xFA00)
    output       [12:0] spr_ram_addr,
    input         [7:0] spr_ram_data,

    // ---- sprite ROM (SDRAM, via upl_rom)
    output       [17:0] spr_addr,
    output              spr_req,
    input               spr_ack,
    input         [7:0] spr_data,

    // ---- framebuffer read port for the video side
    input        [15:0] fb_raddr,
    output        [7:0] fb_rdata,

    output              busy
);

    localparam [12:0] SPR_BASE = 13'h1A00;   // cpu 0xFA00 within the 0xE000 work RAM

    // Framebuffer: 256x256 pixels, FOUR PER 32-BIT WORD, so the clear pass walks
    // 16384 words not 65536 pixels while byte enables keep a single-pixel write at
    // one clock. The read port is shared by the video and the clear pass; they never
    // overlap because the clear only runs while the video is blanked.
    reg  [13:0] fb_waddr;
    reg  [31:0] fb_wdata;
    reg   [3:0] fb_wbe;
    reg         fb_we;

    reg  [13:0] erase_addr;
    wire [13:0] fb_baddr = draw_window ? erase_addr : fb_raddr[15:2];
    wire [31:0] fb_bq;

    // Overdraw stencil, evaluated per byte lane on the stored colour nibble.
    //   ninjakd2 / mnight / arkarea : (pal & 0xf0) == 0xf0  -> only colour 15 clears
    //   robokid                     : (pal & 0xf0) <  0xe0  -> 14 and 15 persist
    //   omegaf                      : always true            -> nothing persists
    wire st0 = is_omegaf ? 1'b1 : gfx_robokid ? (fb_bq[ 7: 4] < 4'hE) : (fb_bq[ 7: 4] == 4'hF);
    wire st1 = is_omegaf ? 1'b1 : gfx_robokid ? (fb_bq[15:12] < 4'hE) : (fb_bq[15:12] == 4'hF);
    wire st2 = is_omegaf ? 1'b1 : gfx_robokid ? (fb_bq[23:20] < 4'hE) : (fb_bq[23:20] == 4'hF);
    wire st3 = is_omegaf ? 1'b1 : gfx_robokid ? (fb_bq[31:28] < 4'hE) : (fb_bq[31:28] == 4'hF);

    // the byte select must lag the address by the BRAM's one clock
    reg [1:0] fb_rsel;
    always_ff @(posedge clk) fb_rsel <= fb_raddr[1:0];

    assign fb_rdata = (fb_rsel == 2'd0) ? fb_bq[7:0]
                    : (fb_rsel == 2'd1) ? fb_bq[15:8]
                    : (fb_rsel == 2'd2) ? fb_bq[23:16]
                                        : fb_bq[31:24];

    // Must be dpram_dc, not a reg array: Quartus 17.0 will not infer block RAM from
    // per-byte writes to `mem[a][7:0]` and builds a 16384:1 mux instead, blowing the
    // device. altsyncram's byteena is native and defaults to all-ones, so instances
    // that leave it unconnected are unaffected.
    dpram_dc #(.widthad_a(14), .width_a(32)) framebuffer
    (
        .clock_a(clk), .address_a(fb_waddr), .data_a(fb_wdata),
        .wren_a(fb_we), .byteena_a(fb_wbe), .q_a(),
        .clock_b(clk), .address_b(fb_baddr), .data_b(32'd0),
        .wren_b(1'b0), .q_b(fb_bq)
    );

    // Sprite record decode
    reg  [6:0] spr_idx;      // spriteram entry, 0..95
    reg  [6:0] drawn;        // sprites_drawn, the 96 budget
    reg  [7:0] b_sy, b_sxlo, b_ctrl, b_code, b_col;

    wire        e_enable = b_ctrl[1];
    wire        e_big    = b_ctrl[2];
    wire        e_flipx  = b_ctrl[4];
    wire        e_flipy  = b_ctrl[5];
    wire  [3:0] e_color  = b_col[3:0];
    // code = sprptr[3] | (bitswap<3>(sprptr[2],3,7,6) << 8)
    wire [10:0] e_code   = {b_ctrl[3], b_ctrl[7], b_ctrl[6], b_code};
    // sx = sprptr[1] - ((sprptr[2] & 1) << 8), so bit0 makes it negative
    wire signed [9:0] e_sx = {2'b00, b_sxlo} - {b_ctrl[0], 9'd0};
    wire signed [9:0] e_sy = {2'b00, b_sy};

    // screen flip mirrors the position and inverts both per-sprite flips
    wire signed [9:0] big_off = e_big ? 10'sd16 : 10'sd0;
    wire signed [9:0] f_sx = flip_screen ? (10'sd240 - big_off - e_sx) : e_sx;
    wire signed [9:0] f_sy = flip_screen ? (10'sd240 - big_off - e_sy) : e_sy;
    wire        f_flipx = e_flipx ^ flip_screen;
    wire        f_flipy = e_flipy ^ flip_screen;

    // Big sprites: code &= ~3 then xor in the quadrant.
    reg  [1:0] qx, qy;       // quadrant being drawn (0..big)
    // 11-bit code: ninjakd2 has 1024 tiles (bit10 unused), mnight/arkarea 1536.
    // robokid is m_robokid_sprites — big_xshift=1 / big_yshift=0, the opposite of
    // the ninjakd2 family, so bit1 is the horizontal half and bit0 the vertical.
    wire [1:0] flip_xor = gfx_robokid ? {f_flipx, f_flipy} : {f_flipy, f_flipx};
    wire [1:0] quad_xor = gfx_robokid ? {qx[0], qy[0]}     : {qy[0], qx[0]};
    wire [10:0] base_code = e_big ? {e_code[10:2], 2'b00} ^ {9'd0, flip_xor}
                                  :  e_code;
    wire [10:0] cur_code  = base_code ^ {9'd0, quad_xor};

    wire signed [9:0] cur_x0 = f_sx + (qx[0] ? 10'sd16 : 10'sd0);
    wire signed [9:0] cur_y0 = f_sy + (qy[0] ? 10'sd16 : 10'sd0);

    // Row fetch: 8 bytes = 16 pixels, same 2x2 sub-tile layout as the bg
    //   offset = ty[3]*64 + tx[3]*32 + ty[2:0]*4 + tx[2:1]
    reg  [3:0] row;          // 0..15 within the tile
    reg  [2:0] rj;           // ROM byte index, = tx[3:1]
    reg [63:0] rowbits;
    reg  [3:0] col;          // 0..15 while writing the row out

    wire [3:0] ty = f_flipy ? ~row : row;
    wire [3:0] tx = f_flipx ? ~col : col;

    reg  [17:0] spr_addr_r;
    reg         spr_req_r;
    assign spr_addr = spr_addr_r;
    assign spr_req  = spr_req_r;

    // 1024 tiles x 128 bytes = 0x20000, so the region address is 17 bits.
    // row_2x2 is 0 1 / 2 3, col_2x2 (robokid) is 0 2 / 1 3: the sub-tile bits swap.
    wire sub_hi = gfx_robokid ? rj[2] : ty[3];
    wire sub_lo = gfx_robokid ? ty[3] : rj[2];
    wire [17:0] rom_addr = {cur_code, sub_hi, sub_lo, ty[2:0], rj[1:0]};

    wire [5:0] pshift = {2'd0, ~tx} << 2;
    wire [3:0] pen    = (rowbits >> pshift) & 64'hF;

    wire signed [9:0] px = cur_x0 + {6'd0, col};
    wire signed [9:0] py = cur_y0 + {6'd0, row};
    wire in_frame = (px >= 0) && (px <= 10'sd255) && (py >= 0) && (py <= 10'sd255);

    // Engine
    localparam S_IDLE = 4'd0, S_ERASE = 4'd1, S_REC   = 4'd2, S_DECIDE = 4'd3,
               S_ROWREQ= 4'd4, S_ROWACK= 4'd5, S_WRITE = 4'd6, S_NEXTROW= 4'd7,
               S_NEXTQ = 4'd8, S_NEXTSP= 4'd9, S_DONE  = 4'd10;

    reg [3:0] st;
    reg [2:0] rec;
    reg       rec_ph;        // 0 = let the address settle, 1 = sample
    reg       dw_d;

    reg [13:0] er_prev;
    reg        er_pv;

    assign busy = (st != S_IDLE) && (st != S_DONE);

    // record byte address: 0x1A00 + idx*16 + 11 + rec
    assign spr_ram_addr = SPR_BASE + {2'd0, spr_idx, 4'd0} + 13'd11 + {10'd0, rec};

    always_ff @(posedge clk) begin
        fb_we <= 1'b0;
        dw_d  <= draw_window;

        if (reset) begin
            st <= S_IDLE; spr_req_r <= 1'b0; drawn <= 7'd0; spr_idx <= 7'd0; er_pv <= 1'b0;
        end else begin
            case (st)
                S_IDLE: if (draw_window && !dw_d) begin
                            erase_addr <= 14'd0;
                            er_pv      <= 1'b0;
                            st         <= S_ERASE;
                        end

                // One pixel per clock. The port B read lands one clock later and its
                // write is issued then, always behind the read pointer.
                S_ERASE: begin
                    er_prev <= erase_addr;
                    er_pv   <= 1'b1;
                    if (er_pv) begin
                        fb_waddr <= er_prev;
                        fb_wdata <= 32'h0F0F0F0F;
                        // No overdraw clears all four pixels; overdraw clears only the
                        // lanes the stencil hits, tested per byte.
                        fb_wbe   <= overdraw ? {st3, st2, st1, st0} : 4'b1111;
                        // never assert wren with no lane enabled
                        fb_we    <= overdraw ? |{st3, st2, st1, st0} : 1'b1;
                    end
                    if (er_pv && (er_prev == 14'h3FFF)) begin
                        spr_idx <= 7'd0; drawn <= 7'd0; rec <= 3'd0; rec_ph <= 1'b0;
                        st <= S_REC;
                    end else begin
                        erase_addr <= erase_addr + 14'd1;
                    end
                end

                // 5 used bytes of the record, one settling clock each for BRAM latency
                S_REC: begin
                    if (!rec_ph) rec_ph <= 1'b1;
                    else begin
                        case (rec)
                            3'd0: b_sy   <= spr_ram_data;
                            3'd1: b_sxlo <= spr_ram_data;
                            3'd2: b_ctrl <= spr_ram_data;
                            3'd3: b_code <= spr_ram_data;
                            default: b_col <= spr_ram_data;
                        endcase
                        rec_ph <= 1'b0;
                        if (rec == 3'd4) st  <= S_DECIDE;
                        else             rec <= rec + 3'd1;
                    end
                end

                S_DECIDE: begin
                    qx <= 2'd0; qy <= 2'd0; row <= 4'd0; rj <= 3'd0;
                    if (!e_enable) begin
                        // a disabled sprite still consumes one of the 96 slots
                        drawn <= drawn + 7'd1;
                        st <= (drawn == 7'd95) ? S_DONE : S_NEXTSP;
                    end else st <= S_ROWREQ;
                end

                S_ROWREQ: begin spr_addr_r <= rom_addr; spr_req_r <= 1'b1; st <= S_ROWACK; end
                S_ROWACK: if (spr_ack) begin
                              rowbits   <= {rowbits[55:0], spr_data};
                              spr_req_r <= 1'b0;
                              if (rj == 3'd7) begin col <= 4'd0; st <= S_WRITE; end
                              else begin rj <= rj + 3'd1; st <= S_ROWREQ; end
                          end

                S_WRITE: begin
                    // transpen: pen 0xf is transparent and never written
                    if (in_frame && (pen != 4'hF)) begin
                        fb_waddr <= {py[7:0], px[7:2]};
                        fb_wdata <= {4{{e_color, pen}}};
                        fb_wbe   <= 4'b0001 << px[1:0];
                        fb_we    <= 1'b1;
                    end
                    if (col == 4'd15) st  <= S_NEXTROW;
                    else              col <= col + 4'd1;
                end

                S_NEXTROW: begin
                    rj <= 3'd0;
                    if (row == 4'd15) st <= S_NEXTQ;
                    else begin row <= row + 4'd1; st <= S_ROWREQ; end
                end

                // each 16x16 quadrant drawn counts against the 96 budget;
                // MAME's quadrant order is x inner, y outer
                S_NEXTQ: begin
                    row <= 4'd0; rj <= 3'd0;
                    drawn <= drawn + 7'd1;
                    if (drawn == 7'd95)                   st <= S_DONE;
                    else if (!e_big)                      st <= S_NEXTSP;
                    else if (qx == 2'd0)                  begin qx <= 2'd1; st <= S_ROWREQ; end
                    else if (qy == 2'd0)                  begin qx <= 2'd0; qy <= 2'd1; st <= S_ROWREQ; end
                    else                                  st <= S_NEXTSP;
                end

                S_NEXTSP: if (spr_idx == 7'd95) st <= S_DONE;
                          else begin
                              spr_idx <= spr_idx + 7'd1;
                              rec <= 3'd0; rec_ph <= 1'b0;
                              st  <= S_REC;
                          end

                S_DONE: if (!draw_window) st <= S_IDLE;

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
