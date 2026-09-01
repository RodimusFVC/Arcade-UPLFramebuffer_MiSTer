//============================================================================
//
// UPLFramebuffer for MiSTer
// Copyright (C) 2026 Rodimus
// Based on Tutankham core structure
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
    `include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// SDRAM pins are driven by the controller inside upl_rom - tie-off removed.

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio_l, audio_r;
assign AUDIO_L = pause_cpu ? 16'd0 : audio_l;
assign AUDIO_R = pause_cpu ? 16'd0 : audio_r;
assign AUDIO_S = 1;   // signed
assign AUDIO_MIX = 0; // no mix, true stereo

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

///////////////////////////////////////////////////

wire [1:0] ar = status[14:13];

// set_id: MRA index 5, captured inside upl_rom and exposed by the game top.
//   0x00-0x0C ninjakd2 / mnight / arkarea / robokid (ROT0)   0x0D-0x0F omegaf (ROT270)
wire [7:0] set_id;
wire is_vertical = (set_id >= 8'h0D);

// Aspect keys off the same split as screen_rotate, so the two can never disagree.
wire horz = ~is_vertical | status[12];

assign VIDEO_ARX = horz ? ((!ar) ? 12'd4 : (ar - 1'd1)) : ((!ar) ? 12'd3 : (ar - 1'd1));
assign VIDEO_ARY = horz ? ((!ar) ? 12'd3 : 12'd0) : ((!ar) ? 12'd4 : 12'd0);

`include "build_id.v"
localparam CONF_STR = {
	"UPLFRAMEBUFFER;;",
	"P1,Video Options;",
	"P1ODE,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"P1OC,Orientation,Vert,Horz;",
	"P1OB,HDMI Flip,Off,On;",
	"P1OM,CRT Flip,Off,On;",
	"P1OFH,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"P2,Pause Options;",
	"P2OP,Pause when OSD is open,On,Off;",
	"P2OQ,Dim video after 10s,On,Off;",
	"-;",
	"P3,High Score Options;",
	"P3OR,Autosave Hiscores,Off,On;",
	"-;",
	// Dev instrument, hidden for release. Uncomment with the .rd_mode() connection
	// below to bring it back; status[20:19] = 0 = Early is the correct setting.
	// "OJK,SDRAM Rd Latch,Early,Normal,Late;",
	// "-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Attack,Jump,Coin,Start 1P,Start 2P,Pause;",
	"jn,A,B,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [31:0] status;
wire [10:0] ps2_key;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;
wire        ioctl_wait;

wire [15:0] joystick_0, joystick_1;

wire [21:0] gamma_bus;
wire        direct_video;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_60M),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

////////////////////   CLOCKS   ///////////////////
//   Fabric 60.000 MHz = 50 MHz refclk x 12/10 (integer PLL: M=12, N=1, C=10).
//     60 / 10 = 6.0 MHz = XTAL 12 / 2 -> main Z80 + pixel clock
//     60 / 12 = 5.0 MHz = 5 MHz XTAL  -> sound Z80
//     60 / 40 = 1.5 MHz = XTAL 12 / 8 -> both YM2203
wire CLK_60M;
wire locked;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(CLK_60M),
    .locked(locked)
);

assign CLK_VIDEO = CLK_60M;

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

// SDRAM power-on reset. Must exclude ioctl_download: a reset including it holds the
// load FSM idle for the whole transfer and no byte lands. High ~15 cycles, then low.
reg  [3:0] por_cnt = 4'd0;
wire       por_reset = ~&por_cnt;
always @(posedge CLK_60M) if (por_reset) por_cnt <= por_cnt + 1'b1;

///////////////////         Keyboard           //////////////////

reg btn_up       = 0;
reg btn_down     = 0;
reg btn_left     = 0;
reg btn_right    = 0;
reg btn_attack   = 0;
reg btn_jump     = 0;
reg btn_coin1    = 0;
reg btn_coin2    = 0;
reg btn_1p_start = 0;
reg btn_2p_start = 0;
reg btn_pause    = 0;
reg btn_service  = 0;

wire pressed = ~ps2_key[9];
wire [7:0] code = ps2_key[7:0];
always @(posedge CLK_60M) begin
	reg old_state;
	old_state <= ps2_key[10];
	if(old_state != ps2_key[10]) begin
		case(code)
			'h16: btn_1p_start <= pressed; // 1 = Player 1 Start
			'h1E: btn_2p_start <= pressed; // 2 = Player 2 Start
			'h2E: btn_coin1    <= pressed; // 5 = Coin Input 1
			'h36: btn_coin2    <= pressed; // 6 = Coin Input 2
			'h4D: btn_pause    <= pressed; // P = Pause
			'h46: btn_service  <= pressed; // 9 = Test Advance

			'h75: btn_up       <= pressed; // up         = Up
			'h72: btn_down     <= pressed; // down       = Down
			'h6B: btn_left     <= pressed; // left       = Left
			'h74: btn_right    <= pressed; // right      = Right
			'h14: btn_attack   <= pressed; // ctrl       = Attack
			'h12: btn_jump     <= pressed; // left shift = Jump
		endcase 
	end
end

//////////////////  Game select (mod byte, MRA <rom index="5">)  ///////////////////////////

//////////////////  Arcade Buttons/Interfaces   ///////////////////////////

// Every UPL set here is 2-button (ninjakd2.cpp INPUT_PORTS common / common_2p).

//Player 1
wire m_up1      = btn_up        | joystick_0[3];
wire m_down1    = btn_down      | joystick_0[2];
wire m_left1    = btn_left      | joystick_0[1];
wire m_right1   = btn_right     | joystick_0[0];
wire m_attack1  = btn_attack    | joystick_0[4];
wire m_jump1    = btn_jump      | joystick_0[5];

//Player 2 (cocktail)
wire m_up2      = btn_up        | joystick_1[3];
wire m_down2    = btn_down      | joystick_1[2];
wire m_left2    = btn_left      | joystick_1[1];
wire m_right2   = btn_right     | joystick_1[0];
wire m_attack2  = btn_attack    | joystick_1[4];
wire m_jump2    = btn_jump      | joystick_1[5];

//Start/Coin
wire m_coin1    = btn_coin1     | joystick_0[6];
wire m_coin2    = btn_coin2     | joystick_1[6];
wire m_start1   = btn_1p_start  | joystick_0[7];
wire m_start2   = btn_2p_start  | joystick_0[8];
wire m_pause    = btn_pause     | joystick_0[9];

//Service Mode
wire m_service  = btn_service                  ;

// Hook for a 180 deg control transform if a set ever needs it; unused on UPL.
wire ctrl_flip_ud = 1'b0;

wire m_up1_c   = ctrl_flip_ud ? m_down1 : m_up1;
wire m_down1_c = ctrl_flip_ud ? m_up1   : m_down1;
wire m_up2_c   = ctrl_flip_ud ? m_down2 : m_up2;
wire m_down2_c = ctrl_flip_ud ? m_up2   : m_down2;

wire m_left1_c  = ctrl_flip_ud ? m_right1 : m_left1;
wire m_right1_c = ctrl_flip_ud ? m_left1  : m_right1;
wire m_left2_c  = ctrl_flip_ud ? m_right2 : m_left2;
wire m_right2_c = ctrl_flip_ud ? m_left2  : m_right2;

// MAME port assembly (ninjakd2.cpp:1156). All UPL inputs are IP_ACTIVE_LOW.
//   KEYCOIN: 0 START1  1 START2  4 SERVICE  6 COIN1  7 COIN2
//   PAD:     0 RIGHT   1 LEFT    2 DOWN     3 UP     4 BUTTON1  5 BUTTON2
wire [7:0] keycoin_port = ~{m_coin2, m_coin1, 1'b0, m_service, 1'b0, 1'b0, m_start2, m_start1};
wire [7:0] pad1_port    = ~{2'b00, m_jump1, m_attack1, m_up1_c, m_down1_c, m_left1_c, m_right1_c};
wire [7:0] pad2_port    = ~{2'b00, m_jump2, m_attack2, m_up2_c, m_down2_c, m_left2_c, m_right2_c};

// Hiscore is DISABLED: restore corrupts loaded data, cause not found. Tied off here,
// and index 3 is commented out in every MRA. To re-enable, instantiate hiscore (the
// standard block is in any sibling core), drive the wires below, and restore index 3.
wire [15:0] hs_address      = 16'd0;
wire  [7:0] hs_data_in      = 8'd0;
wire  [7:0] hs_data_out     = 8'd0;       // hiscore disabled; nothing drives this
wire        hs_write_enable = 1'b0;
wire        hs_access_read  = 1'b0;
wire        hs_access_write = 1'b0;
wire        hs_pause        = 1'b0;
wire        hs_configured   = 1'b0;
assign      ioctl_din       = 8'd0;
assign      ioctl_upload_req = 1'b0;

// PAUSE SYSTEM
wire pause_cpu;
wire [23:0] rgb_out;
pause #(8,8,8,60) pause
(
	.*,
	.clk_sys(CLK_60M),
	.user_button(m_pause),
	.pause_request(hs_pause),
	.options(~status[26:25])
);

///////////////                 Video                  ////////////////

wire hblank, vblank;
wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;

// Only omegaf (set_id 0x0D-0x0F) is ROT270; every other UPL set here is ROT0.
wire rotate_ccw  = 1'b1;                                    // ROT270 = counter-clockwise
wire no_rotate   = ~is_vertical | status[12] | direct_video;
wire flip        = status[11];
screen_rotate screen_rotate(.*);

arcade_video #(256,24) arcade_video
(
	.*,

	.clk_video(CLK_60M),

	.RGB_in(rgb_out),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),

	.fx(status[17:15])
);

// DIP switch
reg [7:0] dip_sw[8] = '{8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_60M) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
wire [7:0] sw0 = dip_sw[0];

UPLFramebuffer uplframebuffer_inst
(
	.reset(reset),
	.por_reset(por_reset),
	.clk_60m(CLK_60M),

	.keycoin(keycoin_port),
	.pad1(pad1_port),
	.pad2(pad2_port),
	.dsw1(dip_sw[0]),
	.dsw2(dip_sw[1]),

	.set_id(set_id),

	.video_hsync(hs),
	.video_vsync(vs),
	.video_vblank(vblank),
	.video_hblank(hblank),
	.ce_pix(ce_pix),

	.video_r(r),
	.video_g(g),
	.video_b(b),

	.sound_l(audio_l),
	.sound_r(audio_r),

	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_download(ioctl_download),
	.ioctl_wait(ioctl_wait),

	.crt_flip(status[22]),          // CRT Flip

	.pause(pause_cpu),

	.rd_mode(2'd0),                 // SDRAM read latch, Early. status[20:19] when the OSD entry is back

	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
);


endmodule
