//============================================================================
//
//  alpha8201 — ALPHA-8201 protection MCU wrapper: an hmcs40 core plus the
//  shared-RAM glue the champbas family drives it through.
//
//  Ported from MAME's alpha8201.cpp (license BSD-3-Clause, copyright hap).
//
//  mcu_start / bus_dir  <- LS259 mainlatch Q6/Q7 (champbas.cpp:935-936)
//  ext_*                <- champbas_map 0x6000-0x63FF shared RAM
//  mcu_addr / mcu_data  -> champbas_rom's 13-bit MCU ROM port
//  CEN_DIV generates the machine-cycle enable; pause freezes it in phase.
//
//============================================================================

module alpha8201 #(
    parameter [15:0] CEN_DIV = 16'd511   // clk cycles per machine-cycle tick, minus 1
) (
    input  wire        clk,
    input  wire        reset,

    // Z80-side control (LS259 mainlatch, champbas.cpp:935-936)
    input  wire        pause,         // 1 = freeze machine cycles (MiSTer pause; tie 0 in TBs)
    input  wire        mcu_start,     // Q6 -> alpha_8201_device::mcu_start_w (INT0 pin)
    input  wire        bus_dir,       // Q7 -> alpha_8201_device::bus_dir_w (1=MCU owns shared RAM)

    // Z80-side shared RAM window (champbas_map 0x6000-0x63FF, 1KB,
    input  wire [9:0]  ext_addr,
    input  wire [7:0]  ext_din,
    output wire [7:0]  ext_dout,
    input  wire        ext_we,

    // MCU program ROM — byte-addressed, 1-cycle registered read latency,
    output wire [12:0] mcu_addr,
    input  wire [7:0]  mcu_data,

    // debug/observability
    output wire [10:0] dbg_pc,
    output wire [9:0]  dbg_op,
    output wire        dbg_illegal,
    output wire [9:0]  dbg_mcu_ram_addr,
    output wire        dbg_mcu_rd_en,
    output wire        dbg_mcu_wr_en
);

    // ------------------------------------------------------------------
    reg [15:0] cen_cnt;
    reg        cen;
    always @(posedge clk) begin
        if (reset) begin
            cen_cnt <= 16'd0;
            cen <= 1'b0;
        end else if (pause) begin
            // Hold BOTH cen and the divider: the MCU is an interpreter over
            cen <= 1'b0;
        end else begin
            cen <= 1'b0;
            if (cen_cnt == CEN_DIV) begin
                cen_cnt <= 16'd0;
                cen <= 1'b1;
            end else begin
                cen_cnt <= cen_cnt + 16'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    wire         core_rom_req;
    wire [11:0]  core_rom_addr;
    reg  [15:0]  core_rom_data;
    reg          core_rom_ack;

    localparam [1:0] RB_IDLE = 2'd0, RB_LO = 2'd1, RB_HI = 2'd2, RB_ACK = 2'd3;
    reg [1:0]  rb_state;
    reg [11:0] rb_word_addr;
    reg [7:0]  rb_lo;

    // NOTE: in RB_IDLE this must combinationally track core_rom_addr (not
    assign mcu_addr = (rb_state == RB_IDLE) ? {core_rom_addr, 1'b0} :
                                               {rb_word_addr, 1'b1};

    always @(posedge clk) begin
        if (reset) begin
            rb_state <= RB_IDLE;
            core_rom_ack <= 1'b0;
            rb_word_addr <= 12'h0;
        end else begin
            core_rom_ack <= 1'b0;
            case (rb_state)
                RB_IDLE: if (core_rom_req) begin
                    rb_word_addr <= core_rom_addr; // mcu_addr already reflects {addr,0} combinationally above
                    rb_state <= RB_LO;
                end
                RB_LO: begin
                    // mcu_data now valid for the LOW byte (address was
                    rb_lo <= mcu_data;
                    rb_state <= RB_HI;
                end
                RB_HI: begin
                    // mcu_data now valid for the HIGH byte.
                    core_rom_data <= {mcu_data, rb_lo};
                    core_rom_ack  <= 1'b1;
                    rb_state <= RB_ACK;
                end
                RB_ACK: begin
                    rb_state <= RB_IDLE; // one idle cycle so a re-request sees a fresh IDLE sample
                end
                default: rb_state <= RB_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    wire [3:0] r0_out, r1_out, r2_out, r3_out;
    wire [15:0] d_out;
    wire        mcu_d_we;   // WR-EVENT-FIX-2026-08-01: true D-write strobe
    wire        mcu_r_we;   // WR-EVENT-FIX rev2: true R-write strobe
    wire [2:0]  mcu_r_we_idx;

    // mcu_update_address() (alpha8201.cpp:357-361):
    //   m_mcu_address = (m_mcu_d<<8 & 0x300) | m_mcu_r[2]<<4 | m_mcu_r[3];
    wire [9:0] mcu_ram_addr = {d_out[1:0], r2_out, r3_out};

    // D2 = /RD (active low), D3 = WR (active high) — pinout table,
    wire mcu_rd_en = bus_dir && ~d_out[2];                  // mcu_data_r gate, alpha8201.cpp:368
    wire mcu_wr_en = bus_dir && (d_out[3:2] == 2'b11);      // mcu_writeram gate, alpha8201.cpp:353

    assign dbg_mcu_ram_addr = mcu_ram_addr;
    assign dbg_mcu_rd_en    = mcu_rd_en;
    assign dbg_mcu_wr_en    = mcu_wr_en;

    reg [7:0] shared_ram [0:1023];

    // Z80 side — unconditional (alpha8201.cpp:418-428 comment: "going by
    assign ext_dout = shared_ram[ext_addr];

    // MCU side — read (mcu_data_r, alpha8201.cpp:364-376): R0 gets the
    wire [7:0] mcu_ram_rd = shared_ram[mcu_ram_addr];
    // R-PORT-READBACK-FIX-2026-08-07 (part 2): MAME read_r() (hmcs40.cpp:387-396)
    // IS_CMOS (hmcs40.cpp:123), so m_polarity is truthy -> the AND branch.
    // bus_dir=1 at $01B7 and leaves it, so the gate is open for the whole run.
    wire [3:0] r0_in = (mcu_rd_en ? mcu_ram_rd[7:4] : 4'h0) & r0_out;
    wire [3:0] r1_in = (mcu_rd_en ? mcu_ram_rd[3:0] : 4'h0) & r1_out;

    // MCU side — write (mcu_writeram, alpha8201.cpp:350-355).
    wire       bus_dir_edge = bus_dir & ~bus_dir_q;
    reg        bus_dir_q;
    always @(posedge clk) bus_dir_q <= bus_dir;

    // MAME, not two. Both port writers funnel through mcu_update_address():
    //     mcu_data_w()  (write_r<0..3>, alpha8201.cpp:378-384) -> update_address -> writeram
    //     mcu_d_w()     (write_d,       :386-393)              -> update_address -> writeram
    //     bus_dir_w()   (:403-409)                             -> writeram directly
    // The MCU's natural sequence is R2/R3 (address) -> D (WR) -> R0/R1 (data),
    // this fix triggered on d_we|bus_dir only, dropped that trigger, and changed
    wire mcu_r03_we    = mcu_r_we & (mcu_r_we_idx <= 3'd3);
    wire mcu_wr_commit = mcu_wr_en & (mcu_d_we | mcu_r03_we | bus_dir_edge);

    // ------------------------------------------------------------------
    // which is why three successive write-trigger fixes (level -> d_we/bus_dir
    // -> +r_we) produced ZERO behavioural change on both talbot and exctsccr.
    always @(posedge clk) begin
        if (ext_we)
            shared_ram[ext_addr]     <= ext_din;
        else if (mcu_wr_commit)
            shared_ram[mcu_ram_addr] <= {r0_out, r1_out};
    end

    // R2/R3 reads and R4-R7/D reads are all unbound in
    // read_r<1>, write_r<0..3>, write_d) -> external input side reads as
    hmcs40 u_mcu (
        .clk        (clk),
        .reset      (reset),
        .cen        (cen),
        .hlt_in     (1'b0),           // pin 19 !HLT tied to Vcc — never halted (alpha8201.cpp:52)

        .rom_req    (core_rom_req),
        .rom_addr   (core_rom_addr),
        .rom_data   (core_rom_data),
        .rom_ack    (core_rom_ack),

        // R2-R7 have NO read_r<> bind in device_add_mconfig, so they take MAME's
        // on at $0ECF -> "TESTING 6" hangs forever.
        // DO NOT retry this. Back to the correct 4'h0.
        .r0_in(r0_in), .r1_in(r1_in), .r2_in(r2_out), .r3_in(r3_out),
        .r4_in(4'h0),  .r5_in(4'h0),  .r6_in(4'h0),  .r7_in(4'h0),
        .r0_out(r0_out), .r1_out(r1_out), .r2_out(r2_out), .r3_out(r3_out),
        .r4_out(), .r5_out(), .r6_out(), .r7_out(),

        // (alpha8201.cpp:329 binds write_d only), and the core already applies
        .d_in       (16'hFFFF),
        .d_out      (d_out),
        .d_we       (mcu_d_we),       // WR-EVENT-FIX-2026-08-01
        .r_we       (mcu_r_we),       // WR-EVENT-FIX rev2
        .r_we_idx   (mcu_r_we_idx),

        .int0_in    (mcu_start),      // pin 30 INT0 = GO (alpha8201.cpp:57)
        .int1_in    (1'b0),           // pin 31 INT1 = n.c. (alpha8201.cpp:58)

        .dbg_pc(dbg_pc), .dbg_op(dbg_op), .dbg_illegal(dbg_illegal),
        .dbg_a(), .dbg_b(), .dbg_x(), .dbg_y()
    );

endmodule
