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
    input               gfx_robokid,      // robokid/omegaf palette bases, gfx col order, 5-bit RGB
    input               is_omegaf,        // bg map is 128x32 tiles, not 32x32

    // ---- fg tilemap RAM (in MAIN)
    output       [10:0] fg_vram_addr,
    input         [7:0] fg_vram_data,

    // ---- bg tilemap RAM (in MAIN) and its scroll/enable registers
    output       [12:0] bg0_vram_addr,   input [7:0] bg0_vram_data,
    output       [12:0] bg1_vram_addr,   input [7:0] bg1_vram_data,
    output       [12:0] bg2_vram_addr,   input [7:0] bg2_vram_data,
    input        [15:0] bg0_scrollx, bg0_scrolly,
    input        [15:0] bg1_scrollx, bg1_scrolly,
    input        [15:0] bg2_scrollx, bg2_scrolly,
    input         [2:0] bg_layer_en,

    // ---- bg tile ROM (SDRAM, via upl_rom)
    output       [18:0] tile1_addr,  output tile1_req,  input tile1_ack,  input [7:0] tile1_data,
    output       [18:0] tile2_addr,  output tile2_req,  input tile2_ack,  input [7:0] tile2_data,
    output       [18:0] tile3_addr,  output tile3_req,  input tile3_ack,  input [7:0] tile3_data,

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
    output        [7:0] B
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

    reg  [3:0] st = 4'd0;
    reg  [7:0] tlo = 8'd0, thi = 8'd0;
    reg [31:0] rowbits_n = 32'd0;   // next group's 8 pixels, 4bpp packed MSB
    reg  [3:0] color_n = 4'd0;
    reg        flipx_n = 1'b0;
    reg [31:0] rowbits = 32'd0;
    reg  [3:0] color   = 4'd0;
    reg        flipx   = 1'b0;

    wire [9:0] tile_index = {fy[7:3], fx[7:3]};
    wire [9:0] tile_num   = {thi[7:6], tlo};
    wire       fy_flip    = thi[5];
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
                    4'd0: begin fg_addr_r <= {tile_index, 1'b0}; st <= 4'd1; end
                    4'd1: st <= 4'd2;                                  // BRAM latency
                    4'd2: begin tlo <= fg_vram_data; fg_addr_r <= {tile_index, 1'b1}; st <= 4'd3; end
                    4'd3: st <= 4'd4;
                    4'd4: begin
                        thi     <= fg_vram_data;
                        color_n <= fg_vram_data[3:0];
                        flipx_n <= fg_vram_data[4];
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
    // Background tilemaps. ninjakd2/mnight/arkarea have one layer; robokid and
    // omegaf have three identical ones (robokid_get_bg_tile_info<Layer>), so the
    // engine lives in UPLFramebuffer_BGLAYER and is instantiated three times.
    // On the single-layer sets MAIN holds bg_layer_en[2:1] low and those two idle.
    ////////////////////////////////////////////////////////////////////////

    wire [3:0] bg0_color, bg0_pix, bg1_color, bg1_pix, bg2_color, bg2_pix;

    UPLFramebuffer_BGLAYER #(.H_TOTAL(H_TOTAL), .V_TOTAL(V_TOTAL)) bg_layer0
    (
        .clk(clk), .cen_pix(cen_pix), .reset(reset), .fetch_en(fetch_en),
        .en(bg_layer_en[0]),
        .h_cnt(h_cnt), .v_cnt(v_cnt), .flip_screen(flip_screen),
        .gfx_robokid(gfx_robokid), .is_omegaf(is_omegaf), .bg_mnight(bg_mnight),
        .scrollx(bg0_scrollx), .scrolly(bg0_scrolly),
        .vram_addr(bg0_vram_addr), .vram_data(bg0_vram_data),
        .rom_addr(tile1_addr), .rom_req(tile1_req), .rom_ack(tile1_ack), .rom_data(tile1_data),
        .color(bg0_color), .pix(bg0_pix)
    );

    UPLFramebuffer_BGLAYER #(.H_TOTAL(H_TOTAL), .V_TOTAL(V_TOTAL)) bg_layer1
    (
        .clk(clk), .cen_pix(cen_pix), .reset(reset), .fetch_en(fetch_en), .en(bg_layer_en[1]),
        .h_cnt(h_cnt), .v_cnt(v_cnt), .flip_screen(flip_screen),
        .gfx_robokid(gfx_robokid), .is_omegaf(is_omegaf), .bg_mnight(bg_mnight),
        .scrollx(bg1_scrollx), .scrolly(bg1_scrolly),
        .vram_addr(bg1_vram_addr), .vram_data(bg1_vram_data),
        .rom_addr(tile2_addr), .rom_req(tile2_req), .rom_ack(tile2_ack), .rom_data(tile2_data),
        .color(bg1_color), .pix(bg1_pix)
    );

    UPLFramebuffer_BGLAYER #(.H_TOTAL(H_TOTAL), .V_TOTAL(V_TOTAL)) bg_layer2
    (
        .clk(clk), .cen_pix(cen_pix), .reset(reset), .fetch_en(fetch_en), .en(bg_layer_en[2]),
        .h_cnt(h_cnt), .v_cnt(v_cnt), .flip_screen(flip_screen),
        .gfx_robokid(gfx_robokid), .is_omegaf(is_omegaf), .bg_mnight(bg_mnight),
        .scrollx(bg2_scrollx), .scrolly(bg2_scrolly),
        .vram_addr(bg2_vram_addr), .vram_data(bg2_vram_data),
        .rom_addr(tile3_addr), .rom_req(tile3_req), .rom_ack(tile3_ack), .rom_data(tile3_data),
        .color(bg2_color), .pix(bg2_pix)
    );

    // Transparency: pen 0xf, EXCEPT robokid's bg0 and ninjakd2/mnight's single layer,
    // which stay opaque -- VIDEO_START_robokid sets the transparent pen on tilemaps 1
    // and 2 only, while VIDEO_START_omegaf sets it on all three.
    wire bg0_op = bg_layer_en[0] && (is_omegaf ? (bg0_pix != 4'hF) : 1'b1);
    wire bg1_op = bg_layer_en[1] && (bg1_pix != 4'hF);
    wire bg2_op = bg_layer_en[2] && (bg2_pix != 4'hF);

    // All three bg layers share palette base 0x000 (GFXDECODE entries 2/3/4).
    wire [9:0] bg0_index = {2'b00, bg0_color, bg0_pix};
    wire [9:0] bg1_index = {2'b00, bg1_color, bg1_pix};
    wire [9:0] bg2_index = {2'b00, bg2_color, bg2_pix};

    ////////////////////////////////////////////////////////////////////////
    // Pixel out. Palette RAM adds a cycle, so the syncs are delayed to match
    // (see Common-Pitfalls: pixel pipeline needs matched sync delay).
    ////////////////////////////////////////////////////////////////////////

    // Screen flip mirrors inside the tile too, so it XORs with the tile's own flipx
    // (255-h == ~h in 8 bits; UPLFramebuffer_BGLAYER does the same via dsx).
    wire [2:0] px    = (flipx ^ flip_screen) ? ~h_cnt[2:0] : h_cnt[2:0];
    wire [4:0] shift = {2'd0, ~px} << 2;          // nibble 7 is the leftmost pixel
    wire [3:0] pix   = (rowbits >> shift) & 32'hF;

    // Layer order, ninjakd2.cpp screen_update_ninjakd2: bitmap cleared to pen 0,
    // bg drawn opaque, sprite framebuffer copied over it with 0xf transparent, then
    // fg with pen 0 transparent. Palette bases: bg 0x000, sprites 0x100, fg 0x200.
    // fb_rdata is {colour, pen} and the engine never writes pen 0xf, so that value
    // is an unambiguous empty marker.
    wire spr_opaque = (fb_rdata[3:0] != 4'hF);

    // The fg tilemap's transparent pen is 0xF, not 0 (ninjakd2.cpp:449
    // set_transparent_pen(0xf)). Testing pen 0 instead inverts it: empty areas, which
    // are pen 0xF, come out opaque as palette[0x20F], and glyph/logo interiors, which
    // are pen 0, come out transparent -- the tan/black swap seen on hardware.
    wire fg_opaque = (pix != 4'hF);

    // GFXDECODE bases: ninjakd2 fg 0x200 / spr 0x100, gfx_robokid fg 0x300 / spr 0x200.
    // Both put bg at 0x000. Reading robokid's sprites at 0x100 hits a range it never
    // writes, so they come out black.
    // Draw order, back to front (ninjakd2.cpp screen_update_*):
    //   ninjakd2/mnight : bg0, sprites, fg
    //   robokid         : bg0, bg1, sprites, bg2, fg   <- bg2 is ABOVE the sprites
    //   omegaf          : bg0, bg1, bg2, sprites, fg
    // so bg2 outranks the sprite framebuffer on robokid only.
    wire top_is_bg2 = bg2_op && !is_omegaf;

    assign pal_index = fg_opaque   ? {gfx_robokid ? 2'b11 : 2'b10, color, pix}
                     : top_is_bg2  ? bg2_index
                     : spr_opaque  ? {gfx_robokid ? 2'b10 : 2'b01, fb_rdata}
                     : bg2_op      ? bg2_index
                     : bg1_op      ? bg1_index
                     : bg0_op      ? bg0_index
                                   : 10'd0;

    // Colour, opacity and syncs must all come out of the SAME pipeline stage.
    // pal_index is combinational from pix, and the palette BRAM presents pal_rgb
    // one clock later - still well inside the 10-clock pixel - so latching all
    // of them on the next cen_pix captures one consistent pixel.
    // Getting this wrong (colour undelayed, opacity delayed 2) paints pixel N
    // with colour(N) gated by opacity(N-2): solid areas survive, thin strokes
    // shred and edges fringe.
    reg [15:0] rgb_lat = 16'd0;
    reg        hs_lat  = 1'b0, vs_lat = 1'b0, hb_lat = 1'b1, vb_lat = 1'b1;

    always_ff @(posedge clk) if (cen_pix) begin
        rgb_lat <= pal_rgb;
        hs_lat  <= hsync_raw;
        vs_lat  <= vsync_raw;
        hb_lat  <= hblank_raw;
        vb_lat  <= vblank_raw;
    end

    assign HSync  = hs_lat;
    assign VSync  = vs_lat;
    assign HBlank = hb_lat;
    assign VBlank = vb_lat;

    wire visible = ~hb_lat & ~vb_lat;

    // robokid: RRRRGGGGBBBBRGBx (5 bits/channel, LSBs in the low nibble).
    // everything else: RGBx_444.
    wire [4:0] r5 = {rgb_lat[15:12], rgb_lat[3]};
    wire [4:0] g5 = {rgb_lat[11:8],  rgb_lat[2]};
    wire [4:0] b5 = {rgb_lat[7:4],   rgb_lat[1]};

    assign R = !visible ? 8'd0 : gfx_robokid ? {r5, r5[4:2]} : {rgb_lat[15:12], rgb_lat[15:12]};
    assign G = !visible ? 8'd0 : gfx_robokid ? {g5, g5[4:2]} : {rgb_lat[11:8],  rgb_lat[11:8]};
    assign B = !visible ? 8'd0 : gfx_robokid ? {b5, b5[4:2]} : {rgb_lat[7:4],   rgb_lat[7:4]};

endmodule
