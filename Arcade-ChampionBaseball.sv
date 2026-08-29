//============================================================================
//
// ChampionBaseball for MiSTer
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
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

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

// set_id: MRA index 5, captured inside champbas_rom and exposed by the game top.
//   0x00-0x06 champbas family (ROT0)   0x07 talbot   0x08-0x0A exctsccr family   (both ROT270)
wire [7:0] set_id;
wire is_vertical = (set_id >= 8'h07);

// got squashed into a 3:4 portrait window. Aspect must follow the SAME set_id split as the
wire horz = ~is_vertical | status[12];

assign VIDEO_ARX = horz ? ((!ar) ? 12'd4 : (ar - 1'd1)) : ((!ar) ? 12'd3 : (ar - 1'd1));
assign VIDEO_ARY = horz ? ((!ar) ? 12'd3 : 12'd0) : ((!ar) ? 12'd4 : 12'd0);

`include "build_id.v"
localparam CONF_STR = {
	"CHAMPIONBASEBALL;;",
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
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Throw,Steal,Changes,Coin,Start 1P,Start 2P,Pause;",
	"jn,A,B,X,Select,Start,R,L;",
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

wire [15:0] joystick_0, joystick_1;
wire [15:0] joy = joystick_0 | joystick_1;

wire [21:0] gamma_bus;
wire        direct_video;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_49M),
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
	.ioctl_index(ioctl_index),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

////////////////////   CLOCKS   ///////////////////
//     49.152 / 16 = 3.072 MHz = XTAL 18.432 / 6  -> both Z80s
//     49.152 /  8 = 6.144 MHz = XTAL 18.432 / 3  -> pixel clock
wire CLK_49M;
wire locked;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(CLK_49M),
    .locked(locked)
);

assign CLK_VIDEO = CLK_49M;

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

///////////////////         Keyboard           //////////////////

reg btn_up       = 0;
reg btn_down     = 0;
reg btn_left     = 0;
reg btn_right    = 0;
reg btn_fire     = 0;
reg btn_fire2    = 0;
reg btn_coin1    = 0;
reg btn_coin2    = 0;
reg btn_1p_start = 0;
reg btn_2p_start = 0;
reg btn_pause    = 0;
reg btn_service  = 0;

wire pressed = ~ps2_key[9];
wire [7:0] code = ps2_key[7:0];
always @(posedge CLK_49M) begin
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
			'h14: btn_fire     <= pressed; // ctrl       = Draw Slow
			'h12: btn_fire2    <= pressed; // left shift = Draw Fast
		endcase 
	end
end

//////////////////  Game select (mod byte, MRA <rom index="5">)  ///////////////////////////

//////////////////  Arcade Buttons/Interfaces   ///////////////////////////

// champbas has THREE buttons (INPUT_PORTS champbas, champbas.cpp:761-771):

//Player 1
wire m_up1      = btn_up        | joystick_0[3];
wire m_down1    = btn_down      | joystick_0[2];
wire m_left1    = btn_left      | joystick_0[1];
wire m_right1   = btn_right     | joystick_0[0];
wire m_throw1   = btn_fire      | joystick_0[4];
wire m_steal1   = btn_fire2     | joystick_0[5];
wire m_change1  =                 joystick_0[6];

//Player 2 (cocktail)
wire m_up2      = btn_up        | joystick_1[3];
wire m_down2    = btn_down      | joystick_1[2];
wire m_left2    = btn_left      | joystick_1[1];
wire m_right2   = btn_right     | joystick_1[0];
wire m_throw2   = btn_fire      | joystick_1[4];
wire m_steal2   = btn_fire2     | joystick_1[5];
wire m_change2  =                 joystick_1[6];

//Start/Coin
wire m_coin1    = btn_coin1     | joystick_0[7];
wire m_coin2    = btn_coin2     | joystick_1[7];
wire m_start1   = btn_1p_start  | joystick_0[8];
wire m_start2   = btn_2p_start  | joystick_0[9];
wire m_pause    = btn_pause     | joystick_0[10];

//Service Mode
wire m_service  = btn_service                  ;

// User reports Exciting Soccer's up/down inverted. Exciting Soccer boots
// flip_screen=1 (maincpu.dasm $010C writes $00 to $A003) where champbas boots
// affected. Left/right are deliberately NOT swapped — the report was
wire ctrl_flip_ud = 1'b0;

wire m_up1_c   = ctrl_flip_ud ? m_down1 : m_up1;
wire m_down1_c = ctrl_flip_ud ? m_up1   : m_down1;
wire m_up2_c   = ctrl_flip_ud ? m_down2 : m_up2;
wire m_down2_c = ctrl_flip_ud ? m_up2   : m_down2;

// reversed, which completes the picture — flip_screen=1 is a 180 deg transform,
wire m_left1_c  = ctrl_flip_ud ? m_right1 : m_left1;
wire m_right1_c = ctrl_flip_ud ? m_left1  : m_right1;
wire m_left2_c  = ctrl_flip_ud ? m_right2 : m_left2;
wire m_right2_c = ctrl_flip_ud ? m_left2  : m_right2;

// MAME port assembly. All champbas inputs are IP_ACTIVE_LOW, so these invert.
wire [7:0] p1_port     = ~{m_down1_c, m_right1_c, m_left1_c, m_up1_c, m_steal1, m_change1, 1'b0, m_throw1};
wire [7:0] p2_port     = ~{m_down2_c, m_right2_c, m_left2_c, m_up2_c, m_steal2, m_change2, 1'b0, m_throw2};
wire [7:0] system_port = ~{4'b0000, m_coin2, m_coin1, m_start2, m_start1};

// HISCORE DISABLED 2026-08-24 -- restore corrupts loaded data, cause not found.
// Module tied off here AND index-3 commented out in every MRA. To re-enable:
// restore the wire decls below, uncomment the hiscore instance further down,
// and un-comment index 3 in the MRAs.
wire [15:0] hs_address      = 16'd0;
wire  [7:0] hs_data_in      = 8'd0;
wire  [7:0] hs_data_out;                  // driven by the game module, harmless
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
pause #(8,8,8,10) pause
(
	.*,
	.clk_sys(CLK_49M),
	.user_button(m_pause),
	.pause_request(hs_pause),
	.options(~status[26:25])
);

///////////////                 Video                  ////////////////

wire hblank, vblank;
wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;

// documented revert path ("arcade_video back to #(256,24) and drop .ce_pix below"). It existed to

// ROTATION: champbas is ROT0 (horizontal). Talbot and the whole Exciting Soccer family are ROT270.
//   0x00-0x06 champbas family (ROT0)   0x07 talbot   0x08-0x0A exctsccr family (both ROT270)
wire rotate_ccw  = 1'b1;                                    // ROT270 = counter-clockwise
wire no_rotate   = ~is_vertical | status[12] | direct_video;
wire flip        = status[11];
screen_rotate screen_rotate(.*);

arcade_video #(256,24) arcade_video
(
	.*,

	.clk_video(CLK_49M),

	.RGB_in(rgb_out),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),

	.fx(status[17:15])
);

// DIP switch
reg [7:0] dip_sw[8] = '{8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_49M) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
wire [7:0] sw0 = dip_sw[0];

ChampionBaseball championbaseball_inst
(
	// in permanent reset: h_cnt/v_cnt never left 0, HSync/VSync were stuck low, no sync at all.
	.reset(reset),        // MiSTer reset is active-high; champbas modules are active-high too

	.clk_49m(CLK_49M),

	.p1(p1_port),
	.p2(p2_port),
	.dsw(sw0),
	.system(system_port),

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

	.hs_addr(hs_address),
	.hs_din(hs_data_in),
	.hs_dout(hs_data_out),
	.hs_we(hs_write_enable),
	.hs_active(hs_access_read | hs_access_write),

	.crt_flip(status[22]),          // CRT Flip

	.pause(pause_cpu)
);

// hiscore #(
// 	.HS_ADDRESSWIDTH(16),
// 	.CFG_ADDRESSWIDTH(3),
// 	.CFG_LENGTHWIDTH(2)
// ) hi (
// 	.*,
// 	.clk(CLK_49M),
// 	.paused(pause_cpu),
// 	.autosave(status[27]),
// 	.ram_address(hs_address),
// 	.data_from_ram(hs_data_out),
// 	.data_to_ram(hs_data_in),
// 	.data_from_hps(ioctl_dout),
// 	.data_to_hps(ioctl_din),
// 	.ram_write(hs_write_enable),
// 	.ram_intent_read(hs_access_read),
// 	.ram_intent_write(hs_access_write),
// 	.pause_cpu(hs_pause),
// 	.configured(hs_configured)
// );

endmodule
