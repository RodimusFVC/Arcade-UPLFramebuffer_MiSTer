//============================================================================
//
//  ChampionBaseball_SND.sv — champbas sound board: Z80 driving a DAC only.
//  The AY is on the MAIN board (champbas.cpp:579); this CPU never sees it.
//
//============================================================================

module ChampionBaseball_SND
(
    input                clk,
    input                cen_cpu,        // 3.072 MHz
    input                cen_ay,         // 1.536 MHz
    input                reset,
    input                pause,

    // ---- from the main board
    input         [7:0]  sound_latch,
    input                sound_latch_wr,
    input         [7:0]  ay_din,
    input                ay_addr_wr,
    input                ay_data_wr,

    // ---- audio CPU ROM (champbas_rom index 1)
    output       [15:0]  rom_addr,
    input         [7:0]  rom_data,

    output signed [15:0] sound_out
);

    ////////////////////////////////////////////////////////////////////////
    // Address decode — champbas_sound_map (champbas.cpp:659)
    // decodes it. Corroborated by the dasm: `ld sp,$E3FF` at $0001 puts the
    // stack at the top of RAM, and $0005/$0008/$0011 hit A000/8000/C000.
    ////////////////////////////////////////////////////////////////////////

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n;

    wire mem_wr = ~mreq_n & ~wr_n;

    wire cs_rom   = (A[15:13] <  3'b011);   // 0000-5FFF
    wire cs_latch = (A[15:13] == 3'b011);   // 6000-7FFF
    wire cs_ret   = (A[15:13] == 3'b100);   // 8000-9FFF (write-only, ignored)
    wire cs_clr   = (A[15:13] == 3'b101);   // A000-BFFF
    wire cs_dac   = (A[15:13] == 3'b110);   // C000-DFFF
    wire cs_ram   = (A[15:13] == 3'b111);   // E000-FFFF

    assign rom_addr = A;

    ////////////////////////////////////////////////////////////////////////
    // Sound latch (MAME GENERIC_LATCH_8).
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] latch_reg = 8'd0;

    always_ff @(posedge clk) begin
        if (reset)                          latch_reg <= 8'd0;
        else if (sound_latch_wr)            latch_reg <= sound_latch;
        else if (cen_cpu & mem_wr & cs_clr) latch_reg <= 8'd0;
    end

    ////////////////////////////////////////////////////////////////////////
    // 6-bit R2R DAC at $C000. The dasm initialises it to $20 at $000F-$0011,
    ////////////////////////////////////////////////////////////////////////

    reg [5:0] dac_reg = 6'd32;

    always_ff @(posedge clk) begin
        if (reset)                          dac_reg <= 6'd32;
        else if (cen_cpu & mem_wr & cs_dac) dac_reg <= cpu_dout[5:0];
    end

    // Centre on mid-scale, then scale to FULL 16-bit range: (-32..+31) << 10
    wire signed [16:0] dac_signed = ($signed({10'd0, dac_reg}) - 17'sd32) <<< 10;

    ////////////////////////////////////////////////////////////////////////
    // Work RAM — E000-E3FF (1KB)
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram_dout;

    dpram_dc #(.widthad_a(10), .width_a(8)) sound_ram
    (
        .clock_a(clk),
        .address_a(A[9:0]),
        .data_a(cpu_dout),
        .wren_a(cen_cpu & mem_wr & cs_ram),
        .q_a(ram_dout),

        .clock_b(clk),
        .address_b(10'd0),
        .data_b(8'd0),
        .wren_b(1'b0),
        .q_b()
    );

    ////////////////////////////////////////////////////////////////////////
    // AY-3-8910 (jt49 by Jotego). Pattern taken from the hardware-verified
    // champbas uses ay8910_device::data_address_w, so $7000 = DATA and
    // $7001 = ADDRESS. In AY bus terms: address latch = {bdir,bc1} = 11,
    // The strobes MUST be stretched: the Z80 write pulse is ~24 clk wide while
    ////////////////////////////////////////////////////////////////////////

    reg        ay_pending = 1'b0;
    reg        ay_bc1_lat = 1'b0;
    reg  [7:0] ay_din_lat = 8'd0;

    always_ff @(posedge clk) begin
        if (reset) ay_pending <= 1'b0;
        else if (ay_addr_wr | ay_data_wr) begin
            ay_pending <= 1'b1;
            ay_bc1_lat <= ay_addr_wr;      // address latch = bc1 high
            ay_din_lat <= ay_din;
        end else if (cen_ay) ay_pending <= 1'b0;
    end

    wire [7:0] ayA_raw, ayB_raw, ayC_raw;

    jt49_bus #(.COMP(3'b100)) ay
    (
        .rst_n  (~reset),
        .clk    (clk),
        .clk_en (cen_ay),
        .bdir   (ay_pending),
        .bc1    (ay_bc1_lat),
        .din    (ay_din_lat),
        .sel    (1'b1),
        .dout   (),
        .A      (ayA_raw),
        .B      (ayB_raw),
        .C      (ayC_raw),
        .IOA_in (8'hFF),
        .IOB_in (8'hFF)
    );

    // DC removal, same shaping as TimePilot: raw byte shifted up into 16 bits
    reg div = 1'b0;
    always_ff @(posedge clk) div <= ~div;
    wire cen_dcrm = ~div;

    wire signed [15:0] ayA_dc, ayB_dc, ayC_dc;

    jt49_dcrm2 #(16) dcrm_A
    ( .clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ayA_raw, 5'd0}), .dout(ayA_dc) );
    jt49_dcrm2 #(16) dcrm_B
    ( .clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ayB_raw, 5'd0}), .dout(ayB_dc) );
    jt49_dcrm2 #(16) dcrm_C
    ( .clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ayC_raw, 5'd0}), .dout(ayC_dc) );

    ////////////////////////////////////////////////////////////////////////
    // Mix. MAME routes the AY at 0.3 and the DAC at 0.7 (:1002, :1004), so the
    ////////////////////////////////////////////////////////////////////////

    wire signed [17:0] ay_sum = {{2{ayA_dc[15]}}, ayA_dc}
                              + {{2{ayB_dc[15]}}, ayB_dc}
                              + {{2{ayC_dc[15]}}, ayC_dc};

    wire signed [17:0] dac_x  = {dac_signed[16], dac_signed};

    wire signed [17:0] mix = (dac_x  >>> 1) + (dac_x  >>> 2)     // DAC x 0.75
                           + (ay_sum >>> 1) + (ay_sum >>> 3);    // AY  x 0.625

    assign sound_out = pause ? 16'sd0 : mix[15:0];

    ////////////////////////////////////////////////////////////////////////
    // CPU read mux + Z80
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] cpu_din;

    always_comb begin
        if      (cs_rom)   cpu_din = rom_data;
        else if (cs_latch) cpu_din = latch_reg;
        else if (cs_ram)   cpu_din = ram_dout;
        else               cpu_din = 8'hFF;
    end

    T80s cpu
    (
        .RESET_n(~reset),
        .CLK(clk),
        .CEN(cen_cpu & ~pause),
        .WAIT_n(1'b1),
        .INT_n(1'b1),          // champbas has no sound IRQ — the CPU polls
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
