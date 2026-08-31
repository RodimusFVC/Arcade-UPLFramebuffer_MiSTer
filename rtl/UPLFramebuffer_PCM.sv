//============================================================================
//
//  UPLFramebuffer_PCM.sv — ninjakd2 sample player (ninjakd2.cpp:817).
//  Copyright (C) 2026 Rodimus
//
//  A write to 0xF000 selects a 256-byte-aligned start page. Bytes are streamed
//  from the PCM ROM at a fixed 16300 Hz (NE555, measured on the PCB) until a
//  0x00 terminator. Writing a page whose first byte is 0x00 stops playback,
//  which is MAME's "end - start == 0" case.
//
//  ninjakd2 family only: MAME removes the samples device for mnight onward.
//
//============================================================================

module UPLFramebuffer_PCM
(
    input                clk,          // 60 MHz fabric
    input                reset,
    input                pause,

    input          [7:0] cmd,          // value written to 0xF000
    input                cmd_wr,       // one-clk strobe

    // ---- PCM ROM, one byte per sample period (SDRAM client via upl_rom)
    output reg    [15:0] rom_addr,
    output reg           rom_req,
    input                rom_ack,
    input          [7:0] rom_data,

    output signed [15:0] sample_out
);

    // 60 MHz / 16300 Hz = 3681 clocks per sample. One read takes ~8.5 clocks
    // with the arbiter saturated, so a fetch always completes inside a period.
    localparam [11:0] RATE_TOP = 12'd3680;

    reg [11:0] rate_cnt = 12'd0;
    reg        playing  = 1'b0;
    reg        busy     = 1'b0;      // a fetch is outstanding
    reg [15:0] addr     = 16'd0;
    reg  [7:0] cur      = 8'd0;      // sample byte currently being held

    wire rate_tick = (rate_cnt == RATE_TOP);

    always_ff @(posedge clk) begin
        if (reset) begin
            rate_cnt <= 12'd0;
            playing  <= 1'b0;
            busy     <= 1'b0;
            rom_req  <= 1'b0;
            cur      <= 8'd0;
            addr     <= 16'd0;
        end else begin
            rate_cnt <= rate_tick ? 12'd0 : rate_cnt + 12'd1;

            // A new command always restarts: MAME's start_raw replaces the channel.
            if (cmd_wr) begin
                addr    <= {cmd, 8'd0};
                playing <= 1'b1;
                busy    <= 1'b0;
                rom_req <= 1'b0;
            end else if (busy) begin
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    busy    <= 1'b0;
                    if (rom_data == 8'd0) begin
                        playing <= 1'b0;         // terminator
                        cur     <= 8'd0;
                    end else begin
                        cur  <= rom_data;
                        addr <= addr + 16'd1;
                        if (&addr) playing <= 1'b0;   // ran off the end of the ROM
                    end
                end
            end else if (playing && rate_tick && !pause) begin
                rom_addr <= addr;
                rom_req  <= 1'b1;
                busy     <= 1'b1;
            end
        end
    end

    // MAME stores samples as rom[i] << 7, i.e. unsigned 0..0x7F80. The bytes are
    // centred on 0x80 (0x00 cannot appear, it terminates), so the offset is DC and
    // the PCB's analogue path strips it. Subtract it here instead of emitting a
    // half-scale DC step on every start and stop.
    wire signed [15:0] centred = $signed({1'b0, cur, 7'd0}) - 16'sd16384;

    assign sample_out = (pause || !playing) ? 16'sd0 : centred;

endmodule
