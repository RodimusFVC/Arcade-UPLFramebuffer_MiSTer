//============================================================================
//
//  ChampionBaseball_VIDEO.sv — 32x32 tilemap of 8x8 tiles plus 8 hardware
//  sprites, palette PROM decode, and the line buffer.
//  Tilemap and sprites are snapshotted together once per frame (vsnap) so
//  both scan out with the same one-frame delay.
//
//============================================================================

module ChampionBaseball_VIDEO
(
    input               clk,             // video clock
    input               cen_pix,         // pixel clock enable (target 6.144 MHz)
    input               reset,

    // ---- CPU port into tile RAM (0x8000-0x87FF, 2KB: 0x000-0x3FF codes, 0x400-0x7FF attrs)
    input       [10:0]  cpu_vram_addr,
    input        [7:0]  cpu_vram_din,
    input               cpu_vram_we,
    output       [7:0]  cpu_vram_dout,

    // ---- control bits from the LS259 mainlatch (champbas.cpp:970-978)
    input               flip_screen,     // latch bit 3, ALREADY de-inverted by the caller

    // it to latch its sprite position/attribute arrays at the SAME instant this
    output              vsnap,
    input               gfx_bank,        // latch bit 2
    input               palette_bank,    // latch bit 4

    // ---- hardware variant. exctsccr family (set_id 0x08-0x0A) differs in the
    input               is_exctsccr,
    input               is_talbot,       // set_id 0x07 — half-size gfx regions

    // ---- gfx ROM port (champbas_rom index 2 region, 16KB)
    output      [13:0]  gfx_addr,
    input        [7:0]  gfx_data,

    // ---- gfx plane-2 source (champbas_rom index 8) — exctsccr only.
    output      [12:0]  gfx_p3_addr,
    input        [7:0]  gfx_p3_data,

    // ---- colour LUT PROM port (champbas_rom index 7 region; LUT lives at 0x020-0x11F)
    output       [9:0]  prom_addr,
    input        [7:0]  prom_data,

    // ---- sprite sources. champbas splits them across TWO memories:
    //   code/colour/flip in MAIN RAM 0x8FF0-0x8FFF   (champbas.cpp:395-403)
    output       [3:0]  spr_pos_addr,
    output              spr_pos_bank,   // 0 = spriteram $A060, 1 = spriteram2 $A040
    input        [7:0]  spr_pos_data,
    output       [3:0]  spr_attr_addr,
    input        [7:0]  spr_attr_data,

    // ---- exctsccr 4bpp sprite gfx (champbas_rom index 9)
    output      [12:0]  gfx3_addr,
    input        [7:0]  gfx3_data,

    // ---- palette PROM snoop (see PALETTE PROM note below)
    input               clk_dl,
    input               ioctl_download,
    input        [7:0]  ioctl_index,
    input       [24:0]  ioctl_addr,
    input        [7:0]  ioctl_data,
    input               ioctl_wr,

    // ---- video out
    output       [7:0]  VGA_R,
    output       [7:0]  VGA_G,
    output       [7:0]  VGA_B,
    output              HSync,
    output              VSync,
    output              HBlank,
    output              VBlank
);

    ////////////////////////////////////////////////////////////////////////
    // Video timing
    //   384 x 264   ->  6.144e6/384 = 16.0 kHz H,  16000/264 = 60.6 Hz V
    ////////////////////////////////////////////////////////////////////////

    localparam H_TOTAL   = 9'd384;
    localparam H_VIS     = 9'd256;
    localparam HS_START  = 9'd272;
    localparam HS_END    = 9'd304;

    localparam V_TOTAL   = 9'd264;
    localparam V_VIS_LO  = 9'd16;    // first visible line  (MAME visarea min_y)
    localparam V_VIS_HI  = 9'd240;   // one past last        (MAME visarea max_y = 239)
    localparam VS_START  = 9'd244;
    localparam VS_END    = 9'd248;

    reg [8:0] h_cnt = 9'd0;
    reg [8:0] v_cnt = 9'd0;

    always_ff @(posedge clk) begin
        if (reset) begin
            h_cnt <= 9'd0;
            v_cnt <= 9'd0;
        end else if (cen_pix) begin
            if (h_cnt == H_TOTAL - 9'd1) begin
                h_cnt <= 9'd0;
                v_cnt <= (v_cnt == V_TOTAL - 9'd1) ? 9'd0 : v_cnt + 9'd1;
            end else begin
                h_cnt <= h_cnt + 9'd1;
            end
        end
    end

    wire hblk = (h_cnt >= H_VIS);
    wire vblk = (v_cnt < V_VIS_LO) || (v_cnt >= V_VIS_HI);

    assign HBlank = hblk;
    assign VBlank = vblk;
    assign HSync  = (h_cnt >= HS_START) && (h_cnt < HS_END);
    assign VSync  = (v_cnt >= VS_START) && (v_cnt < VS_END);

    ////////////////////////////////////////////////////////////////////////
    // Screen -> world coordinates
    // champbas has no scroll, so world coords ARE screen coords; flip is a
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] h_raw = h_cnt[7:0];
    wire [7:0] v_raw = v_cnt[7:0];

    wire [7:0] sx = h_raw ^ {8{flip_screen}};
    wire [7:0] sy = v_raw ^ {8{flip_screen}};

    wire [4:0] tile_col = sx[7:3];
    wire [4:0] tile_row = sy[7:3];
    wire [2:0] fx       = sx[2:0];
    wire [2:0] fy       = sy[2:0];

    ////////////////////////////////////////////////////////////////////////
    // Tile RAM  (0x8000-0x87FF)
    // 0x000-0x3FF = tile codes, 0x400-0x7FF = per-tile colour attributes
    ////////////////////////////////////////////////////////////////////////

    reg  [10:0] vram_raddr;
    wire  [7:0] vram_rdata;
    wire [10:0] vram_addr_mux;

    ////////////////////////////////////////////////////////////////////////
    // ACTIVE DISPLAY (42326 vs 34543 in blanking). The board has NO scroll
    ////////////////////////////////////////////////////////////////////////

    // Snapshot late in vblank (active starts at v_cnt 16) so the copy captures
    wire       snap_trig = (v_cnt == 9'd12) && (h_cnt == 9'd0);
    reg        snap_d;
    always_ff @(posedge clk) snap_d <= snap_trig;
    wire       snap_pulse = snap_trig & ~snap_d;
    assign     vsnap = snap_pulse;

    reg [11:0] cp_cnt;
    reg        cp_run;
    reg [10:0] cp_addr_d;
    reg        cp_we_d;
    wire [7:0] cp_data;

    always_ff @(posedge clk) begin
        if (snap_pulse) begin
            cp_cnt <= 12'd0;
            cp_run <= 1'b1;
        end else if (cp_run) begin
            if (cp_cnt == 12'd2047) cp_run <= 1'b0;
            cp_cnt <= cp_cnt + 12'd1;
        end
        // dpram_dc q is registered: data for the address issued this cycle
        cp_addr_d <= cp_cnt[10:0];
        cp_we_d   <= cp_run;
    end

    dpram_dc #(.widthad_a(11), .width_a(8)) tile_ram
    (
        .clock_a(clk),
        .address_a(cpu_vram_addr),
        .data_a(cpu_vram_din),
        .wren_a(cpu_vram_we),
        .q_a(cpu_vram_dout),

        .clock_b(clk),
        .address_b(cp_cnt[10:0]),
        .data_b(8'd0),
        .wren_b(1'b0),
        .q_b(cp_data)
    );

    dpram_dc #(.widthad_a(11), .width_a(8)) tile_shadow
    (
        .clock_a(clk),
        .address_a(cp_addr_d),
        .data_a(cp_data),
        .wren_a(cp_we_d),
        .q_a(),

        .clock_b(clk),
        .address_b(vram_addr_mux),
        .data_b(8'd0),
        .wren_b(1'b0),
        .q_b(vram_rdata)
    );

    ////////////////////////////////////////////////////////////////////////
    // Tilemap fetch pipeline
    //   fx=2: latch attribute -> colour; address gfx ROM, byte at (y+8)
    //   fx=7: promote _nxt -> _lat, becomes the tile displayed from next fx=0
    ////////////////////////////////////////////////////////////////////////

    // visible in sim as "CREDIT 00" rendering as "REDIT 00".
    // The pipeline fetches one tile ahead, so the tile displayed at h_cnt=0 must
    // sx keeps counting through hblank (h_cnt 256..383 -> sx wraps 0..127), so the
    wire [7:0] sy_next       = (v_raw + 8'd1) ^ {8{flip_screen}};
    wire [4:0] tile_row_next = sy_next[7:3];
    wire [2:0] fy_next       = sy_next[2:0];

    wire       prime         = (h_cnt >= 9'd376);

    // The fetch FSM below MUST be sequenced by a monotonically ascending phase.
    // DOWN, so fx ran 7->0 and the pipeline executed BACKWARDS — the fx=7
    wire [2:0] ph = h_cnt[2:0];

    // The scan direction reverses under flip, so "one tile ahead" reverses too.
    wire [4:0] fetch_col = flip_screen ? (tile_col - 5'd1) : (tile_col + 5'd1);

    // The first tile displayed on a line is tile_col 31 when the scan mirrors,
    wire [4:0] prime_col = flip_screen ? 5'd31 : 5'd0;
    // ------------------------------------------------------------------------

    reg  [7:0] code_nxt;
    reg  [4:0] color_nxt;
    reg  [7:0] byte_lo_nxt, byte_hi_nxt;

    reg  [4:0] color_lat;
    reg  [7:0] byte_lo_lat, byte_hi_lat;

    // exctsccr plane-2 (3bpp). Fetched in PARALLEL with planes 0/1 on its own
    // code[8]: init_exctsccr puts 6_c5's low nibbles at gfx1 0x2000-0x2FFF and
    reg  [3:0] p2_hi_nxt, p2_lo_nxt, p2_hi_lat, p2_lo_lat;
    reg        p2_hi_nib, p2_lo_nib;
    reg [12:0] gfx_p3_addr_r;
    assign gfx_p3_addr = spr_busy ? spr_p3_addr : gfx_p3_addr_r;

    reg [13:0] gfx_addr_r;
    // The gfx ROM has one read port, shared between the tilemap fetch and the
    assign gfx_addr    = spr_busy ? spr_gfx_addr : gfx_addr_r;

    // sprites occupy 0x2000-0x3FFF. Hence the leading 1'b0.
    wire [8:0] code_full = {gfx_bank, code_nxt};

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            if (prime) begin
                // Prime column 0 of the NEXT line. Sequenced directly by h_cnt (fixed
                case (h_cnt)
                    9'd376: vram_raddr <= {1'b0, tile_row_next, prime_col};
                    9'd377: begin
                        code_nxt   <= vram_rdata;
                        vram_raddr <= {1'b1, tile_row_next, prime_col};
                    end
                    // code, the attribute and both planes-0/1 gfx bytes, but
                    // NEVER plane 2, and never promoted p2_*_lat. So the first
                    // "CREDIT 00 / 1ST GAME renders green instead of white"
                    9'd378: begin
                        color_nxt  <= vram_rdata[4:0];
                        gfx_addr_r <= {1'b0, code_full, 1'b1, fy_next};
                        gfx_p3_addr_r <= {1'b0, code_full[7:0], 1'b1, fy_next};
                        p2_hi_nib  <= code_full[8];
                    end
                    9'd379: begin
                        byte_hi_nxt <= gfx_data;
                        p2_hi_nxt   <= p2_hi_nib ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                        gfx_addr_r  <= {1'b0, code_full, 1'b0, fy_next};
                        gfx_p3_addr_r <= {1'b0, code_full[7:0], 1'b0, fy_next};
                        p2_lo_nib   <= code_full[8];
                    end
                    9'd380: begin
                        byte_lo_nxt <= gfx_data;
                        p2_lo_nxt   <= p2_lo_nib ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                    end
                    9'd383: begin
                        color_lat   <= color_nxt;
                        byte_lo_lat <= byte_lo_nxt;
                        byte_hi_lat <= byte_hi_nxt;
                        p2_lo_lat   <= p2_lo_nxt;
                        p2_hi_lat   <= p2_hi_nxt;
                    end
                    default: ;
                endcase
            end else
            case (ph)
                3'd0: vram_raddr <= {1'b0, tile_row, fetch_col};
                3'd1: begin
                    code_nxt   <= vram_rdata;
                    vram_raddr <= {1'b1, tile_row, fetch_col};   // +0x400 attribute plane
                end
                3'd2: begin
                    // champbas : colour = (attr & 0x1f) | 0x20   (champbas.cpp:348)
                    // exctsccr : colour = (attr & 0x0f)          (champbas.cpp:356)
                    // Low 5 bits are stored either way; champbas's |0x20 is a constant
                    color_nxt   <= vram_rdata[4:0];
                    gfx_addr_r  <= {1'b0, code_full, 1'b1, fy};   // byte at y+8
                    gfx_p3_addr_r <= {1'b0, code_full[7:0], 1'b1, fy};
                    p2_hi_nib   <= code_full[8];
                end
                3'd3: begin
                    byte_hi_nxt <= gfx_data;
                    p2_hi_nxt   <= p2_hi_nib ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                    gfx_addr_r  <= {1'b0, code_full, 1'b0, fy};  // byte at y
                    gfx_p3_addr_r <= {1'b0, code_full[7:0], 1'b0, fy};
                    p2_lo_nib   <= code_full[8];
                end
                3'd4: begin
                    byte_lo_nxt <= gfx_data;
                    p2_lo_nxt   <= p2_lo_nib ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                end
                3'd7: begin
                    color_lat   <= color_nxt;
                    byte_lo_lat <= byte_lo_nxt;
                    byte_hi_lat <= byte_hi_nxt;
                    p2_lo_lat   <= p2_lo_nxt;
                    p2_hi_lat   <= p2_hi_nxt;
                end
                default: ;
            endcase
        end
    end

    ////////////////////////////////////////////////////////////////////////
    // Pixel decode
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] byte_sel = fx[2] ? byte_lo_lat : byte_hi_lat;
    wire [1:0] xic      = ~fx[1:0];

    wire p0_bit = byte_sel[{1'b1, xic}];   // high nibble -> plane 0
    wire p1_bit = byte_sel[{1'b0, xic}];   // low  nibble -> plane 1

    wire [1:0] tile_pix = {p0_bit, p1_bit};

    // Pen index within the 512-entry space: {colour[5:0], pen[1:0]}.
    // colour[5] is the constant 1 from the |0x20 above.
    wire [3:0] p2_sel  = fx[2] ? p2_lo_lat : p2_hi_lat;
    wire       p2_bit  = p2_sel[xic];

    // champbas : pen = {1, colour[4:0], pix[1:0]}      (colour |0x20, 2bpp)
    // exctsccr : pen = {0, colour[3:0], pix[2:0]}      (colour &0x0f, 3bpp,
    //            chars at palette base 0x000 with 8 pens per colour, :1195)
    wire [7:0] tile_pen = is_exctsccr ? {1'b0, color_lat[3:0], p2_bit, tile_pix}
                                      : {1'b1, color_lat[4:0], tile_pix};

    ////////////////////////////////////////////////////////////////////////
    // SPRITE ENGINE  (champbas.cpp:387-418)
    // 8 sprites, 16x16, 2bpp. MAME iterates offs = 0x0E down to 0 step -2,
    //   code  = (attr[offs]   >> 2 & 0x3f) | (gfx_bank << 6)
    //   color = (attr[offs+1] & 0x1f)      | (palette_bank << 6)
    ////////////////////////////////////////////////////////////////////////

    // Line buffer, double buffered. {valid, is4bpp, 8-bit palette pen}.
    reg  [9:0] linebuf [0:511];
    reg  [9:0] lb_q;
    reg        lb_bank = 1'b0;          // buffer being WRITTEN this line

    reg        lb_we;
    reg  [7:0] lb_waddr;
    reg  [9:0] lb_wdata;
    wire [7:0] lb_raddr = sx;

    always_ff @(posedge clk) begin
        if (lb_we) linebuf[{lb_bank, lb_waddr}] <= lb_wdata;
        lb_q <= linebuf[{~lb_bank, lb_raddr}];
    end

    // Target line for this render pass = the line about to be displayed.
    wire [7:0] spr_line = (v_raw + 8'd1);

    localparam [8:0] SPR_START = 9'd260;    // just inside hblank (H_VIS = 256)

    // The buffer being WRITTEN is not the one being displayed, so it can be
    wire       clr_active = (h_cnt < H_VIS);
    wire [7:0] clr_addr   = h_cnt[7:0];

    // 16 slots x 40 phases = 640 clk, starting at h_cnt 260 -> ends h_cnt 340,
    // before the tilemap's column-0 prime window opens at 376.
    // MAME draws 3bpp first then 4bpp, each offs 0x0E->0, so later writes win.
    reg  [3:0] spr_slot;
    reg  [5:0] spr_phase;
    reg        spr_busy;
    reg        spr_start_d;

    reg  [7:0] s_y, s_x, s_a0, s_a1;
    reg  [7:0] s_byteA, s_byteB;
    reg  [3:0] s_p2nib;
    reg  [3:0] s_row;
    reg        s_active;

    ////////////////////////////////////////////////////////////////////////
    // MAME draws the 4bpp bank with transpen_mask(gfx, colour, 0x10)
    //     ctabentry = (color_prom[0x100 + i] & 0x0f) | 0x10
    // that MAME drops were drawn in colour-index 0x10 — the black masks
    ////////////////////////////////////////////////////////////////////////

    reg [255:0] lut4_opaque;

    // index is (addr - 0x120), NOT addr[7:0] — 0x120 & 0xFF = 0x20, which
    // rotated the whole mask by 32 entries and left the 4bpp team still boxed.
    wire [8:0] lut4_off = ioctl_addr[8:0] - 9'h120;

    always_ff @(posedge clk_dl) begin
        if (ioctl_wr && ioctl_download && (ioctl_index == 8'd7)
            && (ioctl_addr >= 25'h120) && (ioctl_addr < 25'h220))
            lut4_opaque[lut4_off[7:0]] <= |ioctl_data[3:0];
    end

    wire       s_bank = spr_slot[3];                 // 0 = first bank, 1 = 4bpp bank
    wire [2:0] s_num  = 3'd7 - spr_slot[2:0];        // MAME order: 7 first, 0 last
    wire       s_is4  = is_exctsccr & s_bank;
    wire       s_is3  = is_exctsccr & ~s_bank;
    wire       slot_used = is_exctsccr | ~s_bank;    // champbas uses only bank 0

    assign spr_pos_bank  = s_bank;
    assign spr_pos_addr  = {s_num, (spr_phase == 6'd1)};
    assign spr_attr_addr = {s_num, (spr_phase >= 6'd3)};

    wire [7:0] attr_src = s_is3 ? vram_rdata : spr_attr_data;

    wire [7:0] s_top_raw = 8'd255 - s_y;

    // two SEPARATE mirrors so each can be tuned alone.
    //   "wrong place, right way up" -> s_top_eff   (placement, origin-only)
    //   "right place, inside out"   -> s_row XOR   (internal order)
    // but the two teams came out swapped left<->right and the trophy sign moved
    wire [7:0] s_top     = s_top_raw;
    wire [7:0] s_dy      = spr_line - s_top;
    wire       s_on_line = (s_dy < 8'd16);
    // MEASURED, not derived: comparing "FPGA - Soccer 2.png" against
    // height where MAME has them at 0.60-0.65 — a MIRROR (0.60->0.40), not a
    // shift — and the trophy sign moves left->right. Raw X is the DISPLAYED
    wire       s_flipx   = ~s_a0[0] ^ flip_screen;
    wire       s_flipy   = ~s_a0[1];

    //   champbas : code = (a0>>2 & 0x3f) | gfx_bank<<6      colour = a1&0x1f | palbank<<6
    //   3bpp     : code = (a0>>2 & 0x3f) | (a1<<2 & 0x40)   colour = a1&0x0f   (:433-436)
    //   4bpp     : code =  a0>>2 & 0x3f                     colour = a1&0x0f   (:451-454)
    wire [6:0] s_code = s_is3 ? {s_a1[4], s_a0[7:2]}
                      : s_is4 ? {1'b0,    s_a0[7:2]}
                              : {gfx_bank, s_a0[7:2]};

    // phase -> chunk. 4 chunks of 7 phases starting at 6.
    wire [1:0] chunk = (spr_phase >= 6'd27) ? 2'd3 :
                       (spr_phase >= 6'd20) ? 2'd2 :
                       (spr_phase >= 6'd13) ? 2'd1 : 2'd0;
    wire [5:0] cbase = (chunk == 2'd3) ? 6'd27 :
                       (chunk == 2'd2) ? 6'd20 :
                       (chunk == 2'd1) ? 6'd13 : 6'd6;
    wire [2:0] cph   = spr_phase - cbase;            // 0..6
    wire       in_chunks = (spr_phase >= 6'd6) && (spr_phase <= 6'd33);

    wire [1:0] pic       = cph[1:0] - 2'd3;          // pixel within chunk, valid cph 3..6
    wire [3:0] s_px      = {chunk, pic};
    wire [1:0] src_chunk = s_flipx ? (2'd3 - chunk) : chunk;
    wire [1:0] s_xic     = s_flipx ? pic : (2'd3 - pic);

    // base byte per 4-pixel chunk is {8,16,24,0} -> 8*((chunk+1)&3)
    wire [1:0] s_k   = src_chunk + 2'd1;
    wire [5:0] s_off = {s_row[3], s_k, s_row[2:0]};   // byte within the 64-byte sprite

    // planes 0/1 (all variants except 4bpp) live in the UPPER half of index 2.
    // Talbot's gfx1/gfx2 are 0x1000 each (champbas: 0x2000 each), so the MRA's
    // sprite code is 6 bits -- MAME masks 0x3f and talbot nops gfxbank
    wire [13:0] spr_gfx_addr = is_talbot ? {2'b01, s_code[5:0], s_off}
                                         : {1'b1,  s_code,      s_off};
    // 3bpp plane 2: gfx2's second half = 6_c5[0x1000..] nibble-split, index 8 upper 4K
    wire [12:0] spr_p3_addr  = {1'b1, s_code[5:0], s_off};
    wire        spr_p3_hi    = s_code[6];
    // 4bpp: first half of gfx3 at off, second half at 0x1000+off
    wire [12:0] spr_g3_addr  = {(cph >= 3'd1) & (cph <= 3'd2) ? 1'b1 : 1'b0, s_code[5:0], s_off};

    wire p0_hi = s_byteA[{1'b1, s_xic}];
    wire p0_lo = s_byteA[{1'b0, s_xic}];
    wire p1_hi = s_byteB[{1'b1, s_xic}];
    wire p1_lo = s_byteB[{1'b0, s_xic}];
    wire p2_b  = s_p2nib[s_xic];

    wire [3:0] s_pix = s_is4 ? {p1_hi, p1_lo, p0_hi, p0_lo}
                     : s_is3 ? {1'b0, p2_b, p0_hi, p0_lo}
                             : {2'b00,      p0_hi, p0_lo};

    //   champbas : pen = {palbank, a1[4:0], pix[1:0]}
    //   3bpp     : pen = 0x080 + colour*8  + pix  = {1, a1[3:0], pix[2:0]}
    //   4bpp     : pen = 0x100 + colour*16 + pix  = {a1[3:0], pix[3:0]}, flagged is4
    wire [7:0] s_pen = s_is4 ? {s_a1[3:0], s_pix}
                     : s_is3 ? {1'b1, s_a1[3:0], s_pix[2:0]}
                             : {palette_bank, s_a1[4:0], s_pix[1:0]};

    always_ff @(posedge clk) begin
        lb_we       <= 1'b0;
        spr_start_d <= (h_cnt == SPR_START);

        if (reset) begin
            spr_busy  <= 1'b0;
            spr_slot  <= 4'd0;
            spr_phase <= 6'd0;
            lb_bank   <= 1'b0;
        end else begin
            // clear the write buffer during the active window
            if (clr_active) begin
                lb_we    <= 1'b1;
                lb_waddr <= clr_addr;
                lb_wdata <= 10'd0;
            end

            if ((h_cnt == SPR_START) && !spr_start_d) begin
                spr_busy  <= 1'b1;
                spr_slot  <= 4'd0;
                spr_phase <= 6'd0;
            end else if (spr_busy) begin
                if (spr_phase == 6'd39) begin
                    spr_phase <= 6'd0;
                    spr_slot  <= spr_slot + 4'd1;
                    if (spr_slot == 4'd15) spr_busy <= 1'b0;
                end else begin
                    spr_phase <= spr_phase + 6'd1;
                end

                if (slot_used) begin
                    case (spr_phase)
                        6'd0: s_y  <= spr_pos_data;
                        6'd1: s_x  <= spr_pos_data;
                        6'd3: s_a0 <= attr_src;
                        6'd4: s_a1 <= attr_src;
                        6'd5: begin
                            s_active <= s_on_line;
                            // the pair above — the attribute XOR, which mirrors
                            s_row    <= s_flipy ? (4'd15 - s_dy[3:0]) : s_dy[3:0];
                        end
                        default: ;
                    endcase

                    if (in_chunks) begin
                        // cph 0: address planes 0/1 (+ plane 2 in parallel, own port)
                        if (cph == 3'd1) begin
                            s_byteA <= s_is4 ? gfx3_data : gfx_data;
                            s_p2nib <= spr_p3_hi ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                        end
                        if (cph == 3'd2) s_byteB <= gfx3_data;

                        // keep the direct `pixel != 0` test; only the 4bpp bank
                        if (cph >= 3'd3 && s_active && slot_used
                            && (s_is4 ? lut4_opaque[s_pen] : (s_pix != 4'd0))) begin
                            lb_we    <= 1'b1;
                            // raw-X mirror, in the ORIGIN-ONLY form the vault
                            lb_waddr <= (flip_screen ? (8'd240 - (s_x - 8'd16))
                                                     : (s_x - 8'd16)) + {4'd0, s_px};
                            lb_wdata <= {1'b1, s_is4, s_pen};
                        end
                    end
                end
            end

            if (cen_pix && (h_cnt == H_TOTAL - 9'd1)) lb_bank <= ~lb_bank;
        end
    end

    assign gfx3_addr = spr_g3_addr;

    // VRAM port B is shared. The exctsccr 3bpp bank reads its sprite attributes
    assign vram_addr_mux = (spr_busy && s_is3) ? {7'd0, spr_attr_addr} : vram_raddr;

    wire       spr_opaque = lb_q[9];
    wire       spr_is4    = lb_q[8];
    wire [7:0] spr_pen    = lb_q[7:0];

    ////////////////////////////////////////////////////////////////////////
    // Colour lookup
    //   stage 1: pen[7:0] -> LUT PROM -> 4-bit colour index low nibble
    //   stage 2: {palette_bank, lut[3:0]} -> 32-entry palette PROM -> RGB
    //   ctabentry = (lut[i & 0xff] & 0x0f) | ((i & 0x100) >> 4)
    // (palette offset palette_bank<<8) and the sprite path (colour |=
    // LUT PROM sits at 0x020 in the index-7 region (palette PROM is 0x000-0x01F).
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] active_pen = spr_opaque ? spr_pen : tile_pen;

    // exctsccr indexes its LUT through a bitswap (champbas.cpp:324):
    wire [7:0] pen_swapped = {active_pen[2], active_pen[7], active_pen[6], active_pen[5],
                              active_pen[4], active_pen[3], active_pen[1], active_pen[0]};

    wire [7:0] lut_index = is_exctsccr ? pen_swapped : active_pen;

    // exctsccr_palette (champbas.cpp:329-334) splits the pen space in two:
    //   pens 0x000-0x0FF (chars + 3bpp sprites):
    //       ctabentry = (color_prom[bitswap(i)] & 0x0f) | ((i & 0x80) >> 3)
    //   pens 0x100-0x1FF (4bpp sprites, :330):
    //       ctabentry = (color_prom[0x100 + i] & 0x0f) | 0x10
    // (prom2.8r, region 0x120+ once the 0x20 palette PROM is skipped), and
    wire pen_is4 = spr_opaque & spr_is4;

    assign prom_addr = pen_is4 ? (10'h120 + {2'd0, active_pen})
                               : (10'h020 + {2'd0, lut_index});

    //                                        : {palette_bank,  prom_data[3:0]};
    wire [4:0] color_index = pen_is4     ? {1'b1,          prom_data[3:0]}
                           : is_exctsccr ? {active_pen[7], prom_data[3:0]}
                                         : {palette_bank,  prom_data[3:0]};

    ////////////////////////////////////////////////////////////////////////
    // Palette PROM (32 x 8)
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] pal_prom [0:31];

    always_ff @(posedge clk_dl) begin
        if (ioctl_wr && ioctl_download && (ioctl_index == 8'd7) && (ioctl_addr < 25'h20))
            pal_prom[ioctl_addr[4:0]] <= ioctl_data;
    end

    wire [7:0] pal_byte = pal_prom[color_index];

    ////////////////////////////////////////////////////////////////////////
    // Resistor-network DAC (champbas.cpp:243-251)
    // 0x21 / 0x47 / 0x97 triple (the same constants exctsccr_palette :301
    // 0x51 / 0xAE. Each channel's weights sum to 0xFF.
    ////////////////////////////////////////////////////////////////////////

    function automatic [7:0] rgb3;
        input b0, b1, b2;
        begin
            rgb3 = (b0 ? 8'h21 : 8'h00) + (b1 ? 8'h47 : 8'h00) + (b2 ? 8'h97 : 8'h00);
        end
    endfunction

    function automatic [7:0] rgb2;
        input b0, b1;
        begin
            rgb2 = (b0 ? 8'h51 : 8'h00) + (b1 ? 8'hAE : 8'h00);
        end
    endfunction

    wire [7:0] r_lvl = rgb3(pal_byte[0], pal_byte[1], pal_byte[2]);
    wire [7:0] g_lvl = rgb3(pal_byte[3], pal_byte[4], pal_byte[5]);
    // Blue differs between the two palette functions. champbas normalises its
    // (champbas.cpp:310-313), so its blue tops out at 0xDE rather than 0xFF.
    wire [7:0] b_lvl = is_exctsccr ? rgb3(1'b0, pal_byte[6], pal_byte[7])
                                   : rgb2(pal_byte[6], pal_byte[7]);

    wire blanking = hblk || vblk;

    assign VGA_R = blanking ? 8'd0 : r_lvl;
    assign VGA_G = blanking ? 8'd0 : g_lvl;
    assign VGA_B = blanking ? 8'd0 : b_lvl;

endmodule
