//============================================================================
//
//  UPLFramebuffer_VIDEO.sv — raster, palette and the 8x8 foreground tilemap.
//
//  The 512x512 background tilemap and the sprite framebuffer are not built yet;
//  transparent foreground pixels currently show black.
//
//============================================================================

module UPLFramebuffer_VIDEO
(
    input               clk,
    input               cen_pix,         // pixel clock enable (target 6.0 MHz)
    input               reset,

    input               flip_screen,

    // DIAG-REVERT-2026-08-30: 1 = ignore fg_videoram and the palette, draw char
    // tiles 0.. in order as greyscale. The screen becomes the gfx ROM itself.
    input               DIAG_TILEVIEW,

    // ---- fg tilemap RAM (in MAIN)
    output       [10:0] fg_vram_addr,
    input         [7:0] fg_vram_data,

    // ---- char ROM (SDRAM, via upl_rom)
    output       [14:0] char_addr,
    output              char_req,
    input               char_ack,
    input         [7:0] char_data,

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
        if (reset) begin
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
    // Pixel out. Palette RAM adds a cycle, so the syncs are delayed to match
    // (see Common-Pitfalls: pixel pipeline needs matched sync delay).
    ////////////////////////////////////////////////////////////////////////

    wire [2:0] px    = flipx ? ~h_cnt[2:0] : h_cnt[2:0];
    wire [4:0] shift = {2'd0, ~px} << 2;          // nibble 7 is the leftmost pixel
    wire [3:0] pix   = (rowbits >> shift) & 32'hF;

    assign pal_index = {2'b10, color, pix};        // fg palette base 0x200

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

    always_ff @(posedge clk) if (cen_pix) begin
        // DIAG-REVERT-2026-08-30: original -> rgb_lat <= pal_rgb;
        rgb_lat <= pal_or_grey;
        opq_lat <= |pix;
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

    assign R = visible ? {rgb_lat[15:12], rgb_lat[15:12]} : 8'd0;
    assign G = visible ? {rgb_lat[11:8],  rgb_lat[11:8]}  : 8'd0;
    assign B = visible ? {rgb_lat[7:4],   rgb_lat[7:4]}   : 8'd0;

endmodule
