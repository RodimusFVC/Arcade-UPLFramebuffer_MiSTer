//============================================================================
//
//  ChampionBaseball_MAIN.sv — main Z80 board: memory map, LS259 mainlatch,
//  watchdog, sprite position RAM, ALPHA-8201 MCU and the video instance.
//  The AY lives at 0x7000-0x7001 on THIS board, not the sound board
//  (champbas.cpp:579). Per-set differences are selected by set_id.
//
//============================================================================

module ChampionBaseball_MAIN
(
    input                clk,
    input                cen_cpu,        // 3.072 MHz enable
    input                cen_pix,        // 6.144 MHz enable
    input                reset,
    input                pause,

    // ---- controls (active LOW at the port, as MAME reads them)
    input         [7:0]  p1,
    input         [7:0]  p2,
    input         [7:0]  dsw,            // bit 7 is REPLACED internally, see below
    input         [7:0]  system,

    input         [7:0]  set_id,         // MRA index 5

    // ---- hiscore RAM access. Two windows, because the hiscore.dat entries
    input        [15:0]  hs_addr,
    input         [7:0]  hs_din,
    output        [7:0]  hs_dout,
    input                hs_we,
    input                hs_active,      // ram_intent_read | ram_intent_write

    input                crt_flip,       // OSD CRT Flip

    output       [12:0]  mcu_addr,
    input         [7:0]  mcu_data,

    // ---- main CPU ROM (champbas_rom index 0)
    output       [14:0]  rom_addr,
    input         [7:0]  rom_data,

    output       [13:0]  gfx_addr,
    input         [7:0]  gfx_data,
    output        [9:0]  prom_addr,
    input         [7:0]  prom_data,

    // gfx plane-2 source (champbas_rom index 8) — exctsccr family only
    output       [12:0]  gfx_p3_addr,
    input         [7:0]  gfx_p3_data,

    // 4bpp sprite gfx (champbas_rom index 9) — exctsccr family only
    output       [12:0]  gfx3_addr,
    input         [7:0]  gfx3_data,

    // ---- AY-3-8910 (main board, main CPU writes it)
    output        [7:0]  ay_din,
    output               ay_addr_wr,
    output               ay_data_wr,

    // ---- sound board latch
    output        [7:0]  sound_latch,
    output               sound_latch_wr,

    input                clk_dl,
    input                ioctl_download,
    input         [7:0]  ioctl_index,
    input        [24:0]  ioctl_addr,
    input         [7:0]  ioctl_data,
    input                ioctl_wr,

    // ---- video out
    output        [7:0]  video_r, video_g, video_b,
    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank
);

    ////////////////////////////////////////////////////////////////////////
    // Address decode — champbas_map (champbas.cpp:576)
    //   A000       R  P1     | A000-A007  W  LS259 write_d0
    //   A040       R  P2     | A060-A06F  W  spriteram (x/y only)
    //   A080       R  DSW (mirror 0020) | A080  W  soundlatch
    //   A0C0       R  SYSTEM | A0C0      W  watchdog reset
    ////////////////////////////////////////////////////////////////////////

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n;
    wire        cpu_halt_n;   // DIAG-REVERT-2026-08-23: sim-only observability, output-only

    // Per-set additions at 0x6000-0x68FF (champbas itself has NOTHING here).
    //   champbasj  (0x01) : 0x6000-0x63FF = ALPHA-8201 shared RAM  (:599)
    //   champbasja (0x02) : 0x6000-0x63FF = RAM, plus a fake protection read
    //                       at 0x6800-0x68FF                        (:603-608)
    //   champbasjb (0x03) : 0x6000-0x63FF = plain RAM, no protection (:611-615)
    // For champbasj the 8201 also processes that RAM, so plain RAM alone will
    // champbasj_map, so ALL of them get the 0x6000-0x63FF RAM — exctsccr_map
    // so they get the 0x6000-0x63FF shared-RAM window like every other J-family set.
    //                              || (set_id == 8'h07)
    wire set_has_extram = (set_id == 8'h01) || (set_id == 8'h02) || (set_id == 8'h03)
                       || (set_id == 8'h04) || (set_id == 8'h05)
                       || (set_id == 8'h07)
                       || ((set_id >= 8'h08) && (set_id <= 8'h0A));

    // Sets where a REAL ALPHA-8201 drives the shared RAM:
    //   champbasj 0x01 · talbot 0x07 · exctsccr 0x08 · exctscc2 0x09
    wire set_has_mcu    = (set_id == 8'h01) || (set_id == 8'h04) || (set_id == 8'h05)
                       || (set_id == 8'h07)
                       || (set_id == 8'h08) || (set_id == 8'h09);
    wire set_has_prot   = (set_id == 8'h02);

    // exctsccr (0x08) and exctscc2 (0x09) use exctsccr_map, which ADDS
    wire set_is_exctsccr_full = (set_id == 8'h08) || (set_id == 8'h09);

    // Only talbot's MCU security-checks the watchdog bit, and only talbot needs
    wire set_is_talbot = (set_id == 8'h07);

    wire cs_extram = set_has_extram && (A[15:10] == 6'b0110_00);   // 6000-63FF
    wire cs_prot   = set_has_prot   && (A[15:8]  == 8'h68);        // 6800-68FF
    wire cs_ram7c  = set_is_exctsccr_full && (A[15:10] == 6'b0111_11);  // 7C00-7FFF

    // champbb2/champbb2j add a SECOND ROM window at 0x7800-0x7FFF
    // 0x6000 (:1319). The MRA is already correct — it pads 0x1800 to place the ROM
    // 0x7800-0x7FFF must also win over cs_ay: in MAME the later `.rom()` entry
    wire set_has_rom78 = (set_id == 8'h04) || (set_id == 8'h05);   // champbb2, champbb2j
    wire cs_rom78 = set_has_rom78 && (A[15:11] == 5'b0111_1);      // 7800-7FFF
    wire cs_rom   = (A <  16'h6000) || cs_rom78;
    // 0x7000-0x7001 mirrored across 0x7000-0x7FFF (mirror mask 0x0FFE leaves A0 significant)
    wire cs_ay    = (A[15:12] == 4'h7) && !set_is_exctsccr_full && !cs_rom78;
    wire cs_vram  = (A[15:11] == 5'b1000_0);          // 8000-87FF
    wire cs_ram   = (A[15:11] == 5'b1000_1);          // 8800-8FFF
    wire cs_io    = (A[15:8]  == 8'hA0);

    // CPU write strobe: dead while paused. T80 holds its bus frozen, so an
    // ungated cen_cpu would re-fire the held write for the whole pause.
    wire cen_cpu_wr = cen_cpu & ~pause;

    wire mem_rd = ~mreq_n & ~rd_n;
    wire mem_wr = ~mreq_n & ~wr_n;

    // I/O sub-decode. A[7:6] picks the quadrant, matching MAME's A000/A040/A080/A0C0.
    wire io_q0 = cs_io & (A[7:6] == 2'b00);           // A000-A03F
    wire io_q1 = cs_io & (A[7:6] == 2'b01);           // A040-A07F
    wire io_q2 = cs_io & (A[7:6] == 2'b10);           // A080-A0BF  (DSW mirror 0x20 lands here)
    wire io_q3 = cs_io & (A[7:6] == 2'b11);           // A0C0-A0FF

    wire ls259_wr   = mem_wr & io_q0 & (A[5:3] == 3'b000);   // A000-A007
    wire spram_wr   = mem_wr & io_q1 & (A[5:4] == 2'b10);    // A060-A06F
    // exctsccr adds a SECOND sprite position RAM at A040-A04F (champbas.cpp:645)
    wire spram2_wr  = mem_wr & io_q1 & (A[5:4] == 2'b00);    // A040-A04F
    assign sound_latch_wr = mem_wr & io_q2;
    wire wdog_wr    = mem_wr & io_q3;

    assign sound_latch = cpu_dout;

    ////////////////////////////////////////////////////////////////////////
    // AY-3-8910 register select
    ////////////////////////////////////////////////////////////////////////

    localparam SET_CHAMPBB2J = 8'h05;                  // see any MRA's index-5 enumeration

    // exctsccr family = 0x08 exctsccr, 0x09 exctscc2, 0x0A exctsccrb
    wire is_exctsccr = (set_id >= 8'h08) && (set_id <= 8'h0A);

    wire ay_sel_inverted = (set_id == SET_CHAMPBB2J);
    wire ay_wr           = mem_wr & cs_ay;
    wire ay_is_addr      = ay_sel_inverted ? ~A[0] : A[0];

    assign ay_din     = cpu_dout;
    assign ay_addr_wr = ay_wr &  ay_is_addr;
    assign ay_data_wr = ay_wr & ~ay_is_addr;

    ////////////////////////////////////////////////////////////////////////
    // LS259 mainlatch @ 9D (champbas.cpp:970-978), written with D0.
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] mainlatch = 8'd0;

    always_ff @(posedge clk) begin
        if (reset_i) mainlatch <= 8'd0;
        else if (cen_cpu_wr && ls259_wr) mainlatch[A[2:0]] <= cpu_dout[0];
    end

    wire irq_mask     = mainlatch[0];
    wire gfx_bank     = mainlatch[2];
    // CRT Flip XORs into the game's own cocktail flip -- the one signal the whole
    wire flip_screen  = (~mainlatch[3]) ^ crt_flip;   // .invert() at :974 undone here
    wire palette_bank = mainlatch[4];

    ////////////////////////////////////////////////////////////////////////
    // Watchdog — set_vblank_count(0x10) at :983.
    // (:487, :745):  (0x10 - counter) >> 2 & 1
    // This is NOT a dip switch. The MRA deliberately omits bit 7 and the
    ////////////////////////////////////////////////////////////////////////

    reg [4:0] wdog_cnt = 5'd0;
    reg       vblank_d = 1'b0;
    wire      vblank_rise = video_vblank & ~vblank_d;

    // vblank_d MUST track video_vblank continuously, including during reset.
    // Measured: first $A080 read returned 0xA6 with wdog_cnt=1.
    always_ff @(posedge clk) begin
        vblank_d <= video_vblank;
        if (reset_i)          wdog_cnt <= 5'd0;
        else if (wdog_wr)     wdog_cnt <= 5'd0;
        // ~pause: video keeps running while paused, but the CPU cannot kick $A0C0,
        else if (vblank_rise && !pause) wdog_cnt <= wdog_cnt + 5'd1;
    end

    // 16 vblanks without an $A0C0 kick resets the CPU side (MAME:
    // Without it the boot spin at $003F ("jr c,$003F", a jump to itself) never
    // ends, and wdog_cnt runs past 0x10 so the bit-2 readback stops matching MAME
    // -- which is the bit Talbot's MCU security-checks against bit 2 of $8C00
    // (champbas.cpp:63-65). Video timing is deliberately NOT reset: the real board's
    reg [3:0] wdog_rst_cnt = 4'd0;
    always_ff @(posedge clk) begin
        if (reset)                     wdog_rst_cnt <= 4'd0;
        else if (set_is_talbot && wdog_cnt == 5'h10) wdog_rst_cnt <= 4'hF;
        else if (wdog_rst_cnt != 4'd0) wdog_rst_cnt <= wdog_rst_cnt - 4'd1;
    end
    wire reset_i = reset | (wdog_rst_cnt != 4'd0);

    // wdog_cnt counts UP from a kick, so it is ALREADY MAME's (0x10 - counter):
    // MAME's m_counter loads 0x10 and counts DOWN (watchdog.cpp:112 / :165).
    // Subtracting a second time inverted the bit on 6 frames in 8.
    wire       wdog_bit2 = wdog_cnt[2];

    wire [7:0] dsw_read = {wdog_bit2, dsw[6:0]};

    ////////////////////////////////////////////////////////////////////////
    // Sprite position RAM — A060-A06F, 16 bytes, WRITE ONLY from the CPU
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] spriteram [0:15];

    reg [7:0] spriteram2 [0:15];

    always_ff @(posedge clk) begin
        if (cen_cpu_wr && spram_wr)  spriteram[A[3:0]]  <= cpu_dout;
        if (cen_cpu_wr && spram2_wr) spriteram2[A[3:0]] <= cpu_dout;
    end

    ////////////////////////////////////////////////////////////////////////
    // instant, or sprites stay live while the background lags one frame and
    // sprite ATTRIBUTE window in main RAM ($8FF0 for champbas, $8800 for
    ////////////////////////////////////////////////////////////////////////

    wire        vsnap;
    wire [10:0] spr_attr_base = is_exctsccr ? 11'h000 : 11'h7F0;

    reg [7:0] spriteram_s  [0:15];
    reg [7:0] spriteram2_s [0:15];
    reg [7:0] spr_attr_live[0:15];
    reg [7:0] spr_attr_s   [0:15];

    integer si;
    always_ff @(posedge clk) begin
        // live shadow of the main-RAM sprite attribute window
        if (cen_cpu && mem_wr && cs_ram && (A[10:4] == spr_attr_base[10:4]))
            spr_attr_live[A[3:0]] <= cpu_dout;

        if (vsnap) begin
            for (si = 0; si < 16; si = si + 1) begin
                spriteram_s [si] <= spriteram [si];
                spriteram2_s[si] <= spriteram2[si];
                spr_attr_s  [si] <= spr_attr_live[si];
            end
        end
    end

    ////////////////////////////////////////////////////////////////////////
    // Main RAM — 8800-8FFF (2KB).
    // offset 0x7F0 within this 2KB region — NOT in spriteram.
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram_dout;
    wire [3:0] spr_attr_addr;
    wire [7:0] spr_attr_data;

    // Hiscore RAM windows. Talbot's table lives in VRAM (champbas_map:580 maps
    // 8000-87FF as vram) -- it is stamped there from ROM at $4001 and there is
    wire hs_sel_ram   = (hs_addr[15:11] == 5'b1000_1);    // 8800-8FFF main RAM
    wire hs_sel_ram7c = (hs_addr[15:10] == 6'b0111_11);   // 7C00-7FFF exctsccr
    wire hs_sel_vram  = (hs_addr[15:11] == 5'b1000_0);    // 8000-87FF tilemap
    wire [7:0] hs_ram_dout, hs_ram7c_dout;

    // Every source is a REGISTERED memory read, so the select is delayed one
    reg [1:0] hs_src_r;
    always_ff @(posedge clk)
        hs_src_r <= hs_sel_ram7c ? 2'd2 : hs_sel_vram ? 2'd1 : 2'd0;

    dpram_dc #(.widthad_a(11), .width_a(8)) main_ram
    (
        .clock_a(clk),
        .address_a(A[10:0]),
        .data_a(cpu_dout),
        .wren_a(cen_cpu_wr & mem_wr & cs_ram),
        .q_a(ram_dout),

        .clock_b(clk),
        .address_b(hs_addr[10:0]),
        .data_b(hs_din),
        .wren_b(hs_we & hs_sel_ram),
        .q_b(hs_ram_dout)
    );

    // dpram_dc port-B read, whose q is registered — the sprite FSM issues
    // Baseball. Swapping a BRAM for registers changes read latency; preserve it.
    reg [7:0] spr_attr_data_r;
    always_ff @(posedge clk) spr_attr_data_r <= spr_attr_s[spr_attr_addr];
    assign spr_attr_data = spr_attr_data_r;

    // Sprite position RAM read port (combinational — it is a register array)
    wire [3:0] spr_pos_addr;
    wire       spr_pos_bank;
    wire [7:0] spr_pos_data = spr_pos_bank ? spriteram2_s[spr_pos_addr]
                                           : spriteram_s[spr_pos_addr];

    ////////////////////////////////////////////////////////////////////////
    // Per-set extra RAM at 0x6000-0x63FF (1KB) — champbasj / ja / jb only.
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] extram_dout;

    dpram_dc #(.widthad_a(10), .width_a(8)) ext_ram
    (
        .clock_a(clk),
        .address_a(A[9:0]),
        .data_a(cpu_dout),
        .wren_a(cen_cpu_wr & mem_wr & cs_extram & ~set_has_mcu),
        .q_a(extram_dout),

        .clock_b(clk),
        .address_b(10'd0),
        .data_b(8'd0),
        .wren_b(1'b0),
        .q_b()
    );

    ////////////////////////////////////////////////////////////////////////
    // that page is the mirrored AY instead. Its absence is what produced the
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram7c_dout;

    dpram_dc #(.widthad_a(10), .width_a(8)) ram_7c
    (
        .clock_a(clk),
        .address_a(A[9:0]),
        .data_a(cpu_dout),
        .wren_a(cen_cpu_wr & mem_wr & cs_ram7c),
        .q_a(ram7c_dout),

        .clock_b(clk),
        .address_b(hs_addr[9:0]),
        .data_b(hs_din),
        .wren_b(hs_we & hs_sel_ram7c),
        .q_b(hs_ram7c_dout)
    );

    ////////////////////////////////////////////////////////////////////////
    // LS259 bit 6 -> mcu_start_w, bit 7 -> bus_dir_w (champbas.cpp:935-936).
    // OWNS that RAM, so the plain ext_ram above is write-disabled and the read
    // -> 96 kHz. 49.152 MHz / 96 kHz = 512, so 512-1 = 511.
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] mcu_ext_dout;

    alpha8201 #(.CEN_DIV(16'd511)) alpha_8201
    (
        .clk        (clk),
        .reset      (reset_i),

        .pause      (pause),
        .mcu_start  (mainlatch[6]),
        .bus_dir    (mainlatch[7]),

        .ext_addr   (A[9:0]),
        .ext_din    (cpu_dout),
        .ext_dout   (mcu_ext_dout),
        .ext_we     (cen_cpu_wr & mem_wr & cs_extram & set_has_mcu),

        .mcu_addr   (mcu_addr),
        .mcu_data   (mcu_data),

        .dbg_pc(), .dbg_op(), .dbg_illegal(),
        .dbg_mcu_ram_addr(), .dbg_mcu_rd_en(), .dbg_mcu_wr_en()
    );

    ////////////////////////////////////////////////////////////////////////
    // champbasja fake protection (champbas.cpp:532-563).
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] prot_dout = (A[0] ? 8'h80 : 8'h00) | (A[6] ? 8'h19 : 8'h00);

    ////////////////////////////////////////////////////////////////////////
    // Video
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] vram_dout;

    // VRAM has no spare port (port B drives the tilemap shadow copy), so the
    wire        hs_vram_own   = hs_active & hs_sel_vram;
    wire [10:0] vram_addr_cpu = hs_vram_own ? hs_addr[10:0] : A[10:0];
    wire  [7:0] vram_din_cpu  = hs_vram_own ? hs_din        : cpu_dout;
    wire        vram_we_cpu   = hs_vram_own ? hs_we
                                            : (cen_cpu_wr & mem_wr & cs_vram);

    assign hs_dout = (hs_src_r == 2'd2) ? hs_ram7c_dout
                   : (hs_src_r == 2'd1) ? vram_dout
                                        : hs_ram_dout;

    ChampionBaseball_VIDEO video
    (
        .clk(clk),
        .cen_pix(cen_pix),
        .reset(reset),

        .cpu_vram_addr(vram_addr_cpu),
        .cpu_vram_din(vram_din_cpu),
        .cpu_vram_we(vram_we_cpu),
        .cpu_vram_dout(vram_dout),

        .flip_screen(flip_screen),
        .vsnap(vsnap),                 // DETEAR-2026-08-01
        .gfx_bank(gfx_bank),
        .palette_bank(palette_bank),

        .is_exctsccr(is_exctsccr),
        .is_talbot(set_is_talbot),

        .gfx_addr(gfx_addr),
        .gfx_data(gfx_data),
        .prom_addr(prom_addr),
        .prom_data(prom_data),
        .gfx_p3_addr(gfx_p3_addr),
        .gfx_p3_data(gfx_p3_data),
        .gfx3_addr(gfx3_addr),
        .gfx3_data(gfx3_data),

        .spr_pos_addr(spr_pos_addr),
        .spr_pos_bank(spr_pos_bank),
        .spr_pos_data(spr_pos_data),
        .spr_attr_addr(spr_attr_addr),
        .spr_attr_data(spr_attr_data),

        .clk_dl(clk_dl),
        .ioctl_download(ioctl_download),
        .ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),
        .ioctl_data(ioctl_data),
        .ioctl_wr(ioctl_wr),

        .VGA_R(video_r),
        .VGA_G(video_g),
        .VGA_B(video_b),
        .HSync(video_hsync),
        .VSync(video_vsync),
        .HBlank(video_hblank),
        .VBlank(video_vblank)
    );

    ////////////////////////////////////////////////////////////////////////
    // CPU read mux
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] cpu_din;

    always_comb begin
        if      (cs_rom)    cpu_din = rom_data;
        else if (cs_prot)   cpu_din = prot_dout;      // champbasja, before cs_extram
        else if (cs_extram) cpu_din = set_has_mcu ? mcu_ext_dout : extram_dout;
        else if (cs_ram7c)  cpu_din = ram7c_dout;    // EXCTSCCR-MAP-FIX-2026-07-31
        else if (cs_vram) cpu_din = vram_dout;
        else if (cs_ram)  cpu_din = ram_dout;
        else if (io_q0)   cpu_din = p1;
        else if (io_q1)   cpu_din = p2;
        else if (io_q2)   cpu_din = dsw_read;
        else if (io_q3)   cpu_din = system;
        else              cpu_din = 8'hFF;
    end

    assign rom_addr = A[14:0];

    ////////////////////////////////////////////////////////////////////////
    // IRQ — vblank asserts IRQ0 only while irq_mask; irq_enable_w(0) clears it
    ////////////////////////////////////////////////////////////////////////

    reg irq_pending = 1'b0;

    always_ff @(posedge clk) begin
        if (reset_i)          irq_pending <= 1'b0;
        else if (!irq_mask)   irq_pending <= 1'b0;
        else if (vblank_rise) irq_pending <= 1'b1;
    end

    wire int_n = ~(irq_pending & irq_mask);

    ////////////////////////////////////////////////////////////////////////
    // Z80
    ////////////////////////////////////////////////////////////////////////

    T80s cpu
    (
        .RESET_n(~reset_i),
        .CLK(clk),
        .CEN(cen_cpu & ~pause),
        .WAIT_n(1'b1),
        .INT_n(int_n),
        .NMI_n(1'b1),
        .BUSRQ_n(1'b1),
        .HALT_n(cpu_halt_n),   // DIAG-REVERT-2026-08-23: was unconnected
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
