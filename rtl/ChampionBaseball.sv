//============================================================================
//
//  ChampionBaseball.sv — game top level: main board, sound board and ROMs.
//  Copyright (C) 2026 Rodimus
//
//    49.152 / 16 = 3.072 MHz = XTAL 18.432 / 6  -> both Z80s
//    49.152 /  8 = 6.144 MHz = XTAL 18.432 / 3  -> pixel clock
//
//============================================================================

module ChampionBaseball
(
    input                reset,
    input                clk_49m,

    // ---- controls, already assembled into MAME port order by the wrapper
    input          [7:0] p1,
    input          [7:0] p2,
    input          [7:0] dsw,          // bit 7 is ignored; MAIN substitutes watchdog_bit2()
    input          [7:0] system,

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

    output         [7:0] set_id,       // MRA index 5, exposed for the wrapper's OSD/rotation logic

    // ---- hiscore RAM access (routed inside MAIN to main RAM or the 7C00 block)
    input         [15:0] hs_addr,
    input          [7:0] hs_din,
    output         [7:0] hs_dout,
    input                hs_we,
    input                hs_active,

    input                crt_flip,     // OSD CRT Flip — XORed into flip_screen in MAIN

    input                pause
);

//------------------------------------------------------- Clock enables -------------------------------------------------------//

reg [4:0] cen_cnt = 5'd0;
always_ff @(posedge clk_49m) cen_cnt <= cen_cnt + 5'd1;

wire cen_cpu = (cen_cnt[3:0] == 4'd0);   // 1-in-16 -> 3.072 MHz  (18.432/6)
wire cen_pix = (cen_cnt[2:0] == 3'd0);   // 1-in-8  -> 6.144 MHz  (18.432/3)
wire cen_ay  = (cen_cnt      == 5'd0);   // 1-in-32 -> 1.536 MHz  (18.432/12)

assign ce_pix = cen_pix;

//------------------------------------------------------- ROM regions ---------------------------------------------------------//

wire [14:0] maincpu_addr;
wire  [7:0] maincpu_data;
wire [15:0] audiocpu_addr;
wire  [7:0] audiocpu_data;
wire [13:0] gfx_p01_addr;
wire  [7:0] gfx_p01_data;
wire  [9:0] prom_addr;
wire  [7:0] prom_data;
wire [12:0] gfx_p3_addr;
wire  [7:0] gfx_p3_data;
wire [12:0] gfx3_addr;
wire  [7:0] gfx3_data;

champbas_rom rom
(
    .clk(clk_49m),
    .clk_dl(clk_49m),

    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .ioctl_wr(ioctl_wr),

    .set_id(set_id),

    .maincpu_addr(maincpu_addr),   .maincpu_data(maincpu_data),
    .gfx_p01_addr(gfx_p01_addr),   .gfx_p01_data(gfx_p01_data),
    .prom_addr(prom_addr),         .prom_data(prom_data),

    .audiocpu_addr(audiocpu_addr), .audiocpu_data(audiocpu_data),

    .gfx_p3_addr(gfx_p3_addr),     .gfx_p3_data(gfx_p3_data),

    .gfx3_addr(gfx3_addr),         .gfx3_data(gfx3_data),

    // alpha8201 instance inside ChampionBaseball_MAIN.
    .mcu_addr(mcu_addr),           .mcu_data(mcu_data)
);

wire [12:0] mcu_addr;
wire  [7:0] mcu_data;

//------------------------------------------------------- Main board ----------------------------------------------------------//

wire [7:0] ay_din;
wire       ay_addr_wr, ay_data_wr;
wire [7:0] sound_latch;
wire       sound_latch_wr;

ChampionBaseball_MAIN main_board
(
    .mcu_addr(mcu_addr),
    .mcu_data(mcu_data),

    .clk(clk_49m),
    .cen_cpu(cen_cpu),
    .cen_pix(cen_pix),
    .reset(reset),
    .pause(pause),

    .p1(p1),
    .p2(p2),
    .dsw(dsw),
    .system(system),

    .set_id(set_id),

    .hs_addr(hs_addr),
    .hs_din(hs_din),
    .hs_dout(hs_dout),
    .hs_we(hs_we),
    .hs_active(hs_active),

    .crt_flip(crt_flip),

    .rom_addr(maincpu_addr),
    .rom_data(maincpu_data),

    .gfx_addr(gfx_p01_addr),
    .gfx_data(gfx_p01_data),
    .prom_addr(prom_addr),
    .prom_data(prom_data),

    .gfx_p3_addr(gfx_p3_addr),
    .gfx_p3_data(gfx_p3_data),
    .gfx3_addr(gfx3_addr),
    .gfx3_data(gfx3_data),

    .ay_din(ay_din),
    .ay_addr_wr(ay_addr_wr),
    .ay_data_wr(ay_data_wr),

    .sound_latch(sound_latch),
    .sound_latch_wr(sound_latch_wr),

    .clk_dl(clk_49m),
    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .ioctl_wr(ioctl_wr),

    .video_r(video_r),
    .video_g(video_g),
    .video_b(video_b),
    .video_hsync(video_hsync),
    .video_vsync(video_vsync),
    .video_hblank(video_hblank),
    .video_vblank(video_vblank)
);

//------------------------------------------------------- Sound board ---------------------------------------------------------//

// have an ENTIRELY DIFFERENT sound board — own 14.318181 MHz crystal, 4 AYs on
// champbas board. exctsccrb (0x0A) is deliberately NOT included: that bootleg
wire use_exctsccr_snd = (set_id == 8'h08) || (set_id == 8'h09);

wire signed [15:0] snd_mono;
wire signed [15:0] snd_exctsccr;
wire        [15:0] audiocpu_addr_cb;
wire        [15:0] audiocpu_addr_es;

// Only one board is selected at a time; both share the index-1 audio ROM port.
assign audiocpu_addr = use_exctsccr_snd ? audiocpu_addr_es : audiocpu_addr_cb;

ChampionBaseball_SND snd_board
(
    .clk(clk_49m),
    .cen_cpu(cen_cpu),
    .cen_ay(cen_ay),
    .reset(reset | use_exctsccr_snd),
    .pause(pause),

    .sound_latch(sound_latch),
    .sound_latch_wr(sound_latch_wr),

    // The AY physically lives on the MAIN board and is written by the MAIN CPU
    .ay_din(ay_din),
    .ay_addr_wr(ay_addr_wr),
    .ay_data_wr(ay_data_wr),

    .rom_addr(audiocpu_addr_cb),
    .rom_data(audiocpu_data),

    .sound_out(snd_mono)
);

ExcitingSoccer_SND snd_board_es
(
    .clk(clk_49m),
    .reset(reset | ~use_exctsccr_snd),
    .pause(pause),

    .is_exctscc2(set_id == 8'h09),

    .sound_latch(sound_latch),
    .sound_latch_wr(sound_latch_wr),

    .rom_addr(audiocpu_addr_es),
    .rom_data(audiocpu_data),

    .sound_out(snd_exctsccr)
);

wire signed [15:0] snd_sel = use_exctsccr_snd ? snd_exctsccr : snd_mono;

// Both boards are mono — one SPEAKER each (champbas.cpp:998, :1115)
assign sound_l = snd_sel;
assign sound_r = snd_sel;

endmodule
