//============================================================================
//
//  UPLFramebuffer_SND.sv — UPL sound board: Z80 @ 5 MHz + 2x YM2203 @ 1.5 MHz.
//  Maps from ninjakd2.cpp:1121 (memory) and :1141 (I/O).
//
//============================================================================

module UPLFramebuffer_SND
(
    input                clk,            // 60 MHz fabric
    input                cen_cpu,        // 5.0 MHz  (sound Z80)
    input                cen_ym,         // 1.5 MHz  (both YM2203)
    input                reset,
    input                pause,

    // ---- from the main board
    input         [7:0]  sound_latch,
    input                sound_latch_wr,

    // ---- sound CPU ROM, 0000-BFFF
    output       [15:0]  rom_addr,
    input         [7:0]  rom_data,
    output               rom_m1,         // opcode fetch; MC8123 decrypted-opcode select

    // ---- PCM sample trigger, ninjakd2 only (ninjakd2_pcm_play_w)
    output        [7:0]  pcm_cmd,
    output               pcm_cmd_wr,

    // DIAG-REVERT-2026-08-31: sound bring-up probes, both default OFF
    input                diag_tone,      // square wave straight into the mixer output
    input                diag_ym,        // SSG tone written directly into YM2203 #1

    output signed [15:0] sound_out
);

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n;

    wire mem_wr = ~mreq_n & ~wr_n;
    wire io_wr  = ~iorq_n & ~wr_n & m1_n;   // m1_n excludes the interrupt-ack cycle
    wire io_rd  = ~iorq_n & ~rd_n & m1_n;

    ////////////////////////////////////////////////////////////////////////
    // Memory decode. 0000-BFFF ROM, C000-C7FF RAM, E000 latch, F000 PCM.
    // E000/F000 are decoded exactly as MAME maps them; the sound program uses
    // only those addresses (mnight_soundcpu.dasm $00E5: ld a,($E000)).
    ////////////////////////////////////////////////////////////////////////

    wire cs_rom   = (A[15:14] != 2'b11);        // 0000-BFFF
    wire cs_ram   = (A[15:11] == 5'b11000);     // C000-C7FF
    wire cs_latch = (A == 16'hE000);
    wire cs_pcm   = (A == 16'hF000);

    assign rom_addr = A;
    assign rom_m1   = ~m1_n;

    ////////////////////////////////////////////////////////////////////////
    // Sound latch (MAME GENERIC_LATCH_8) — written by the main CPU, read here.
    ////////////////////////////////////////////////////////////////////////

    // MAME's generic_latch_8 is not cleared by the sound CPU's reset line, so a
    // command written while the CPU is held must survive until it is released.
    reg [7:0] latch_reg = 8'd0;

    always_ff @(posedge clk) begin
        if (sound_latch_wr) latch_reg <= sound_latch;
    end

    ////////////////////////////////////////////////////////////////////////
    // PCM sample command latch. Consumed by the sample player once the PCM
    // ROM region exists; every game writes 0xF0 (silence) here.
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] pcm_reg = 8'd0;
    reg       pcm_wr  = 1'b0;

    always_ff @(posedge clk) begin
        pcm_wr <= 1'b0;
        if (cen_cpu & mem_wr & cs_pcm) begin
            pcm_reg <= cpu_dout;
            pcm_wr  <= 1'b1;
        end
    end

    assign pcm_cmd    = pcm_reg;
    assign pcm_cmd_wr = pcm_wr;

    ////////////////////////////////////////////////////////////////////////
    // Work RAM — C000-C7FF (2KB)
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram_dout;

    dpram_dc #(.widthad_a(11), .width_a(8)) sound_ram
    (
        .clock_a(clk),
        .address_a(A[10:0]),
        .data_a(cpu_dout),
        .wren_a(cen_cpu & mem_wr & cs_ram),
        .q_a(ram_dout),

        .clock_b(clk),
        .address_b(11'd0),
        .data_b(8'd0),
        .wren_b(1'b0),
        .q_b()
    );

    ////////////////////////////////////////////////////////////////////////
    // 2x YM2203. I/O $00-$01 = chip 1, $80-$81 = chip 2, A0 selects
    // address/data. Only chip 1 drives the Z80 IRQ (ninjakd2.cpp:1581).
    //
    // jt12_mmr's register block is always @(posedge clk) and is NOT cen-gated,
    // so a held write re-executes every clock and re-triggers once-only bits
    // such as key-on. The strobe must therefore be exactly one clk wide — the
    // opposite of the stretched strobe a cen-gated jt49 needs.
    ////////////////////////////////////////////////////////////////////////

    wire ym1_sel = io_wr & (A[7:1] == 7'b0000000);   // $00-$01
    wire ym2_sel = io_wr & (A[7:1] == 7'b1000000);   // $80-$81

    reg ym1_sel_d = 1'b0, ym2_sel_d = 1'b0;
    always_ff @(posedge clk) begin
        ym1_sel_d <= ym1_sel;
        ym2_sel_d <= ym2_sel;
    end

    // Gated on ~reset: jt12_mmr flags a write during reset as a glue-logic error.
    wire ym1_wr = ym1_sel & ~ym1_sel_d & ~reset;
    wire ym2_wr = ym2_sel & ~ym2_sel_d & ~reset;

    // DIAG-REVERT-2026-08-31: SSG tone generator. Writes R7 mixer, R0/R1 tone
    // period and R8 volume into chip 1, one register per ~17us, then stops.
    reg [3:0] dstep = 4'd0;
    reg [9:0] dwait = 10'd0;
    reg       dstrobe = 1'b0;
    reg       daddr = 1'b0;
    reg [7:0] ddin  = 8'd0;
    reg       ddone = 1'b0;

    always_ff @(posedge clk) begin
        dstrobe <= 1'b0;
        if (!diag_ym) begin
            dstep <= 4'd0; dwait <= 10'd0; ddone <= 1'b0;
        end else if (!ddone) begin
            if (dwait != 10'd1023) dwait <= dwait + 10'd1;
            else begin
                dwait <= 10'd0;
                case (dstep)
                    4'd0: begin daddr <= 1'b0; ddin <= 8'h07; end
                    4'd1: begin daddr <= 1'b1; ddin <= 8'h38; end
                    4'd2: begin daddr <= 1'b0; ddin <= 8'h00; end
                    4'd3: begin daddr <= 1'b1; ddin <= 8'h40; end
                    4'd4: begin daddr <= 1'b0; ddin <= 8'h01; end
                    4'd5: begin daddr <= 1'b1; ddin <= 8'h00; end
                    4'd6: begin daddr <= 1'b0; ddin <= 8'h08; end
                    default: begin daddr <= 1'b1; ddin <= 8'h0F; end
                endcase
                dstrobe <= 1'b1;
                if (dstep == 4'd7) ddone <= 1'b1;
                else dstep <= dstep + 4'd1;
            end
        end
    end

    wire       ym1_wr_eff = diag_ym ? dstrobe : ym1_wr;
    wire       ym1_addr   = diag_ym ? daddr   : A[0];
    wire [7:0] ym1_din    = diag_ym ? ddin    : cpu_dout;

    // DIAG-REVERT-2026-08-31: ~440 Hz square, bypasses jt03 entirely.
    reg [16:0] tone_div = 17'd0;
    reg        tone_ph  = 1'b0;
    always_ff @(posedge clk) begin
        if (tone_div == 17'd68181) begin tone_div <= 17'd0; tone_ph <= ~tone_ph; end
        else tone_div <= tone_div + 17'd1;
    end
    wire signed [15:0] diag_wave = tone_ph ? 16'sd8000 : -16'sd8000;

    wire [7:0] ym1_dout, ym2_dout;
    wire       ym1_irq_n;
    wire signed [15:0] ym1_snd, ym2_snd;

    jt03 ym2203_1
    (
        .rst    (reset),
        .clk    (clk),
        .cen    (cen_ym),
        // DIAG-REVERT-2026-08-31: originals were cpu_dout / A[0] / ~ym1_wr / ~ym1_wr
        .din    (ym1_din),
        .addr   (ym1_addr),
        .cs_n   (~ym1_wr_eff),
        .wr_n   (~ym1_wr_eff),
        .dout   (ym1_dout),
        .irq_n  (ym1_irq_n),
        .IOA_in (8'hFF),
        .IOB_in (8'hFF),
        .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
        .psg_A  (), .psg_B  (), .psg_C  (),
        .fm_snd (), .psg_snd(),
        .snd    (ym1_snd),
        .snd_sample(),
        .debug_view()
    );

    jt03 ym2203_2
    (
        .rst    (reset),
        .clk    (clk),
        .cen    (cen_ym),
        .din    (cpu_dout),
        .addr   (A[0]),
        .cs_n   (~ym2_wr),
        .wr_n   (~ym2_wr),
        .dout   (ym2_dout),
        .irq_n  (),                      // chip 2 does not drive the IRQ line
        .IOA_in (8'hFF),
        .IOB_in (8'hFF),
        .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
        .psg_A  (), .psg_B  (), .psg_C  (),
        .fm_snd (), .psg_snd(),
        .snd    (ym2_snd),
        .snd_sample(),
        .debug_view()
    );

    ////////////////////////////////////////////////////////////////////////
    // Mix. jt03's combined snd already carries jotego's FM/SSG balance, so the
    // two chips just sum and halve.
    ////////////////////////////////////////////////////////////////////////

    wire signed [16:0] snd_sum = {ym1_snd[15], ym1_snd} + {ym2_snd[15], ym2_snd};

    // DIAG-REVERT-2026-08-31: original below, uncomment to restore
    // assign sound_out = pause ? 16'sd0 : snd_sum[16:1];
    assign sound_out = pause ? 16'sd0 : (diag_tone ? diag_wave : snd_sum[16:1]);

    ////////////////////////////////////////////////////////////////////////
    // CPU read mux + Z80. MAME maps the YM ports write-only, but the sound
    // program does read them (mnight_soundcpu.dasm: in a,($01) / in a,($81)),
    // so the status/SSG read path is wired. Forcing io_rd to 8'hFF restores
    // MAME's behaviour if that ever proves to matter.
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] cpu_din;

    always_comb begin
        if      (io_rd & (A[7:1] == 7'b0000000)) cpu_din = ym1_dout;
        else if (io_rd & (A[7:1] == 7'b1000000)) cpu_din = ym2_dout;
        else if (io_rd)                          cpu_din = 8'hFF;
        else if (cs_rom)                         cpu_din = rom_data;
        else if (cs_ram)                         cpu_din = ram_dout;
        else if (cs_latch)                       cpu_din = latch_reg;
        else                                     cpu_din = 8'hFF;
    end

    T80s cpu
    (
        .RESET_n(~reset),
        .CLK(clk),
        .CEN(cen_cpu & ~pause),
        .WAIT_n(1'b1),
        .INT_n(ym1_irq_n),
        .NMI_n(1'b1),
        .BUSRQ_n(1'b1),
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
