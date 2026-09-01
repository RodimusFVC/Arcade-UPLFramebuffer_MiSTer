//============================================================================
//
//  upl_rom.sv — ROM storage for the UPL framebuffer hardware.
//
//  CPU ROMs live in BRAM; graphics, PCM and PROMs live in SDRAM. Region base
//  addresses and the MRA index map are fixed here and in releases/*.mra.
//
//============================================================================

module upl_rom
(
    input                clk,             // 60 MHz fabric; also clocks the SDRAM controller
    input                por_reset,       // power-on ONLY. Must never include ioctl_download.

    // SDRAM read latch. sdram.sv uses BURST_LENGTH=4, so the completion cycle holds
    // burst word 1; Early samples one cycle sooner and lands on word 0.
    input          [1:0] rd_mode,       // 0 = Early, 1 = Normal, 2 = Late

    // ---- ROM download
    input                ioctl_download,
    input          [7:0] ioctl_index,
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    output               ioctl_wait,

    output reg     [7:0] set_id,

    // ---- main CPU ROM (BRAM): 0000-7FFF fixed, 8000-BFFF banked
    input         [15:0] maincpu_addr,
    input          [3:0] maincpu_bank,
    output         [7:0] maincpu_data,

    // ---- sound CPU ROM (BRAM). M1 fetches below 8000 come from the decrypted
    //      opcode half on the sets that ship one (ninjakd2a/ninjakd2b).
    input         [15:0] audiocpu_addr,
    input                audiocpu_m1,
    output         [7:0] audiocpu_data,

    // ---- SDRAM-backed read ports. Hold req until ack; data is valid with ack.
    input         [14:0] char_addr,   input char_req,   output char_ack,   output [7:0] char_data,
    input         [17:0] spr_addr,    input spr_req,    output spr_ack,    output [7:0] spr_data,
    input         [18:0] tile1_addr,  input tile1_req,  output tile1_ack,  output [7:0] tile1_data,
    input         [18:0] tile2_addr,  input tile2_req,  output tile2_ack,  output [7:0] tile2_data,
    input         [18:0] tile3_addr,  input tile3_req,  output tile3_ack,  output [7:0] tile3_data,
    input         [15:0] pcm_addr,    input pcm_req,    output pcm_ack,    output [7:0] pcm_data,

    // ---- SDRAM pins
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

    // MRA index map (must match releases/*.mra)
    //   0 maincpu   1 soundcpu   2 chars   5 set-id
    //   6 sprites   7 tiles1     8 tiles2  9 tiles3   10 pcm   11 proms
    localparam [7:0] IDX_MAIN = 8'd0,  IDX_SND  = 8'd1,  IDX_CHAR = 8'd2,
                     IDX_SET  = 8'd5,  IDX_SPR  = 8'd6,  IDX_TIL1 = 8'd7,
                     IDX_TIL2 = 8'd8,  IDX_TIL3 = 8'd9,  IDX_PCM  = 8'd10,
                     IDX_PROM = 8'd11, IDX_KEY  = 8'd12;

    // SDRAM region bases (byte addresses)
    localparam [23:0] SDR_CHAR = 24'h000000,   // 32K
                      SDR_SPR  = 24'h040000,   // 256K
                      SDR_TIL1 = 24'h080000,   // 512K
                      SDR_TIL2 = 24'h100000,   // 512K
                      SDR_TIL3 = 24'h180000,   // 512K
                      SDR_PCM  = 24'h200000,   // 64K
                      SDR_PROM = 24'h210000;   // 2K

    wire in_sdram = (ioctl_index == IDX_CHAR) || (ioctl_index == IDX_SPR)  ||
                    (ioctl_index == IDX_TIL1) || (ioctl_index == IDX_TIL2) ||
                    (ioctl_index == IDX_TIL3) || (ioctl_index == IDX_PCM)  ||
                    (ioctl_index == IDX_PROM);

    reg [23:0] dl_base;
    always_comb begin
        case (ioctl_index)
            IDX_CHAR: dl_base = SDR_CHAR;
            IDX_SPR : dl_base = SDR_SPR;
            IDX_TIL1: dl_base = SDR_TIL1;
            IDX_TIL2: dl_base = SDR_TIL2;
            IDX_TIL3: dl_base = SDR_TIL3;
            IDX_PCM : dl_base = SDR_PCM;
            IDX_PROM: dl_base = SDR_PROM;
            default : dl_base = 24'd0;
        endcase
    end

    // Game select byte (MRA index 5)
    always_ff @(posedge clk)
        if (ioctl_wr && ioctl_index == IDX_SET) set_id <= ioctl_data;

    // ninjakd2a / ninjakd2b ship a pre-decrypted opcode half; every other set
    // runs opcodes and data from the same image.
    wire use_opcodes = (set_id == 8'h01) || (set_id == 8'h02);

    // MC8123 sets never use the pre-decrypted opcode ROM (01/02 bootlegs only), so
    // rom_snd_opcodes holds the key instead and costs no extra block RAM.
    wire mc8123 = (set_id == 8'h00) || (set_id == 8'h03)
               || (set_id == 8'h04) || (set_id == 8'h05);

    // Main CPU ROM (BRAM). 0x0000-0x7FFF fixed, bank image from download offset 0x8000.
    wire [18:0] mc_off      = ioctl_addr[18:0];
    wire        mc_is_fixed = (mc_off < 19'h08000);
    wire [18:0] mc_bank_off = mc_off - 19'h08000;
    wire        mc_wr       = ioctl_wr && (ioctl_index == IDX_MAIN);

    wire [7:0] mc_fixed_q, mc_bank_q;

    dpram_dc #(.widthad_a(15), .width_a(8)) rom_main_fixed
    (
        .clock_a(clk), .address_a(maincpu_addr[14:0]),
        .data_a(8'd0), .wren_a(1'b0), .q_a(mc_fixed_q),
        .clock_b(clk), .address_b(mc_off[14:0]),
        .data_b(ioctl_data), .wren_b(mc_wr && mc_is_fixed), .q_b()
    );

    dpram_dc #(.widthad_a(18), .width_a(8)) rom_main_bank
    (
        .clock_a(clk), .address_a({maincpu_bank, maincpu_addr[13:0]}),
        .data_a(8'd0), .wren_a(1'b0), .q_a(mc_bank_q),
        .clock_b(clk), .address_b(mc_bank_off[17:0]),
        .data_b(ioctl_data), .wren_b(mc_wr && !mc_is_fixed), .q_b()
    );

    assign maincpu_data = maincpu_addr[15] ? mc_bank_q : mc_fixed_q;

    // Sound CPU ROM (BRAM). 0x00000-0x0FFFF data, 0x10000-0x17FFF opcodes.
    wire [16:0] sc_off   = ioctl_addr[16:0];
    wire        sc_is_op = sc_off[16];
    wire        sc_wr    = ioctl_wr && (ioctl_index == IDX_SND);

    wire [7:0] sc_op_q, sc_lo_q, sc_hi_q;

    // SND decodes cs_rom = (A[15:14] != 2'b11), so only 0000-BFFF is reachable.
    // Split 32K+16K to free 16 M10K blocks; the MRA's C000-FFFF bytes land nowhere.
    dpram_dc #(.widthad_a(15), .width_a(8)) rom_snd_lo          // 0000-7FFF
    (
        .clock_a(clk), .address_a(audiocpu_addr[14:0]),
        .data_a(8'd0), .wren_a(1'b0), .q_a(sc_lo_q),
        .clock_b(clk), .address_b(sc_off[14:0]),
        .data_b(ioctl_data), .wren_b(sc_wr && !sc_is_op && !sc_off[15]), .q_b()
    );

    dpram_dc #(.widthad_a(14), .width_a(8)) rom_snd_hi          // 8000-BFFF
    (
        .clock_a(clk), .address_a(audiocpu_addr[13:0]),
        .data_a(8'd0), .wren_a(1'b0), .q_a(sc_hi_q),
        .clock_b(clk), .address_b(sc_off[13:0]),
        .data_b(ioctl_data), .wren_b(sc_wr && !sc_is_op && (sc_off[15:14] == 2'b10)), .q_b()
    );

    wire [7:0] sc_data_q = audiocpu_addr[15] ? sc_hi_q : sc_lo_q;

    // MC8123 key index: bitswap<12>(addr,15,14,13,12,11,10,8,6,4,2,1,0). Bit 11 is
    // addr[15], always 0 over the encrypted 0000-7FFF, so the MRA packs the two live
    // 2K halves back to back: opcode table then data table, 4K total.
    wire [10:0] tbl_num = {audiocpu_addr[14], audiocpu_addr[13], audiocpu_addr[12],
                           audiocpu_addr[11], audiocpu_addr[10], audiocpu_addr[8],
                           audiocpu_addr[6],  audiocpu_addr[4],  audiocpu_addr[2],
                           audiocpu_addr[1],  audiocpu_addr[0]};

    wire [14:0] sc_op_addr = mc8123 ? {3'd0, ~audiocpu_m1, tbl_num} : audiocpu_addr[14:0];
    wire        key_wr     = ioctl_wr && (ioctl_index == IDX_KEY);

    dpram_dc #(.widthad_a(15), .width_a(8)) rom_snd_opcodes
    (
        .clock_a(clk), .address_a(sc_op_addr),
        .data_a(8'd0), .wren_a(1'b0), .q_a(sc_op_q),
        // Opcodes occupy 0x10000-0x17FFF of a 0x20000 region the MRA fills, so bit 15
        // must gate the write or 0x18000+ aliases onto 0x0000. MC8123 sets: key RAM.
        .clock_b(clk),
        .address_b(key_wr ? {3'd0, ioctl_addr[11:0]} : sc_off[14:0]),
        .data_b(ioctl_data),
        .wren_b(key_wr || (sc_wr && sc_is_op && !sc_off[15])), .q_b()
    );

    // In-flight decrypt. m1 is stable for the whole Z80 cycle, so it both addresses
    // the key and selects the table.
    wire [7:0] sc_dec;

    UPLFramebuffer_MC8123 mc8123_dec
    (
        .val   (sc_data_q),
        .key   (sc_op_q),
        .opcode(audiocpu_m1),
        .dec   (sc_dec)
    );

    // 0x8000-0xBFFF is not encrypted (MAME decodes only the first 0x8000).
    assign audiocpu_data = mc8123 ? (audiocpu_addr[15] ? sc_data_q : sc_dec)
                         : (use_opcodes && audiocpu_m1 && !audiocpu_addr[15])
                           ? sc_op_q : sc_data_q;

    // SDRAM. Read clients round-robin; writes always win so downloads never stall.
    wire [5:0] req = {pcm_req, tile3_req, tile2_req, tile1_req, spr_req, char_req};

    reg  [2:0] rr    = 3'd0;   // rotating priority pointer
    reg  [2:0] cur   = 3'd0;   // client currently being served
    reg  [5:0] ack_r = 6'd0;
    reg  [7:0] rd_q  = 8'd0;

    // A client acked last cycle cannot drop req until the cycle after, so mask it
    // out here rather than burn an arbiter slot the guards below would veto.
    wire [5:0] req_eff = req & ~ack_r;

    // Rotating scan from rr. No modulo: a non-power-of-2 '%' synthesizes a divider.
    reg [2:0] pick;
    reg       pick_v;
    reg [2:0] scan;
    integer   k;
    always_comb begin
        pick   = 3'd0;
        pick_v = 1'b0;
        scan   = rr;
        for (k = 0; k < 6; k = k + 1) begin
            if (!pick_v && req_eff[scan]) begin
                pick   = scan;
                pick_v = 1'b1;
            end
            scan = (scan == 3'd5) ? 3'd0 : (scan + 3'd1);
        end

        // char (client 0) jumps the queue: it is the only client with no lookahead,
        // and its fg FSM hands rowbits to the display whether the fetch completed or
        // not. Demand is bounded at 4 accesses per group, so it cannot starve the rest.
        if (req_eff[3'd0]) begin
            pick   = 3'd0;
            pick_v = 1'b1;
        end
    end

    // gfx_unscramble, in flight (ninjakd2.cpp:2249 lineswap_gfx_roms). MAME rotates
    // the low (bit+1) address bits left at load:
    //   da[bit:1] = sa[bit-1:0], da[0] = sa[bit]; bits above `bit` unchanged.
    // SDRAM holds the raw ROM and the inverse rotate is applied here. chars rotate
    // about bit 13, sprites and tiles1 about bit 14. set_id 00-08 only; robokid and
    // omegaf use empty_init and are not scrambled.
    wire gfx_scr = (set_id <= 8'h08);

    wire [14:0] char_sa  = gfx_scr ? {char_addr[14],     char_addr[0],  char_addr[13:1]}   : char_addr;
    wire [17:0] spr_sa   = gfx_scr ? {spr_addr[17:15],   spr_addr[0],   spr_addr[14:1]}    : spr_addr;
    wire [18:0] tile1_sa = gfx_scr ? {tile1_addr[18:15], tile1_addr[0], tile1_addr[14:1]}  : tile1_addr;

    reg [23:0] cli_byte;
    always_comb begin
        case (pick)
            3'd0: cli_byte = SDR_CHAR + {9'd0,  char_sa};
            3'd1: cli_byte = SDR_SPR  + {6'd0,  spr_sa};
            3'd2: cli_byte = SDR_TIL1 + {5'd0,  tile1_sa};
            3'd3: cli_byte = SDR_TIL2 + {5'd0,  tile2_addr};
            3'd4: cli_byte = SDR_TIL3 + {5'd0,  tile3_addr};
            default: cli_byte = SDR_PCM + {8'd0, pcm_addr};
        endcase
    end

    // 16-bit read cache: every SDRAM word holds two bytes this hardware will ask
    // for, so every second byte fetch becomes a free hit. Pairing differs by set —
    // unscrambled clients pair (da, da+1), scrambled ones (da, da+2) since
    // sa[0] = da[1] — so TWO slots per client are needed to cover the 4-byte row
    // fetches without thrashing. Contents are ROM; only a download invalidates.
    // CACHE_EN = 0 falls back to one SDRAM read per byte.
    localparam CACHE_EN = 1'b1;

    reg [22:0] c_tag [0:5][0:1];
    reg [15:0] c_dat [0:5][0:1];
    reg  [1:0] c_vld [0:5];
    reg        c_lru [0:5];
    integer    ci;

    wire [22:0] pick_wa = cli_byte[23:1];
    wire c_h0  = CACHE_EN && c_vld[pick][0] && (c_tag[pick][0] == pick_wa);
    wire c_h1  = CACHE_EN && c_vld[pick][1] && (c_tag[pick][1] == pick_wa);
    wire c_hit = pick_v && (c_h0 || c_h1);
    wire [15:0] c_word = c_h0 ? c_dat[pick][0] : c_dat[pick][1];

    reg  [26:1] sd_addr;
    reg  [15:0] sd_din;
    reg   [1:0] sd_bs;
    reg         sd_rd, sd_wr, sd_refresh, sd_busy, sd_was_rd, sd_lsb;
    reg         sd_old_ready;
    reg   [8:0] sd_refresh_cnt;

    // Latch every download byte on arrival whatever sd_busy is doing; a strobe
    // landing on a busy cycle is otherwise lost.
    reg         wr_pend;
    reg  [23:0] wr_addr;
    reg   [7:0] wr_data;

    // Deferred read capture for RD_LATE; cur/sd_lsb are snapshotted because the
    // arbiter may start another read next cycle.
    reg         rd_pend = 1'b0;
    reg   [2:0] rd_cur  = 3'd0;
    reg         rd_lsbp = 1'b0;

    wire        sd_ready;
    wire [15:0] sd_dout;

    localparam [1:0] RD_EARLY = 2'd0, RD_NORMAL = 2'd1, RD_LATE = 2'd2;

    // sd_dout is a register of SDRAM_DQ, so a one-deep delay gives burst word 0.
    reg [15:0] sd_dout_d1;
    always_ff @(posedge clk) sd_dout_d1 <= sd_dout;

    wire [15:0] sd_dout_sel = (rd_mode == RD_EARLY) ? sd_dout_d1 : sd_dout;

    assign ioctl_wait = sd_busy || (ioctl_wr && in_sdram);

    // A hit needs no SDRAM cycle, so it can be served while another client's read is
    // in flight. rd_q/ack_r are shared: one ack per cycle, and a completion wins.
    wire sd_complete = sd_busy && sd_ready && !sd_rd && !sd_wr;
    wire comp_ack    = (sd_complete && sd_was_rd && (rd_mode != RD_LATE)) || rd_pend;
    wire serve_hit   = c_hit && !comp_ack && !ack_r[pick] && !ioctl_download;

    always_ff @(posedge clk) begin
        // por_reset ONLY: a reset including ioctl_download would idle this FSM for
        // the whole transfer and no byte would land.
        if (por_reset) begin
            sd_rd <= 0; sd_wr <= 0; sd_refresh <= 0; sd_busy <= 0; sd_was_rd <= 0;
            sd_refresh_cnt <= 9'd0; sd_old_ready <= 1'b1; wr_pend <= 1'b0; ack_r <= 6'd0;
            rd_pend <= 1'b0;
            rr <= 3'd0;
            for (ci = 0; ci < 6; ci = ci + 1) begin
                c_vld[ci] <= 2'd0;
                c_lru[ci] <= 1'b0;
            end
        end else begin
            // AUTO_REFRESH: 8192 rows / 64 ms = 7.8125 us = 468 cycles at 60 MHz.
            // Toggled unconditionally and OUTSIDE the arbiter so a busy client cannot
            // starve it; the controller edge-detects it and services it from IDLE.
            // This toggle is the only refresh source — sdram.sv's cycles_per_refresh
            // is declared but never referenced.
            if (sd_refresh_cnt == 9'd467) begin
                sd_refresh_cnt <= 9'd0;
                sd_refresh     <= ~sd_refresh;
            end else begin
                sd_refresh_cnt <= sd_refresh_cnt + 1'b1;
            end
            sd_old_ready   <= sd_ready;
            ack_r          <= 6'd0;

            if (ioctl_wr && in_sdram) begin
                wr_pend <= 1'b1;
                wr_addr <= dl_base + ioctl_addr[23:0];
                wr_data <= ioctl_data;
            end

            // accepted: ready fell 1->0, drop the strobe so the op runs once
            if (sd_old_ready && !sd_ready) begin
                sd_rd <= 0;
                sd_wr <= 0;
            end

            if (sd_busy) begin
                // complete: ready back high with the strobe already cleared
                if (sd_ready && !sd_rd && !sd_wr) begin
                    if (sd_was_rd) begin
                        if (rd_mode == RD_LATE) begin
                            rd_pend <= 1'b1; rd_cur <= cur; rd_lsbp <= sd_lsb;
                        end else begin
                            rd_q       <= sd_lsb ? sd_dout_sel[15:8] : sd_dout_sel[7:0];
                            ack_r[cur] <= 1'b1;
                            c_tag[cur][c_lru[cur]] <= sd_addr[23:1];
                            c_dat[cur][c_lru[cur]] <= sd_dout_sel;
                            c_vld[cur][c_lru[cur]] <= 1'b1;
                            c_lru[cur]             <= ~c_lru[cur];
                        end
                    end
                    sd_busy <= 0;
                end
            end else begin
                if (wr_pend) begin
                    sd_addr  <= {3'd0, wr_addr[23:1]};
                    sd_din   <= {wr_data, wr_data};
                    sd_bs    <= wr_addr[0] ? 2'b10 : 2'b01;
                    sd_wr    <= 1; sd_busy <= 1; sd_was_rd <= 0;
                    // Keep a request arriving this cycle: a bare `wr_pend <= 0` here
                    // would win as the last assignment and drop that byte.
                    wr_pend  <= (ioctl_wr && in_sdram);
                // !ack_r[pick] && !c_hit: never fetch for a client whose ack is already
                // up or is being served from cache, or its next read is one fetch stale.
                end else if (pick_v && !ioctl_download && !rd_pend && !ack_r[pick] && !c_hit) begin
                    sd_addr   <= {3'd0, cli_byte[23:1]};
                    sd_lsb    <= cli_byte[0];
                    cur       <= pick;
                    rr        <= (pick == 3'd5) ? 3'd0 : (pick + 3'd1);
                    sd_rd     <= 1; sd_busy <= 1; sd_was_rd <= 1;
                end
            end

            // RD_LATE capture, one cycle after completion
            if (rd_pend) begin
                rd_q          <= rd_lsbp ? sd_dout[15:8] : sd_dout[7:0];
                ack_r[rd_cur] <= 1'b1;
                rd_pend       <= 1'b0;
                c_tag[rd_cur][c_lru[rd_cur]] <= sd_addr[23:1];
                c_dat[rd_cur][c_lru[rd_cur]] <= sd_dout;
                c_vld[rd_cur][c_lru[rd_cur]] <= 1'b1;
                c_lru[rd_cur]                <= ~c_lru[rd_cur];
            end

            // Cache hit: ack immediately and rotate the pointer as a real service
            // would, so one client cannot monopolise the port.
            if (serve_hit) begin
                rd_q        <= cli_byte[0] ? c_word[15:8] : c_word[7:0];
                ack_r[pick] <= 1'b1;
                rr          <= (pick == 3'd5) ? 3'd0 : (pick + 3'd1);
            end

            // ROM never changes underneath us, so a download is the only invalidation.
            if (ioctl_download)
                for (ci = 0; ci < 6; ci = ci + 1) c_vld[ci] <= 2'd0;
        end
    end

    assign {pcm_ack, tile3_ack, tile2_ack, tile1_ack, spr_ack, char_ack} = ack_r;
    assign char_data  = rd_q;
    assign spr_data   = rd_q;
    assign tile1_data = rd_q;
    assign tile2_data = rd_q;
    assign tile3_data = rd_q;
    assign pcm_data   = rd_q;

    // Clock-rate dependent: 468 cycles = 7.8125 us at 60 MHz (stock 780 would be
    // 13 us and lose data). Startup 100 us = 6060 cycles.
    sdram #(.sdram_startup_cycles(14'd6060), .cycles_per_refresh(14'd468)) sdram_i
    (
        .init       (por_reset),
        .clk        (clk),
        .SDRAM_DQ   (SDRAM_DQ),   .SDRAM_A   (SDRAM_A),   .SDRAM_DQML(SDRAM_DQML),
        .SDRAM_DQMH (SDRAM_DQMH), .SDRAM_BA  (SDRAM_BA),  .SDRAM_nCS (SDRAM_nCS),
        .SDRAM_nWE  (SDRAM_nWE),  .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE  (SDRAM_CKE),  .SDRAM_CLK (SDRAM_CLK), .SDRAM_EN  (1'b1),
        .sel        (1'b1),
        .addr       (sd_addr),    .dout      (sd_dout),   .din       (sd_din),
        .wr         (sd_wr),      .bs        (sd_bs),     .rd        (sd_rd),
        .ready      (sd_ready),   .refresh   (sd_refresh),
        .cpsel(1'b0), .cpaddr(26'd0), .cpdin(16'd0), .cprd(), .cpreq(1'b0), .cpbusy()
    );

endmodule
