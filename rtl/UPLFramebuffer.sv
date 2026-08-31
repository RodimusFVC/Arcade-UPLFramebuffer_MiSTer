//============================================================================
//
//  UPLFramebuffer.sv — game top level: main board, sound board, video and ROMs.
//  Copyright (C) 2026 Rodimus
//
//    60 / 10 = 6.0 MHz = XTAL 12 / 2 -> main Z80 + pixel clock
//    60 / 12 = 5.0 MHz = 5 MHz XTAL  -> sound Z80
//    60 / 40 = 1.5 MHz = XTAL 12 / 8 -> both YM2203
//
//============================================================================

module UPLFramebuffer
(
    input                reset,
    input                por_reset,     // power-on only; never includes ioctl_download
    input                clk_60m,

    // ---- controls, assembled into MAME port order by the wrapper (active low)
    input          [7:0] keycoin,
    input          [7:0] pad1,
    input          [7:0] pad2,
    input          [7:0] dsw1,
    input          [7:0] dsw2,

    // ---- video
    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank,
    output               ce_pix,
    output         [7:0] video_r, video_g, video_b,

    // ---- audio
    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    // ---- ROM download
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,
    input                ioctl_download,
    output               ioctl_wait,

    output         [7:0] set_id,

    input                crt_flip,
    input                pause,

    // DIAG-REVERT-2026-08-30
    input          [1:0] rd_mode,        // SDRAM read latch: 0=Early 1=Normal 2=Late
    input                diag_tileview,
    input          [1:0] diag_bgmode,    // 0 Off 1 Swatch 2 TileROM 3 VRAMCol
    input                diag_sproff,    // 1 = drop the sprite layer out of the mix

    // ---- SDRAM
    inout  [15:0] SDRAM_DQ,
    output [12:0] SDRAM_A,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output  [1:0] SDRAM_BA,
    output        SDRAM_nCS,
    output        SDRAM_nWE,
    output        SDRAM_nRAS,
    output        SDRAM_nCAS,
    output        SDRAM_CKE,
    output        SDRAM_CLK
);

//------------------------------------------------------- Clock enables -------------------------------------------------------//

// All four rates are exact integer divides of the 60 MHz fabric - no fractional
// cen, no jitter. div4 advances once per cen_cpu pulse, so cen_ym is 6/4 MHz.
reg [3:0] div10 = 4'd0;   // mod-10 -> 6 MHz
reg [3:0] div12 = 4'd0;   // mod-12 -> 5 MHz
reg [1:0] div4  = 2'd0;   // mod-4 of the 6 MHz tick -> 1.5 MHz

always_ff @(posedge clk_60m) begin
    div10 <= (div10 == 4'd9)  ? 4'd0 : div10 + 4'd1;
    div12 <= (div12 == 4'd11) ? 4'd0 : div12 + 4'd1;
    if (div10 == 4'd9) div4 <= (div4 == 2'd3) ? 2'd0 : div4 + 2'd1;
end

wire cen_cpu = (div10 == 4'd0);                    // 6.0 MHz  main Z80
wire cen_pix = (div10 == 4'd0);                    // 6.0 MHz  pixel clock
wire cen_snd = (div12 == 4'd0);                    // 5.0 MHz  sound Z80
wire cen_ym  = (div10 == 4'd0) && (div4 == 2'd0);  // 1.5 MHz  both YM2203

assign ce_pix = cen_pix;

//------------------------------------------------------- ROM regions ---------------------------------------------------------//

wire [15:0] maincpu_addr;   wire [3:0] maincpu_bank;   wire [7:0] maincpu_data;
wire [15:0] audiocpu_addr;  wire audiocpu_m1;          wire [7:0] audiocpu_data;
wire [14:0] char_addr;      wire char_req, char_ack;   wire [7:0] char_data;
wire [18:0] tile1_addr;     wire tile1_req, tile1_ack; wire [7:0] tile1_data;
wire [17:0] spr_addr;       wire spr_req, spr_ack;     wire [7:0] spr_data;
wire [15:0] fb_raddr;       wire [7:0] fb_rdata;       wire spr_draw_window;

upl_rom rom
(
    .clk(clk_60m),
    .por_reset(por_reset),
    .rd_mode(rd_mode),          // DIAG-REVERT-2026-08-30

    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .ioctl_wr(ioctl_wr),
    .ioctl_wait(ioctl_wait),

    .set_id(set_id),

    .maincpu_addr(maincpu_addr), .maincpu_bank(maincpu_bank), .maincpu_data(maincpu_data),
    .audiocpu_addr(audiocpu_addr), .audiocpu_m1(audiocpu_m1), .audiocpu_data(audiocpu_data),

    .char_addr(char_addr),  .char_req(char_req),  .char_ack(char_ack),  .char_data(char_data),
    .spr_addr(spr_addr), .spr_req(spr_req), .spr_ack(spr_ack), .spr_data(spr_data),
    .tile1_addr(tile1_addr), .tile1_req(tile1_req), .tile1_ack(tile1_ack), .tile1_data(tile1_data),
    .tile2_addr(19'd0), .tile2_req(1'b0), .tile2_ack(), .tile2_data(),
    .tile3_addr(19'd0), .tile3_req(1'b0), .tile3_ack(), .tile3_data(),
    .pcm_addr(16'd0),   .pcm_req(1'b0),   .pcm_ack(),   .pcm_data(),

    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
    .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
);

//------------------------------------------------------- Main board ----------------------------------------------------------//

wire [7:0] sound_latch;
wire       sound_latch_wr;
wire       snd_reset;
wire       flip_screen, sprite_overdraw, bg_enable;
wire [15:0] bg_scrollx, bg_scrolly;

wire [10:0] fg_vram_addr;  wire [7:0] fg_vram_data;
wire [10:0] bg_vram_addr;  wire [7:0] bg_vram_data;
wire [12:0] work_addr;     wire [7:0] work_data;
wire  [9:0] pal_index;     wire [15:0] pal_rgb;

UPLFramebuffer_MAIN main_board
(
    .clk(clk_60m),
    .cen_cpu(cen_cpu),
    .reset(reset),
    .pause(pause),

    .set_id(set_id),

    .keycoin(keycoin), .pad1(pad1), .pad2(pad2), .dsw1(dsw1), .dsw2(dsw2),

    .maincpu_addr(maincpu_addr), .maincpu_bank(maincpu_bank), .maincpu_data(maincpu_data),

    .sound_latch(sound_latch), .sound_latch_wr(sound_latch_wr), .snd_reset(snd_reset),

    .crt_flip(crt_flip),
    .flip_screen(flip_screen),
    .sprite_overdraw(sprite_overdraw),
    .bg_scrollx(bg_scrollx), .bg_scrolly(bg_scrolly), .bg_enable(bg_enable),

    .fg_vram_addr(fg_vram_addr), .fg_vram_data(fg_vram_data),
    .bg_vram_addr(bg_vram_addr), .bg_vram_data(bg_vram_data),
    .work_addr(work_addr),       .work_data(work_data),
    .pal_index(pal_index),       .pal_rgb(pal_rgb),

    .vblank(video_vblank)
);



//------------------------------------------------------- Video ---------------------------------------------------------------//

UPLFramebuffer_VIDEO video
(
    .clk(clk_60m),
    .cen_pix(cen_pix),
    .reset(reset),

    .flip_screen(flip_screen),
    .DIAG_TILEVIEW(diag_tileview),   // DIAG-REVERT-2026-08-30
    .DIAG_BGMODE(diag_bgmode),       // DIAG-REVERT-2026-08-30
    .DIAG_SPROFF(diag_sproff),       // DIAG-REVERT-2026-08-30

    .fg_vram_addr(fg_vram_addr), .fg_vram_data(fg_vram_data),
    .bg_vram_addr(bg_vram_addr), .bg_vram_data(bg_vram_data),
    .bg_scrollx(bg_scrollx), .bg_scrolly(bg_scrolly), .bg_enable(bg_enable),
    .char_addr(char_addr), .char_req(char_req), .char_ack(char_ack), .char_data(char_data),
    .tile1_addr(tile1_addr), .tile1_req(tile1_req), .tile1_ack(tile1_ack), .tile1_data(tile1_data),
    .fb_raddr(fb_raddr), .fb_rdata(fb_rdata), .spr_draw_window(spr_draw_window),
    .pal_index(pal_index), .pal_rgb(pal_rgb),

    .HSync(video_hsync), .VSync(video_vsync),
    .HBlank(video_hblank), .VBlank(video_vblank),
    .R(video_r), .G(video_g), .B(video_b),
    .DIAG_bst(), .DIAG_btidx(), .DIAG_bty(), .DIAG_bstart()   // DIAG-REVERT-2026-08-30
);

//------------------------------------------------------- Sprites -------------------------------------------------------------//

UPLFramebuffer_SPRITE sprites
(
    .clk(clk_60m),
    .reset(reset),

    .flip_screen(flip_screen),
    .overdraw(sprite_overdraw),
    .draw_window(spr_draw_window),

    .spr_ram_addr(work_addr), .spr_ram_data(work_data),
    .spr_addr(spr_addr), .spr_req(spr_req), .spr_ack(spr_ack), .spr_data(spr_data),

    .fb_raddr(fb_raddr), .fb_rdata(fb_rdata),
    .busy()
);

//------------------------------------------------------- Sound board ---------------------------------------------------------//

wire signed [15:0] snd_mono;

UPLFramebuffer_SND snd_board
(
    .clk(clk_60m),
    .cen_cpu(cen_snd),
    .cen_ym(cen_ym),
    .reset(reset | snd_reset),
    .pause(pause),

    .sound_latch(sound_latch),
    .sound_latch_wr(sound_latch_wr),

    .rom_addr(audiocpu_addr),
    .rom_data(audiocpu_data),
    .rom_m1(audiocpu_m1),
    .pcm_cmd(),                 // ninjakd2 sample player, wired with the PCM engine
    .pcm_cmd_wr(),

    .sound_out(snd_mono)
);

// Mono board - one SPEAKER (ninjakd2.cpp:1575)
assign sound_l = snd_mono;
assign sound_r = snd_mono;

endmodule
