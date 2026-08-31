//============================================================================
//
//  UPLFramebuffer_VIDEO.sv — raster, palette, the 8x8 foreground tilemap and the
//  512x512 background tilemap.
//
//  The sprite framebuffer is not built yet, so the layer order is bg then fg
//  (ninjakd2.cpp screen_update_ninjakd2 puts sprites between them).
//
//============================================================================

module UPLFramebuffer_VIDEO
(
    input               clk,
    input               cen_pix,         // pixel clock enable (target 6.0 MHz)
    input               reset,

    input               flip_screen,
    input               bg_mnight,       // mnight/arkarea bg tile decode (11-bit index)
    input               is_robokid,      // robokid palette bases, gfx col order, 5-bit RGB

    // DIAG-REVERT-2026-08-30: 1 = ignore fg_videoram and the palette, draw char
    // tiles 0.. in order as greyscale. The screen becomes the gfx ROM itself.
    input               DIAG_TILEVIEW,

    // DIAG-REVERT-2026-08-30: background bisection.
    //   0 Off      normal
    //   1 Swatch   bg colour/pen straight from screen position, VRAM and ROM and
    //              bg_enable all bypassed -> tests only mixing + palette
    //   2 TileROM  tile index from screen position, bg_videoram bypassed
    //              -> tests the tiles1 SDRAM fetch path
    //   3 VRAMCol  normal fetch but pen forced to 1, so what shows is the colour
    //              nibble the CPU wrote into bg_videoram
    input         [1:0] DIAG_BGMODE,
    // DIAG-REVERT-2026-08-30: 1 = drop the sprite framebuffer out of the mix,
    // so an unexpected sprite layer can be told apart from a bg/fg fault.
    input               DIAG_SPROFF,

    // ---- fg tilemap RAM (in MAIN)
    output       [10:0] fg_vram_addr,
    input         [7:0] fg_vram_data,

    // ---- bg tilemap RAM (in MAIN) and its scroll/enable registers
    output       [10:0] bg_vram_addr,
    input         [7:0] bg_vram_data,
    input        [15:0] bg_scrollx,
    input        [15:0] bg_scrolly,
    input               bg_enable,

    // ---- bg tile ROM (SDRAM, via upl_rom)
    output       [18:0] tile1_addr,
    output              tile1_req,
    input               tile1_ack,
    input         [7:0] tile1_data,

    // ---- char ROM (SDRAM, via upl_rom)
    output       [14:0] char_addr,
    output              char_req,
    input               char_ack,
    input         [7:0] char_data,

    // ---- sprite framebuffer (in UPLFramebuffer_SPRITE)
    output       [15:0] fb_raddr,
    input         [7:0] fb_rdata,
    output              spr_draw_window,   // vblank rendering window for the engine

    // ---- palette (in MAIN)
    output        [9:0] pal_index,
    input        [15:0] pal_rgb,

    output              HSync,
    output              VSync,
    output              HBlank,
    output              VBlank,
    output        [7:0] R,
    output        [7:0] G,
    output        [7:0] B,

    // DIAG-REVERT-2026-08-30: bg fetch visibility for the Verilator harness only.
    // Leave unconnected in synthesis; costs nothing.
    output        [3:0] DIAG_bst,
    output        [9:0] DIAG_btidx,
    output        [3:0] DIAG_bty,
    output              DIAG_bstart
);

    ////////////////////////////////////////////////////////////////////////
    // Video timing.
    //   6.0 MHz pixel, H_TOTAL 384 -> 15.625 kHz H
    //   V_TOTAL 262 -> 59.637 Hz V (MAME ninjakd2.cpp: 59.61 "verified on pcb")
    //   v_cnt IS the tilemap row; MAME's visarea is y 32..223 of a 256-row map.
    ////////////////////////////////////////////////////////////////////////

    localparam H_TOTAL   = 9'd384;
    localparam H_VIS     = 9'd256;
    localparam HS_START  = 9'd272;
    localparam HS_END    = 9'd304;

    localparam V_TOTAL   = 9'd262;
    localparam V_VIS_LO  = 9'd32;    // MAME visarea min_y
    localparam V_VIS_HI  = 9'd224;   // one past max_y (223)
    localparam VS_START  = 9'd232;
    localparam VS_END    = 9'd235;

    reg [8:0] h_cnt = 9'd0;
    reg [8:0] v_cnt = 9'd0;

    always_ff @(posedge clk) begin
        if (reset) begin
            h_cnt <= 9'd0;
            v_cnt <= 9'd0;
        end else if (cen_pix) begin
            if (h_cnt == H_TOTAL - 1'd1) begin
                h_cnt <= 9'd0;
                v_cnt <= (v_cnt == V_TOTAL - 1'd1) ? 9'd0 : v_cnt + 1'd1;
            end else begin
                h_cnt <= h_cnt + 1'd1;
            end
        end
    end

    // The fg/bg tile fetches and the sprite engine share the SDRAM arbiter, and
    // fg+bg alone already use ~85% of it. Splitting them in time is what makes the
    // sprite engine fit: tiles fetch over the visible lines plus two ahead to prime
    // the pipelines, and the engine owns the rest of vblank.
    wire fetch_en = (v_cnt >= V_VIS_LO - 9'd2) && (v_cnt < V_VIS_HI);
    assign spr_draw_window = !fetch_en;

    assign fb_raddr = {v_cnt[7:0], h_cnt[7:0]};

    wire hblank_raw = (h_cnt >= H_VIS);
    wire vblank_raw = (v_cnt < V_VIS_LO) || (v_cnt >= V_VIS_HI);
    wire hsync_raw  = (h_cnt >= HS_START) && (h_cnt < HS_END);
    wire vsync_raw  = (v_cnt >= VS_START) && (v_cnt < VS_END);

    ////////////////////////////////////////////////////////////////////////
    // Foreground tilemap fetch. One 8-pixel group is fetched while the
    // previous one is displayed: 2 bytes of tilemap RAM then 4 bytes of char
    // ROM. At 10 clk per pixel there are 80 clk per group, comfortably more
    // than the ~45 the sequence needs.
    //   tile   = ((hi & 0xc0) << 2) | lo      (ninjakd2.cpp get_fg_tile_info)
    //   flipyx = (hi >> 4) & 3
    //   color  = hi & 0x0f, palette base 0x200
    ////////////////////////////////////////////////////////////////////////

    wire [8:0] h_next   = (h_cnt >= H_TOTAL - 9'd8) ? (h_cnt - (H_TOTAL - 9'd8)) : (h_cnt + 9'd8);
    wire [8:0] v_fetch  = (h_cnt >= H_TOTAL - 9'd8) ? ((v_cnt == V_TOTAL - 1'd1) ? 9'd0 : v_cnt + 1'd1) : v_cnt;

    // screen->tilemap coordinates, with screen flip
    wire [7:0] fx = flip_screen ? (8'd255 - h_next[7:0])  : h_next[7:0];
    wire [7:0] fy = flip_screen ? (8'd255 - v_fetch[7:0]) : v_fetch[7:0];

    reg  [9:0] tile_lat = 10'd0;   // DIAG-REVERT-2026-08-30
    reg  [3:0] st = 4'd0;
    reg  [7:0] tlo = 8'd0, thi = 8'd0;
    reg [31:0] rowbits_n = 32'd0;   // next group's 8 pixels, 4bpp packed MSB
    reg  [3:0] color_n = 4'd0;
    reg        flipx_n = 1'b0;
    reg [31:0] rowbits = 32'd0;
    reg  [3:0] color   = 4'd0;
    reg        flipx   = 1'b0;

    wire [9:0] tile_index = {fy[7:3], fx[7:3]};
    // DIAG-REVERT-2026-08-30: original below, restore when removing the viewer
    // wire [9:0] tile_num = {thi[7:6], tlo};
    wire [9:0] tile_num   = DIAG_TILEVIEW ? tile_lat : {thi[7:6], tlo};
    // DIAG-REVERT-2026-08-30: original -> wire fy_flip = thi[5];
    // The viewer MUST force both flips off: they come from fg_videoram, so
    // garbage tilemap data flips tiles at random and garbles the viewer even
    // when the ROM path is correct.
    wire       fy_flip    = DIAG_TILEVIEW ? 1'b0 : thi[5];
    wire [2:0] trow       = fy_flip ? ~fy[2:0] : fy[2:0];

    reg [10:0] fg_addr_r;
    reg [14:0] char_addr_r;
    reg        char_req_r;

    assign fg_vram_addr = fg_addr_r;
    assign char_addr    = char_addr_r;
    assign char_req     = char_req_r;

    always_ff @(posedge clk) begin
        if (reset || !fetch_en) begin
            st <= 4'd0; char_req_r <= 1'b0;
        end else begin
            if (cen_pix && (h_cnt[2:0] == 3'd7)) begin
                // hand the completed group to the display side and restart
                rowbits <= rowbits_n;
                color   <= color_n;
                flipx   <= flipx_n;
                st      <= 4'd0;
            end else begin
                case (st)
                    // DIAG-REVERT-2026-08-30: -4 tile rows so tile 0 lands on the first
                    // VISIBLE line (the window starts at bitmap row 32 = tile row 4)
                    4'd0: begin fg_addr_r <= {tile_index, 1'b0};
                                tile_lat <= {fy[7:3] - 5'd4, fx[7:3]}; st <= 4'd1; end
                    4'd1: st <= 4'd2;                                  // BRAM latency
                    4'd2: begin tlo <= fg_vram_data; fg_addr_r <= {tile_index, 1'b1}; st <= 4'd3; end
                    4'd3: st <= 4'd4;
                    4'd4: begin
                        thi     <= fg_vram_data;
                        color_n <= fg_vram_data[3:0];
                        // DIAG-REVERT-2026-08-30: original -> flipx_n <= fg_vram_data[4];
                        flipx_n <= DIAG_TILEVIEW ? 1'b0 : fg_vram_data[4];
                        st      <= 4'd5;
                    end
                    4'd5: begin char_addr_r <= {tile_num, trow, 2'd0}; char_req_r <= 1'b1; st <= 4'd6; end
                    4'd6: if (char_ack) begin rowbits_n[31:24] <= char_data; char_req_r <= 1'b0; st <= 4'd7; end
                    4'd7: begin char_addr_r <= {tile_num, trow, 2'd1}; char_req_r <= 1'b1; st <= 4'd8; end
                    4'd8: if (char_ack) begin rowbits_n[23:16] <= char_data; char_req_r <= 1'b0; st <= 4'd9; end
                    4'd9: begin char_addr_r <= {tile_num, trow, 2'd2}; char_req_r <= 1'b1; st <= 4'd10; end
                    4'd10: if (char_ack) begin rowbits_n[15:8] <= char_data; char_req_r <= 1'b0; st <= 4'd11; end
                    4'd11: begin char_addr_r <= {tile_num, trow, 2'd3}; char_req_r <= 1'b1; st <= 4'd12; end
                    4'd12: if (char_ack) begin rowbits_n[7:0] <= char_data; char_req_r <= 1'b0; st <= 4'd13; end
                    default: ;
                endcase
            end
        end
    end

    ////////////////////////////////////////////////////////////////////////
    // Background tilemap: 16x16 tiles, 32x32 map = 512x512, wrapping, with a
    // 16-bit scroll on each axis (ninjakd2.cpp bg_ctrl, only the low 9 bits can
    // matter against a 512-pixel map).
    //   tile   = ((hi & 0xc0) << 2) | lo      (ninjakd2_get_bg_tile_info)
    //   flipyx = (hi >> 4) & 3
    //   color  = hi & 0x0f, palette base 0x000
    //
    // The fetch is phase-locked to MAP tile boundaries, not screen ones. With a
    // scroll that is not a multiple of 16 a screen-aligned 16-pixel group spans
    // two map tiles, so aligning to h_cnt[3:0] would tear on most scroll values.
    // Locking to bmx[3:0] gives exactly one map tile per fetch at any scroll.
    ////////////////////////////////////////////////////////////////////////

    // Fetch is RASTER-aligned (h_cnt[3:0]), not map-tile aligned. Phase-locking the
    // window to map tiles cannot work: the window boundary would have to line up
    // with the end-of-line wrap as well, and it only does when the scroll happens
    // to be a multiple of 16. Instead a 16-pixel screen group spans at most TWO map
    // tiles, so the display keeps both and selects per pixel on dmx[8:4].
    //
    // Pipeline, one group = 16 pixels:
    //   cur <= nxt, nxt <= new, and a fetch for the tile two groups ahead starts.
    // The +32 lookahead is what makes nxt already valid when a group straddles.

    wire [8:0] fh = (h_cnt >= H_TOTAL - 9'd32) ? (h_cnt - (H_TOTAL - 9'd32)) : (h_cnt + 9'd32);
    wire [8:0] fv = (h_cnt >= H_TOTAL - 9'd32) ? ((v_cnt == V_TOTAL - 1'd1) ? 9'd0 : v_cnt + 1'd1) : v_cnt;

    // Full 9 bits, no truncation to the 256-wide screen. The lookahead runs past
    // 255 into hblank, and those positions still have a well-defined map column --
    // it is the one a straddling group at the end of the visible line needs. All of
    // this is mod-512 arithmetic against a 512-pixel map, which is what makes the
    // flipped case fall out correctly too.
    wire [8:0] fsx = flip_screen ? (9'd255 - fh) : fh;
    wire [8:0] fsy = flip_screen ? (9'd255 - fv) : fv;
    wire [8:0] fmx = fsx + bg_scrollx[8:0];
    wire [8:0] fmy = fsy + bg_scrolly[8:0];

    // map coordinates of the pixel being displayed, and of the next group's first
    wire [8:0] h_p1 = (h_cnt == H_TOTAL - 1'd1) ? 9'd0 : h_cnt + 1'd1;
    wire [8:0] dsx  = flip_screen ? (9'd255 - h_cnt) : h_cnt;
    wire [8:0] dsx1 = flip_screen ? (9'd255 - h_p1)  : h_p1;
    wire [8:0] dmx  = dsx  + bg_scrollx[8:0];
    wire [8:0] dmx1 = dsx1 + bg_scrollx[8:0];

    wire bg_group_end = (h_cnt[3:0] == 4'd15);

    reg  [3:0] bst = 4'd0;
    reg  [2:0] bj  = 3'd0;
    reg  [7:0] blo = 8'd0, bhi = 8'd0;

    // latched at the start of the fetch so nothing drifts as h_cnt advances
    reg  [9:0] bfetch_tidx = 10'd0;
    reg  [3:0] bfetch_my   = 4'd0;

    reg [63:0] bg_new_rowbits = 64'd0;  reg [3:0] bg_new_color = 4'd0;  reg bg_new_flipx = 1'b0;
    reg [63:0] bg_nxt_rowbits = 64'd0;  reg [3:0] bg_nxt_color = 4'd0;  reg bg_nxt_flipx = 1'b0;
    reg [63:0] bg_cur_rowbits = 64'd0;  reg [3:0] bg_cur_color = 4'd0;  reg bg_cur_flipx = 1'b0;
    reg  [4:0] bg_cur_col = 5'd0;

    reg [10:0] bg_addr_r;
    reg [18:0] tile1_addr_r;
    reg        tile1_req_r;

    assign bg_vram_addr = bg_addr_r;
    assign tile1_addr   = tile1_addr_r;
    assign tile1_req    = tile1_req_r;

    // mnight/arkarea reuse hi bit4 as tile bit 10 instead of flipx
    // (ninjakd2.cpp mnight_get_bg_tile_info); ninjakd2 keeps a 10-bit index.
    // DIAG-REVERT-2026-08-30: original -> wire [9:0] bg_tile = {bhi[7:6], blo};
    wire [10:0] bg_tile  = (DIAG_BGMODE == 2'd2) ? {1'b0, bfetch_tidx}
                                                 : {bg_mnight & bhi[4], bhi[7:6], blo};
    wire        bg_flipy = bhi[5];
    wire [3:0] bg_ty    = bg_flipy ? ~bfetch_my : bfetch_my;

    // gfx_8x8x4_row_2x2_group_packed_msb: 128 bytes per 16x16 tile, four 8x8
    // sub-tiles in 0 1 / 2 3 order, so the byte offset is a pure concatenation:
    //   ty[3]*64 + tx[3]*32 + ty[2:0]*4 + tx[2:1]
    // Fetch index j is tx[3:1], so j ascending walks tx 0..15 left to right.
    // row_2x2 is 0 1 / 2 3, col_2x2 (robokid) is 0 2 / 1 3 -- the two sub-tile
    // select bits swap (emu/video/generic.cpp:145,175).
    wire bg_sub_hi = is_robokid ? bj[2]    : bg_ty[3];
    wire bg_sub_lo = is_robokid ? bg_ty[3] : bj[2];
    wire [18:0] bg_rom_addr = {1'b0, bg_tile, bg_sub_hi, bg_sub_lo, bg_ty[2:0], bj[1:0]};

    always_ff @(posedge clk) begin
        if (reset || !fetch_en) begin
            bst <= 4'd0; tile1_req_r <= 1'b0; bj <= 3'd0;
            if (reset) bg_cur_col <= 5'd0;
        end else begin
            if (cen_pix && bg_group_end) begin
                bg_cur_rowbits <= bg_nxt_rowbits;
                bg_cur_color   <= bg_nxt_color;
                bg_cur_flipx   <= bg_nxt_flipx;
                bg_cur_col     <= dmx1[8:4];
                bg_nxt_rowbits <= bg_new_rowbits;
                bg_nxt_color   <= bg_new_color;
                bg_nxt_flipx   <= bg_new_flipx;
                bst <= 4'd0;
                bj  <= 3'd0;
            end else begin
                case (bst)
                    4'd0: begin
                        bfetch_tidx <= {fmy[8:4], fmx[8:4]};
                        bfetch_my   <= fmy[3:0];
                        bg_addr_r   <= {{fmy[8:4], fmx[8:4]}, 1'b0};
                        bst         <= 4'd1;
                    end
                    4'd1: bst <= 4'd2;                                  // BRAM latency
                    4'd2: begin blo <= bg_vram_data; bg_addr_r <= {bfetch_tidx, 1'b1}; bst <= 4'd3; end
                    4'd3: bst <= 4'd4;
                    4'd4: begin
                        bhi          <= bg_vram_data;
                        bg_new_color <= bg_vram_data[3:0];
                        // mnight/arkarea use bit4 as tile bit 10, so they have no flipx
                        bg_new_flipx <= bg_mnight ? 1'b0 : bg_vram_data[4];
                        bst          <= 4'd5;
                    end
                    4'd5: begin tile1_addr_r <= bg_rom_addr; tile1_req_r <= 1'b1; bst <= 4'd6; end
                    4'd6: if (tile1_ack) begin
                              // j ascends 0..7 and byte j belongs at [63-8j -: 8],
                              // which is exactly a byte-wide shift left.
                              bg_new_rowbits <= {bg_new_rowbits[55:0], tile1_data};
                              tile1_req_r <= 1'b0;
                              if (bj == 3'd7) bst <= 4'd7;
                              else begin bj <= bj + 3'd1; bst <= 4'd5; end
                          end
                    default: ;
                endcase
            end
        end
    end

    // DIAG-REVERT-2026-08-30
    assign DIAG_bst    = bst;
    assign DIAG_btidx  = bfetch_tidx;
    assign DIAG_bty    = bg_ty;
    assign DIAG_bstart = bg_group_end;

    // Display select: a screen group spans at most two map tiles, so pick between
    // cur and nxt on the map column of this pixel.
    wire        bg_use_nxt   = (dmx[8:4] != bg_cur_col);
    wire [63:0] bg_sel_bits  = bg_use_nxt ? bg_nxt_rowbits : bg_cur_rowbits;
    wire  [3:0] bg_color     = bg_use_nxt ? bg_nxt_color   : bg_cur_color;
    wire        bg_sel_flipx = bg_use_nxt ? bg_nxt_flipx   : bg_cur_flipx;

    wire [3:0] bg_tx  = bg_sel_flipx ? ~dmx[3:0] : dmx[3:0];
    wire [5:0] bshift = {2'd0, ~bg_tx} << 2;         // nibble 15 is the leftmost pixel
    wire [3:0] bg_pix_raw = (bg_sel_bits >> bshift) & 64'hF;

    // DIAG-REVERT-2026-08-30: original -> wire [3:0] bg_pix = bg_pix_raw;
    wire [3:0] bg_pix = (DIAG_BGMODE == 2'd3) ? 4'd1 : bg_pix_raw;

    ////////////////////////////////////////////////////////////////////////
    // Pixel out. Palette RAM adds a cycle, so the syncs are delayed to match
    // (see Common-Pitfalls: pixel pipeline needs matched sync delay).
    ////////////////////////////////////////////////////////////////////////

    wire [2:0] px    = flipx ? ~h_cnt[2:0] : h_cnt[2:0];
    wire [4:0] shift = {2'd0, ~px} << 2;          // nibble 7 is the leftmost pixel
    wire [3:0] pix   = (rowbits >> shift) & 32'hF;

    // Layer order, ninjakd2.cpp screen_update_ninjakd2: bitmap cleared to pen 0,
    // bg drawn opaque, sprite framebuffer copied over it with 0xf transparent, then
    // fg with pen 0 transparent. Palette bases: bg 0x000, sprites 0x100, fg 0x200.
    // fb_rdata is {colour, pen} and the engine never writes pen 0xf, so that value
    // is an unambiguous empty marker.
    // DIAG-REVERT-2026-08-30: original -> wire spr_opaque = (fb_rdata[3:0] != 4'hF);
    wire spr_opaque = (fb_rdata[3:0] != 4'hF) && !DIAG_SPROFF;

    // DIAG-REVERT-2026-08-30: original below, restore when removing the bisection
    // assign pal_index = (|pix)     ? {2'b10, color, pix}
    //                  : spr_opaque ? {2'b01, fb_rdata}
    //                  : bg_enable  ? {2'b00, bg_color, bg_pix}
    //                               : 10'd0;
    // Swatch deliberately ignores bg_enable, so a black screen in mode 1 means the
    // mixing or palette is at fault, while black in 2/3 with 1 working means
    // bg_enable is low.
    wire [9:0] bg_index = (DIAG_BGMODE == 2'd1) ? {2'b00, v_cnt[7:4], h_cnt[7:4]}
                                                : {2'b00, bg_color, bg_pix};
    wire       bg_show  = (DIAG_BGMODE == 2'd1) ? 1'b1 : bg_enable;

    // The fg tilemap's transparent pen is 0xF, not 0 (ninjakd2.cpp:449
    // set_transparent_pen(0xf)). Testing pen 0 instead inverts it: empty areas, which
    // are pen 0xF, come out opaque as palette[0x20F], and glyph/logo interiors, which
    // are pen 0, come out transparent -- the tan/black swap seen on hardware.
    wire fg_opaque = (pix != 4'hF);

    // GFXDECODE bases: ninjakd2 fg 0x200 / spr 0x100, robokid fg 0x300 / spr 0x200.
    // Both put bg at 0x000. Reading robokid's sprites at 0x100 hits a range it never
    // writes, so they come out black.
    assign pal_index = fg_opaque   ? {is_robokid ? 2'b11 : 2'b10, color, pix}
                     : spr_opaque  ? {is_robokid ? 2'b10 : 2'b01, fb_rdata}
                     : bg_show     ? bg_index
                                   : 10'd0;

    // Colour, opacity and syncs must all come out of the SAME pipeline stage.
    // pal_index is combinational from pix, and the palette BRAM presents pal_rgb
    // one clock later - still well inside the 10-clock pixel - so latching all
    // of them on the next cen_pix captures one consistent pixel.
    // Getting this wrong (colour undelayed, opacity delayed 2) paints pixel N
    // with colour(N) gated by opacity(N-2): solid areas survive, thin strokes
    // shred and edges fringe.
    reg [15:0] rgb_lat = 16'd0;
    reg        opq_lat = 1'b0;
    reg        hs_lat  = 1'b0, vs_lat = 1'b0, hb_lat = 1'b1, vb_lat = 1'b1;

    // DIAG-REVERT-2026-08-30: in viewer mode the pixel value itself becomes the
    // greyscale level, bypassing palette RAM completely.
    wire [15:0] pal_or_grey = DIAG_TILEVIEW ? {pix, pix, pix, 4'd0} : pal_rgb;

    // Only the tile-ROM viewer keys on fg opacity; in normal operation every pixel
    // has a colour, from the fg, the bg, or pen 0 when the bg is disabled.
    always_ff @(posedge clk) if (cen_pix) begin
        // DIAG-REVERT-2026-08-30: original -> rgb_lat <= pal_rgb;
        rgb_lat <= pal_or_grey;
        opq_lat <= DIAG_TILEVIEW ? (|pix) : 1'b1;
        hs_lat  <= hsync_raw;
        vs_lat  <= vsync_raw;
        hb_lat  <= hblank_raw;
        vb_lat  <= vblank_raw;
    end

    assign HSync  = hs_lat;
    assign VSync  = vs_lat;
    assign HBlank = hb_lat;
    assign VBlank = vb_lat;

    wire visible = opq_lat & ~hb_lat & ~vb_lat;

    // robokid: RRRRGGGGBBBBRGBx (5 bits/channel, LSBs in the low nibble).
    // everything else: RGBx_444.
    wire [4:0] r5 = {rgb_lat[15:12], rgb_lat[3]};
    wire [4:0] g5 = {rgb_lat[11:8],  rgb_lat[2]};
    wire [4:0] b5 = {rgb_lat[7:4],   rgb_lat[1]};

    assign R = !visible ? 8'd0 : is_robokid ? {r5, r5[4:2]} : {rgb_lat[15:12], rgb_lat[15:12]};
    assign G = !visible ? 8'd0 : is_robokid ? {g5, g5[4:2]} : {rgb_lat[11:8],  rgb_lat[11:8]};
    assign B = !visible ? 8'd0 : is_robokid ? {b5, b5[4:2]} : {rgb_lat[7:4],   rgb_lat[7:4]};

endmodule
