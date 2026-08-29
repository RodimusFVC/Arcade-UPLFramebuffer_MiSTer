//============================================================================
//  hmcs40_decoder — standalone combinational HMCS40 opcode decoder.
//============================================================================

module hmcs40_decoder (
    input  wire [9:0] op,
    output reg  [6:0] id
);

    localparam [6:0]
        I_ILL   = 7'd0,
        I_LAB   = 7'd1,  I_LBA   = 7'd2,  I_LAY   = 7'd3,  I_LASPX = 7'd4,  I_LASPY = 7'd5,  I_XAMR  = 7'd6,
        I_LXA   = 7'd7,  I_LYA   = 7'd8,  I_LXI   = 7'd9,  I_LYI   = 7'd10, I_IY    = 7'd11, I_DY    = 7'd12,
        I_AYY   = 7'd13, I_SYY   = 7'd14, I_XSP   = 7'd15,
        I_LAM   = 7'd16, I_LBM   = 7'd17, I_XMA   = 7'd18, I_XMB   = 7'd19, I_LMAIY = 7'd20, I_LMADY = 7'd21,
        I_LMIIY = 7'd22, I_LAI   = 7'd23, I_LBI   = 7'd24,
        I_AI    = 7'd25, I_IB    = 7'd26, I_DB    = 7'd27, I_AMC   = 7'd28, I_SMC   = 7'd29, I_AM    = 7'd30,
        I_DAA   = 7'd31, I_DAS   = 7'd32, I_NEGA  = 7'd33, I_COMB  = 7'd34, I_SEC   = 7'd35, I_REC   = 7'd36,
        I_TC    = 7'd37, I_ROTL  = 7'd38, I_ROTR  = 7'd39, I_OR    = 7'd40,
        I_MNEI  = 7'd41, I_YNEI  = 7'd42, I_ANEM  = 7'd43, I_BNEM  = 7'd44, I_ALEI  = 7'd45, I_ALEM  = 7'd46, I_BLEM = 7'd47,
        I_SEM   = 7'd48, I_REM   = 7'd49, I_TM    = 7'd50,
        I_BR    = 7'd51, I_CAL   = 7'd52, I_LPU   = 7'd53, I_TBR   = 7'd54, I_RTN   = 7'd55,
        I_SEIE  = 7'd56, I_SEIF0 = 7'd57, I_SEIF1 = 7'd58, I_SETF  = 7'd59, I_SECF  = 7'd60,
        I_REIE  = 7'd61, I_REIF0 = 7'd62, I_REIF1 = 7'd63, I_RETF  = 7'd64, I_RECF  = 7'd65,
        I_TI0   = 7'd66, I_TI1   = 7'd67, I_TIF0  = 7'd68, I_TIF1  = 7'd69, I_TTF   = 7'd70,
        I_LTI   = 7'd71, I_LTA   = 7'd72, I_LAT   = 7'd73, I_RTNI  = 7'd74,
        I_SED   = 7'd75, I_RED   = 7'd76, I_TD    = 7'd77, I_SEDD  = 7'd78, I_REDD  = 7'd79,
        I_LAR   = 7'd80, I_LBR   = 7'd81, I_LRA   = 7'd82, I_LRB   = 7'd83, I_P     = 7'd84;

    wire [9:0] top4 = op & 10'h3F0;
    wire [9:0] top8 = op & 10'h3FC;

    always @* begin
             if (top4 == 10'h1C0 || top4 == 10'h1D0 || top4 == 10'h1E0 || top4 == 10'h1F0) id = I_BR;
        else if (top4 == 10'h3C0 || top4 == 10'h3D0 || top4 == 10'h3E0 || top4 == 10'h3F0) id = I_CAL;
        else if (top4 == 10'h340 || top4 == 10'h350) id = I_LPU;
        else if (top4 == 10'h010) id = I_LMIIY;
        else if (top4 == 10'h070) id = I_LAI;
        else if (top4 == 10'h080) id = I_AI;
        else if (top4 == 10'h0F0) id = I_XAMR;
        else if (top4 == 10'h140) id = I_LXI;
        else if (top4 == 10'h150) id = I_LYI;
        else if (top4 == 10'h160) id = I_LBI;
        else if (top4 == 10'h170) id = I_LTI;
        else if (top4 == 10'h210) id = I_MNEI;
        else if (top4 == 10'h270) id = I_ALEI;
        else if (top4 == 10'h280) id = I_YNEI;
        else if (top8 == 10'h0C0 || top8 == 10'h0C4) id = I_LAR;
        else if (top8 == 10'h0E0 || top8 == 10'h0E4) id = I_LBR;
        else if (top8 == 10'h2C0 || top8 == 10'h2C4) id = I_LRA;
        else if (top8 == 10'h2E0 || top8 == 10'h2E4) id = I_LRB;
        else if (top8 == 10'h360 || top8 == 10'h364) id = I_TBR;
        else if (top8 == 10'h368 || top8 == 10'h36C) id = I_P;
        else if (top8 == 10'h000) id = I_XSP;
        else if (top8 == 10'h004) id = I_SEM;
        else if (top8 == 10'h008) id = I_LAM;
        else if (top8 == 10'h020) id = I_LBM;
        else if (top8 == 10'h0D0) id = I_SEDD;
        else if (top8 == 10'h200) id = I_TM;
        else if (top8 == 10'h204) id = I_REM;
        else if (top8 == 10'h208) id = I_XMA;
        else if (top8 == 10'h220) id = I_XMB;
        else if (top8 == 10'h2D0) id = I_REDD;
        else if (op == 10'h024) id = I_BLEM;
        else if (op == 10'h030) id = I_AMC;
        else if (op == 10'h034) id = I_AM;
        else if (op == 10'h03C) id = I_LTA;
        else if (op == 10'h040) id = I_LXA;
        else if (op == 10'h045) id = I_DAS;
        else if (op == 10'h046) id = I_DAA;
        else if (op == 10'h04C) id = I_REC;
        else if (op == 10'h04F) id = I_SEC;
        else if (op == 10'h050) id = I_LYA;
        else if (op == 10'h054) id = I_IY;
        else if (op == 10'h058) id = I_AYY;
        else if (op == 10'h060) id = I_LBA;
        else if (op == 10'h064) id = I_IB;
        else if (op == 10'h090) id = I_SED;
        else if (op == 10'h094) id = I_TD;
        else if (op == 10'h0A0) id = I_SEIF1;
        else if (op == 10'h0A1) id = I_SECF;
        else if (op == 10'h0A2) id = I_SEIF0;
        else if (op == 10'h0A4) id = I_SEIE;
        else if (op == 10'h0A5) id = I_SETF;
        else if (op == 10'h110 || op == 10'h111) id = I_LMAIY;
        else if (op == 10'h114 || op == 10'h115) id = I_LMADY;
        else if (op == 10'h118) id = I_LAY;
        else if (op == 10'h120) id = I_OR;
        else if (op == 10'h124) id = I_ANEM;
        else if (op == 10'h1A0) id = I_TIF1;
        else if (op == 10'h1A1) id = I_TI1;
        else if (op == 10'h1A2) id = I_TIF0;
        else if (op == 10'h1A3) id = I_TI0;
        else if (op == 10'h1A5) id = I_TTF;
        else if (op == 10'h224) id = I_ROTR;
        else if (op == 10'h225) id = I_ROTL;
        else if (op == 10'h230) id = I_SMC;
        else if (op == 10'h234) id = I_ALEM;
        else if (op == 10'h23C) id = I_LAT;
        else if (op == 10'h240) id = I_LASPX;
        else if (op == 10'h244) id = I_NEGA;
        else if (op == 10'h24F) id = I_TC;
        else if (op == 10'h250) id = I_LASPY;
        else if (op == 10'h254) id = I_DY;
        else if (op == 10'h258) id = I_SYY;
        else if (op == 10'h260) id = I_LAB;
        else if (op == 10'h267) id = I_DB;
        else if (op == 10'h290) id = I_RED;
        else if (op == 10'h2A0) id = I_REIF1;
        else if (op == 10'h2A1) id = I_RECF;
        else if (op == 10'h2A2) id = I_REIF0;
        else if (op == 10'h2A4) id = I_REIE;
        else if (op == 10'h2A5) id = I_RETF;
        else if (op == 10'h320) id = I_COMB;
        else if (op == 10'h324) id = I_BNEM;
        else if (op == 10'h3A4) id = I_RTNI;
        else if (op == 10'h3A7) id = I_RTN;
        else id = I_ILL;
    end

endmodule
