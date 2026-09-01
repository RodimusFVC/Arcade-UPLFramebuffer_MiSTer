//============================================================================
//
//  UPLFramebuffer_BGLAYER.sv — one 16x16 background tilemap layer.
//
//  ninjakd2/mnight/arkarea have a single layer; robokid and omegaf have three
//  identical ones (ninjakd2.cpp robokid_get_bg_tile_info<Layer>), so this is
//  instantiated three times and the caller supplies each layer's VRAM port,
//  tile ROM client and scroll registers.
//
//  Extracted unchanged from UPLFramebuffer_VIDEO.sv, where it was HW-proven on
//  ninjakd2, mnight, arkarea and robokid. The two structural rules below cost a
//  bug each during that bring-up -- do not "simplify" either one.
//
//============================================================================

module UPLFramebuffer_BGLAYER #(
    parameter [8:0] H_TOTAL = 9'd384,
    parameter [8:0] V_TOTAL = 9'd262
)
(
    input               clk,
    input               cen_pix,
    input               reset,
    input               fetch_en,        // low outside the visible fetch window
    input               en,              // layer enabled; gates FETCHING, not just output --
                                         // a disabled layer must not spend SDRAM slots, or
                                         // the single-layer sets lose 2/3 of the arbiter

    input         [8:0] h_cnt,
    input         [8:0] v_cnt,
    input               flip_screen,

    input               gfx_robokid,     // 12-bit tile index, no flip, col-aligned sub-tiles
    input               is_omegaf,       // 128x32 map instead of 32x32
    input               bg_mnight,       // hi bit4 is tile bit 10 rather than flipx

    input        [15:0] scrollx,
    input        [15:0] scrolly,

    input         [1:0] DIAG_BGMODE,     // DIAG-REVERT-2026-08-30

    output       [12:0] vram_addr,
    input         [7:0] vram_data,

    output       [18:0] rom_addr,
    output              rom_req,
    input               rom_ack,
    input         [7:0] rom_data,

    output        [3:0] color,
    output        [3:0] pix
);

    ////////////////////////////////////////////////////////////////////////
    // The fetch is RASTER-aligned (h_cnt[3:0]), not map-tile aligned. Phase-locking
    // the window to map tiles cannot work: the boundary would have to line up with
    // the end-of-line wrap as well, and it only does when the scroll happens to be a
    // multiple of 16. Instead a 16-pixel screen group spans at most TWO map tiles, so
    // the display keeps both and selects per pixel on the map column.
    //
    // Pipeline, one group = 16 pixels:
    //   cur <= nxt, nxt <= new, and a fetch for the tile two groups ahead starts.
    // The +32 lookahead is what makes nxt already valid when a group straddles.
    ////////////////////////////////////////////////////////////////////////

    wire [8:0] fh = (h_cnt >= H_TOTAL - 9'd32) ? (h_cnt - (H_TOTAL - 9'd32)) : (h_cnt + 9'd32);
    wire [8:0] fv = (h_cnt >= H_TOTAL - 9'd32) ? ((v_cnt == V_TOTAL - 1'd1) ? 9'd0 : v_cnt + 1'd1) : v_cnt;

    // Full 9 bits, no truncation to the 256-wide screen. The lookahead runs past 255
    // into hblank, and those positions still have a well-defined map column -- it is
    // the one a straddling group at the end of the visible line needs. Truncating
    // here cost two separate bugs, both showing as "correct only at scroll multiples
    // of 16". The flipped case falls out of the same mod arithmetic.
    wire [8:0] fsx = flip_screen ? (9'd255 - fh) : fh;
    wire [8:0] fsy = flip_screen ? (9'd255 - fv) : fv;

    // X is 11-bit because omegaf's map is 128x32 tiles = 2048 px wide; the other sets
    // are 32x32 = 512 and mask back to 5 column bits below, keeping their mod-512 wrap.
    wire [10:0] fmx = {2'b00, fsx} + scrollx[10:0];
    wire  [8:0] fmy = fsy + scrolly[8:0];

    // map coordinates of the pixel being displayed, and of the next group's first
    wire [8:0]  h_p1 = (h_cnt == H_TOTAL - 1'd1) ? 9'd0 : h_cnt + 1'd1;
    wire [8:0]  dsx  = flip_screen ? (9'd255 - h_cnt) : h_cnt;
    wire [8:0]  dsx1 = flip_screen ? (9'd255 - h_p1)  : h_p1;
    wire [10:0] dmx  = {2'b00, dsx}  + scrollx[10:0];
    wire [10:0] dmx1 = {2'b00, dsx1} + scrollx[10:0];

    wire [6:0] bg_fcol  = is_omegaf ? fmx[10:4]  : {2'b00, fmx[8:4]};
    wire [6:0] bg_dcol  = is_omegaf ? dmx[10:4]  : {2'b00, dmx[8:4]};
    wire [6:0] bg_dcol1 = is_omegaf ? dmx1[10:4] : {2'b00, dmx1[8:4]};
    wire [4:0] bg_frow  = fmy[8:4];

    // Scan. ninjakd2/mnight are plain row-major; robokid_bg_scan and omegaf_bg_scan
    // both put the HIGH column bits ABOVE the row, i.e. 16-column strips:
    //   (col & 0x0f) | ((row & 0x1f) << 4) | ((col & mask) << 5)
    wire [11:0] bg_scan = gfx_robokid ? {bg_fcol[6:4], bg_frow, bg_fcol[3:0]}
                                      : {2'b00, bg_frow, bg_fcol[4:0]};

    wire bg_group_end = (h_cnt[3:0] == 4'd15);

    reg  [3:0] bst = 4'd0;
    reg  [2:0] bj  = 3'd0;
    reg  [7:0] blo = 8'd0, bhi = 8'd0;

    // latched at the start of the fetch so nothing drifts as h_cnt advances
    reg [11:0] bfetch_tidx = 12'd0;
    reg  [3:0] bfetch_my   = 4'd0;

    reg [63:0] bg_new_rowbits = 64'd0;  reg [3:0] bg_new_color = 4'd0;  reg bg_new_flipx = 1'b0;
    reg [63:0] bg_nxt_rowbits = 64'd0;  reg [3:0] bg_nxt_color = 4'd0;  reg bg_nxt_flipx = 1'b0;
    reg [63:0] bg_cur_rowbits = 64'd0;  reg [3:0] bg_cur_color = 4'd0;  reg bg_cur_flipx = 1'b0;
    reg  [6:0] bg_cur_col = 7'd0;

    reg [12:0] bg_addr_r;
    reg [18:0] rom_addr_r;
    reg        rom_req_r;

    assign vram_addr = bg_addr_r;
    assign rom_addr  = rom_addr_r;
    assign rom_req   = rom_req_r;

    // robokid/omegaf: tile = ((hi&0x10)<<7)|((hi&0x20)<<5)|((hi&0xc0)<<2)|lo, a 12-bit
    // index using all of hi[7:4], and tileinfo.set() passes flip 0 -- those sets have NO
    // bg flip at all. mnight/arkarea reuse hi bit4 as tile bit 10 (so no flipx either);
    // ninjakd2 keeps a 10-bit index with flipx on bit4.
    wire [11:0] bg_tile  = (DIAG_BGMODE == 2'd2) ? bfetch_tidx
                         : gfx_robokid           ? {bhi[4], bhi[5], bhi[7:6], blo}
                                                 : {1'b0, bg_mnight & bhi[4], bhi[7:6], blo};
    wire        bg_flipy = gfx_robokid ? 1'b0 : bhi[5];
    wire  [3:0] bg_ty    = bg_flipy ? ~bfetch_my : bfetch_my;

    // 128 bytes per 16x16 tile, four 8x8 sub-tiles. row_2x2 is 0 1 / 2 3, col_2x2
    // (robokid/omegaf) is 0 2 / 1 3 -- the two sub-tile select bits swap
    // (emu/video/generic.cpp:145,175).
    wire bg_sub_hi = gfx_robokid ? bj[2]    : bg_ty[3];
    wire bg_sub_lo = gfx_robokid ? bg_ty[3] : bj[2];
    wire [18:0] bg_rom_addr = {bg_tile, bg_sub_hi, bg_sub_lo, bg_ty[2:0], bj[1:0]};

    always_ff @(posedge clk) begin
        if (reset || !fetch_en || !en) begin
            bst <= 4'd0; rom_req_r <= 1'b0; bj <= 3'd0;
            if (reset) bg_cur_col <= 7'd0;
        end else begin
            if (cen_pix && bg_group_end) begin
                bg_cur_rowbits <= bg_nxt_rowbits;
                bg_cur_color   <= bg_nxt_color;
                bg_cur_flipx   <= bg_nxt_flipx;
                bg_cur_col     <= bg_dcol1;
                bg_nxt_rowbits <= bg_new_rowbits;
                bg_nxt_color   <= bg_new_color;
                bg_nxt_flipx   <= bg_new_flipx;
                bst <= 4'd0;
                bj  <= 3'd0;
            end else begin
                case (bst)
                    4'd0: begin
                        bfetch_tidx <= bg_scan;
                        bfetch_my   <= fmy[3:0];
                        bg_addr_r   <= {bg_scan, 1'b0};
                        bst         <= 4'd1;
                    end
                    4'd1: bst <= 4'd2;                                  // BRAM latency
                    4'd2: begin blo <= vram_data; bg_addr_r <= {bfetch_tidx, 1'b1}; bst <= 4'd3; end
                    4'd3: bst <= 4'd4;
                    4'd4: begin
                        bhi          <= vram_data;
                        bg_new_color <= vram_data[3:0];
                        bg_new_flipx <= (gfx_robokid | bg_mnight) ? 1'b0 : vram_data[4];
                        bst          <= 4'd5;
                    end
                    4'd5: begin rom_addr_r <= bg_rom_addr; rom_req_r <= 1'b1; bst <= 4'd6; end
                    4'd6: if (rom_ack) begin
                              // j ascends 0..7 and byte j belongs at [63-8j -: 8],
                              // which is exactly a byte-wide shift left.
                              bg_new_rowbits <= {bg_new_rowbits[55:0], rom_data};
                              rom_req_r <= 1'b0;
                              if (bj == 3'd7) bst <= 4'd7;
                              else begin bj <= bj + 3'd1; bst <= 4'd5; end
                          end
                    default: ;
                endcase
            end
        end
    end

    // Display select: a screen group spans at most two map tiles, so pick between
    // cur and nxt on the map column of this pixel.
    wire        bg_use_nxt   = (bg_dcol != bg_cur_col);
    wire [63:0] bg_sel_bits  = bg_use_nxt ? bg_nxt_rowbits : bg_cur_rowbits;
    wire        bg_sel_flipx = bg_use_nxt ? bg_nxt_flipx   : bg_cur_flipx;

    wire [3:0] bg_tx  = bg_sel_flipx ? ~dmx[3:0] : dmx[3:0];
    wire [5:0] bshift = {2'd0, ~bg_tx} << 2;         // nibble 15 is the leftmost pixel

    assign color = bg_use_nxt ? bg_nxt_color : bg_cur_color;
    assign pix   = (DIAG_BGMODE == 2'd3) ? 4'd1 : ((bg_sel_bits >> bshift) & 64'hF);

endmodule
