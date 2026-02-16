/*
 * GTX Debug Reporter with Parser Counters
 *
 * Periodically sends GTX status AND parser pipeline counters over UART.
 * Format: "Q:X L:X T:X R:X BL:X CD:X EI:X PR:X ST:X SD:XXXX FC:XXXX UC:XXXX MC:XXXX MX:XXXX NM:XXXX [OK]\r\n"
 *   Q  = QPLL lock (1=locked, 0=not)
 *   L  = REFCLK lost (1=lost, 0=present)
 *   T  = TX reset done (1=done, 0=in reset)
 *   R  = RX reset done (1=done, 0=in reset)
 *   BL = PCS block lock (1=locked, 0=searching)
 *   CD = CDR lock (info only - unreliable for 10GBASE-R, can show false positives)
 *   EI = Electrical idle (info only - unreliable for 10GBASE-R, can show false positives)
 *   PR = PCS reset (1=reset/FSM stuck, 0=running) - CRITICAL: must be 0!
 *   ST = Block lock FSM state (0-7, 7=LOCKED)
 *   SD = Start Detect count (XGMII Start codes seen on RX - confirms decoder works)
 *   FC = Frame count (Start->Terminate pairs) - BEST link indicator!
 *   UC = UDP packet count
 *   MC = MoldUDP64 packet count
 *   MX = MoldUDP64 messages extracted
 *   NM = NASDAQ ITCH total messages parsed
 *   MT = Last ITCH message type (ASCII: A=Add, E=Exec, X=Cancel, D=Delete, U=Replace)
 *   SL = Last stock locate (16-bit identifier)
 *   PX = Last price (32-bit fixed-point, 4 implied decimals)
 *   RB = Raw first 8 Bytes from MoldUDP64 output (before ITCH parser)
 *        Byte 0 should be message type ASCII. If 0xD4/0x31 = UDP header leak
 *   SY = Last parsed Stock Symbol from ITCH parser (8 ASCII chars as hex)
 *
 * Link Status [OK]/[XK]:
 *   - Based on: QPLL lock, block lock, PCS not in reset
 *   - CD and EI are NOT used (Xilinx IP doesn't use them for 10GBASE-R either)
 *   - For real link validation, watch FC (frame count) increasing
 *
 * Note: This module samples GTX debug signals which helps keep signal paths
 * active and prevents Vivado optimization that can affect QPLL/PCS locking.
 *
 *
 * Copyright 2026 Adilson Dias
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Author: Adilson Dias
 * GitHub: https://github.com/adilsondias-engineer/fpga-trading-systems
 * Date: January 2026
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gtx_debug_reporter #(
        parameter CLK_FREQ  = 200_000_000,
        parameter BAUD_RATE = 115200,
        parameter REPORT_MS = 500  // Report interval in milliseconds
    )(
        input  wire clk,
        input  wire rst,

        // GTX Status inputs
        input  wire qpll_lock,
        input  wire qpll_refclk_lost,
        input  wire tx_resetdone,
        input  wire rx_resetdone,

        // Extended debug inputs (keep these sampled to prevent optimization)
        input  wire debug_por_done,
        input  wire debug_qpll_reset,
        input  wire debug_gtx_reset,
        input  wire debug_tx_userrdy,
        input  wire debug_rx_userrdy,
        input  wire debug_refclk_present,

        // PCS status
        input  wire pcs_block_lock,

        // RX debug signals (directly from GTX/PCS)
        input  wire rx_header_valid,
        input  wire rx_datavalid,
        input  wire [2:0] block_lock_state,
        input  wire rx_cdrlock,
        input  wire rx_elecidle,
        input  wire tx_clk_heartbeat,
        input  wire pcs_reset,
        input  wire reset_int_dbg,
        input  wire gtx_ready_dbg,

        // Parser pipeline counters
        input  wire [31:0] start_detect_count,
        input  wire [31:0] frame_count,
        input  wire [31:0] udp_packet_count,
        input  wire [31:0] mold_packet_count,
        input  wire [31:0] mold_msg_extracted,
        input  wire [31:0] nasdaq_total_messages,

        // ITCH parsed fields (last message)
        input  wire [7:0]  itch_msg_type,
        input  wire [15:0] itch_stock_locate,
        input  wire [31:0] itch_price,

        // Raw debug bytes from ITCH path (tx_clk domain, needs CDC)
        input  wire [63:0] debug_raw_bytes,    // First 8 bytes of last ITCH msg from MoldUDP64
        input  wire [63:0] debug_itch_symbol,  // Last parsed symbol from ITCH parser

        // BBO path debug counters (optional - tie to 0 if not used)
        input  wire [15:0] itch_fifo_wr_count,
        input  wire [15:0] itch_fifo_rd_count,
        input  wire [15:0] bbo_update_count,
        input  wire [15:0] bbo_fifo_wr_count,
        input  wire [15:0] bbo_fifo_rd_count,
        input  wire [15:0] bbo_tx_count,

        // UART output
        output wire uart_tx
    );

    // Report interval in clock cycles
    localparam REPORT_CYCLES = (CLK_FREQ / 1000) * REPORT_MS;

    // Message: "Q:X L:X T:X R:X BL:X CD:X EI:X PR:X ST:X SD:XXXX FC:XXXX UC:XXXX MC:XXXX MX:XXXX NM:XXXX MT:X SL:XXXX PX:XXXXXXXX IW:XXXX IR:XXXX BU:XXXX BW:XXXX BR:XXXX TX:XXXX RB:XXXXXXXXXXXXXXXX SY:XXXXXXXXXXXXXXXX\r\n"
    // PR = PCS reset (should be 0 for FSM to run - if PR:1, FSM is held in reset!)
    // SD = Start Detect count (XGMII Start codes seen on RX)
    // MT/SL/PX = Last parsed ITCH message type, stock locate, price
    // BBO Path: IW=ITCH FIFO Wr, IR=ITCH FIFO Rd, BU=BBO Update, BW=BBO FIFO Wr, BR=BBO FIFO Rd, TX=BBO TX
    // RB = Raw first 8 bytes before ITCH parser, SY = parsed symbol after ITCH parser
    localparam MSG_LEN = 203;  // Includes CR+LF (added RB + SY debug fields)

    // State machine
    localparam STATE_IDLE     = 2'd0;
    localparam STATE_BUILD    = 2'd1;
    localparam STATE_SEND     = 2'd2;
    localparam STATE_WAIT     = 2'd3;

    reg [1:0] state;
    reg [31:0] timer;
    reg [7:0] char_idx;  // 8 bits to support MSG_LEN up to 255
    reg [7:0] tx_data;
    reg tx_start;
    wire tx_busy;

    // Status sampling (reduce metastability)
    reg qpll_lock_s, qpll_lost_s, tx_done_s, rx_done_s, blk_lock_s;
    reg qpll_lock_ss, qpll_lost_ss, tx_done_ss, rx_done_ss, blk_lock_ss;
    reg hdr_valid_s, data_valid_s, cdr_lock_s, elec_idle_s, tx_hb_s, pcs_rst_s, rst_int_s, gtx_rdy_s;
    reg hdr_valid_ss, data_valid_ss, cdr_lock_ss, elec_idle_ss, tx_hb_ss, pcs_rst_ss, rst_int_ss, gtx_rdy_ss;
    reg [2:0] blk_state_s, blk_state_ss;

    // Parser counter sampling
    reg [31:0] start_det_s, frame_count_s, udp_count_s, mold_count_s, mold_msg_s, nasdaq_count_s;
    reg [31:0] start_det_ss, frame_count_ss, udp_count_ss, mold_count_ss, mold_msg_ss, nasdaq_count_ss;

    // ITCH field sampling
    reg [7:0]  itch_type_s, itch_type_ss;
    reg [15:0] itch_sl_s, itch_sl_ss;
    reg [31:0] itch_px_s, itch_px_ss;

    // Raw debug byte sampling
    reg [63:0] rb_s, rb_ss;   // Raw first 8 bytes from MoldUDP64
    reg [63:0] sy_s, sy_ss;   // Parsed symbol from ITCH parser

    // BBO path counter sampling
    reg [15:0] iw_s, iw_ss;  // ITCH FIFO write count
    reg [15:0] ir_s, ir_ss;  // ITCH FIFO read count
    reg [15:0] bu_s, bu_ss;  // BBO update count
    reg [15:0] bw_s, bw_ss;  // BBO FIFO write count
    reg [15:0] br_s, br_ss;  // BBO FIFO read count
    reg [15:0] tx_s, tx_ss;  // BBO TX count

    // Message buffer (163 bytes: 161 chars + CR + LF)
    reg [7:0] msg [0:MSG_LEN-1];

    // UART TX instantiation
    uart_tx_simple #(
                       .CLK_FREQ(CLK_FREQ),
                       .BAUD_RATE(BAUD_RATE)
                   ) uart_inst (
                       .clk(clk),
                       .rst(rst),
                       .tx_data(tx_data),
                       .tx_start(tx_start),
                       .tx_busy(tx_busy),
                       .tx(uart_tx)
                   );

    // Helper function: convert nibble to hex ASCII
    function [7:0] hex_char;
        input [3:0] nibble;
        begin
            if (nibble < 10)
                hex_char = "0" + nibble;
            else
                hex_char = "A" + (nibble - 10);
        end
    endfunction

    // Sample status inputs (2-stage sync for CDC)
    always @(posedge clk) begin
        // First stage - GTX status
        qpll_lock_s <= qpll_lock;
        qpll_lost_s <= qpll_refclk_lost;
        tx_done_s   <= tx_resetdone;
        rx_done_s   <= rx_resetdone;
        blk_lock_s  <= pcs_block_lock;
        hdr_valid_s <= rx_header_valid;
        data_valid_s <= rx_datavalid;
        cdr_lock_s  <= rx_cdrlock;
        elec_idle_s <= rx_elecidle;
        blk_state_s <= block_lock_state;
        tx_hb_s     <= tx_clk_heartbeat;
        pcs_rst_s   <= pcs_reset;
        rst_int_s   <= reset_int_dbg;
        gtx_rdy_s   <= gtx_ready_dbg;

        // First stage - parser counters
        start_det_s   <= start_detect_count;
        frame_count_s <= frame_count;
        udp_count_s   <= udp_packet_count;
        mold_count_s  <= mold_packet_count;
        mold_msg_s    <= mold_msg_extracted;
        nasdaq_count_s <= nasdaq_total_messages;

        // First stage - ITCH fields
        itch_type_s   <= itch_msg_type;
        itch_sl_s     <= itch_stock_locate;
        itch_px_s     <= itch_price;

        // First stage - raw debug bytes
        rb_s <= debug_raw_bytes;
        sy_s <= debug_itch_symbol;

        // First stage - BBO path counters
        iw_s <= itch_fifo_wr_count;
        ir_s <= itch_fifo_rd_count;
        bu_s <= bbo_update_count;
        bw_s <= bbo_fifo_wr_count;
        br_s <= bbo_fifo_rd_count;
        tx_s <= bbo_tx_count;

        // Second stage - GTX status
        qpll_lock_ss <= qpll_lock_s;
        qpll_lost_ss <= qpll_lost_s;
        tx_done_ss   <= tx_done_s;
        rx_done_ss   <= rx_done_s;
        blk_lock_ss  <= blk_lock_s;
        hdr_valid_ss <= hdr_valid_s;
        data_valid_ss <= data_valid_s;
        cdr_lock_ss <= cdr_lock_s;
        elec_idle_ss <= elec_idle_s;
        blk_state_ss <= blk_state_s;
        tx_hb_ss    <= tx_hb_s;
        pcs_rst_ss  <= pcs_rst_s;
        rst_int_ss  <= rst_int_s;
        gtx_rdy_ss  <= gtx_rdy_s;

        // Second stage - parser counters
        start_det_ss   <= start_det_s;
        frame_count_ss <= frame_count_s;
        udp_count_ss   <= udp_count_s;
        mold_count_ss  <= mold_count_s;
        mold_msg_ss    <= mold_msg_s;
        nasdaq_count_ss <= nasdaq_count_s;

        // Second stage - ITCH fields
        itch_type_ss  <= itch_type_s;
        itch_sl_ss    <= itch_sl_s;
        itch_px_ss    <= itch_px_s;

        // Second stage - raw debug bytes
        rb_ss <= rb_s;
        sy_ss <= sy_s;

        // Second stage - BBO path counters
        iw_ss <= iw_s;
        ir_ss <= ir_s;
        bu_ss <= bu_s;
        bw_ss <= bw_s;
        br_ss <= br_s;
        tx_ss <= tx_s;
    end

    // Main state machine
    always @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            timer <= 32'd0;
            char_idx <= 8'd0;
            tx_start <= 1'b0;
            tx_data <= 8'd0;
        end
        else begin
            tx_start <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    if (timer >= REPORT_CYCLES - 1) begin
                        timer <= 32'd0;
                        state <= STATE_BUILD;
                    end
                    else begin
                        timer <= timer + 1;
                    end
                end

                STATE_BUILD: begin
                    // Build message: "Q:X L:X T:X R:X BL:X CD:X EI:X ST:X FC:XXXX UC:XXXX MC:XXXX MX:XXXX NM:XXXX [OK]\r\n"

                    // Q: QPLL lock
                    msg[0]  <= "Q";
                    msg[1]  <= ":";
                    msg[2]  <= qpll_lock_ss ? "1" : "0";
                    msg[3]  <= " ";

                    // L: REFCLK lost
                    msg[4]  <= "L";
                    msg[5]  <= ":";
                    msg[6]  <= qpll_lost_ss ? "1" : "0";
                    msg[7]  <= " ";

                    // T: TX reset done
                    msg[8]  <= "T";
                    msg[9]  <= ":";
                    msg[10] <= tx_done_ss ? "1" : "0";
                    msg[11] <= " ";

                    // R: RX reset done
                    msg[12] <= "R";
                    msg[13] <= ":";
                    msg[14] <= rx_done_ss ? "1" : "0";
                    msg[15] <= " ";

                    // BL: Block lock
                    msg[16] <= "B";
                    msg[17] <= "L";
                    msg[18] <= ":";
                    msg[19] <= blk_lock_ss ? "1" : "0";
                    msg[20] <= " ";

                    // CD: CDR lock (CRITICAL - 0 means no valid signal!)
                    msg[21] <= "C";
                    msg[22] <= "D";
                    msg[23] <= ":";
                    msg[24] <= cdr_lock_ss ? "1" : "0";
                    msg[25] <= " ";

                    // EI: Electrical Idle (1 = no signal detected)
                    msg[26] <= "E";
                    msg[27] <= "I";
                    msg[28] <= ":";
                    msg[29] <= elec_idle_ss ? "1" : "0";
                    msg[30] <= " ";

                    // PR: PCS Reset (CRITICAL - must be 0 for FSM to run!)
                    msg[31] <= "P";
                    msg[32] <= "R";
                    msg[33] <= ":";
                    msg[34] <= pcs_rst_ss ? "1" : "0";
                    msg[35] <= " ";

                    // ST: Block lock FSM state (0-7)
                    msg[36] <= "S";
                    msg[37] <= "T";
                    msg[38] <= ":";
                    msg[39] <= "0" + blk_state_ss;
                    msg[40] <= " ";

                    // SD: Start Detect count (XGMII Start codes seen on RX)
                    msg[41] <= "S";
                    msg[42] <= "D";
                    msg[43] <= ":";
                    msg[44] <= hex_char(start_det_ss[15:12]);
                    msg[45] <= hex_char(start_det_ss[11:8]);
                    msg[46] <= hex_char(start_det_ss[7:4]);
                    msg[47] <= hex_char(start_det_ss[3:0]);
                    msg[48] <= " ";

                    // FC: Frame Count (Start->Terminate pairs)
                    msg[49] <= "F";
                    msg[50] <= "C";
                    msg[51] <= ":";
                    msg[52] <= hex_char(frame_count_ss[15:12]);
                    msg[53] <= hex_char(frame_count_ss[11:8]);
                    msg[54] <= hex_char(frame_count_ss[7:4]);
                    msg[55] <= hex_char(frame_count_ss[3:0]);
                    msg[56] <= " ";

                    // UC: UDP packet Count
                    msg[57] <= "U";
                    msg[58] <= "C";
                    msg[59] <= ":";
                    msg[60] <= hex_char(udp_count_ss[15:12]);
                    msg[61] <= hex_char(udp_count_ss[11:8]);
                    msg[62] <= hex_char(udp_count_ss[7:4]);
                    msg[63] <= hex_char(udp_count_ss[3:0]);
                    msg[64] <= " ";

                    // MC: MoldUDP64 packet Count
                    msg[65] <= "M";
                    msg[66] <= "C";
                    msg[67] <= ":";
                    msg[68] <= hex_char(mold_count_ss[15:12]);
                    msg[69] <= hex_char(mold_count_ss[11:8]);
                    msg[70] <= hex_char(mold_count_ss[7:4]);
                    msg[71] <= hex_char(mold_count_ss[3:0]);
                    msg[72] <= " ";

                    // MX: MoldUDP64 Messages eXtracted
                    msg[73] <= "M";
                    msg[74] <= "X";
                    msg[75] <= ":";
                    msg[76] <= hex_char(mold_msg_ss[15:12]);
                    msg[77] <= hex_char(mold_msg_ss[11:8]);
                    msg[78] <= hex_char(mold_msg_ss[7:4]);
                    msg[79] <= hex_char(mold_msg_ss[3:0]);
                    msg[80] <= " ";

                    // NM: NASDAQ Messages parsed
                    msg[81] <= "N";
                    msg[82] <= "M";
                    msg[83] <= ":";
                    msg[84] <= hex_char(nasdaq_count_ss[15:12]);
                    msg[85] <= hex_char(nasdaq_count_ss[11:8]);
                    msg[86] <= hex_char(nasdaq_count_ss[7:4]);
                    msg[87] <= hex_char(nasdaq_count_ss[3:0]);
                    msg[88] <= " ";

                    // MT: Last ITCH Message Type (ASCII character)
                    msg[89]  <= "M";
                    msg[90]  <= "T";
                    msg[91]  <= ":";
                    msg[92]  <= (itch_type_ss != 8'd0) ? itch_type_ss : "-";
                    msg[93]  <= " ";

                    // SL: Last Stock Locate (16-bit)
                    msg[94]  <= "S";
                    msg[95]  <= "L";
                    msg[96]  <= ":";
                    msg[97]  <= hex_char(itch_sl_ss[15:12]);
                    msg[98]  <= hex_char(itch_sl_ss[11:8]);
                    msg[99]  <= hex_char(itch_sl_ss[7:4]);
                    msg[100] <= hex_char(itch_sl_ss[3:0]);
                    msg[101] <= " ";

                    // PX: Last Price (32-bit fixed-point)
                    msg[102] <= "P";
                    msg[103] <= "$";
                    msg[104] <= ":";
                    msg[105] <= hex_char(itch_px_ss[31:28]);
                    msg[106] <= hex_char(itch_px_ss[27:24]);
                    msg[107] <= hex_char(itch_px_ss[23:20]);
                    msg[108] <= hex_char(itch_px_ss[19:16]);
                    msg[109] <= hex_char(itch_px_ss[15:12]);
                    msg[110] <= hex_char(itch_px_ss[11:8]);
                    msg[111] <= hex_char(itch_px_ss[7:4]);
                    msg[112] <= hex_char(itch_px_ss[3:0]);
                    msg[113] <= " ";

                    // IW: ITCH FIFO Write count
                    msg[114] <= "I";
                    msg[115] <= "W";
                    msg[116] <= ":";
                    msg[117] <= hex_char(iw_ss[15:12]);
                    msg[118] <= hex_char(iw_ss[11:8]);
                    msg[119] <= hex_char(iw_ss[7:4]);
                    msg[120] <= hex_char(iw_ss[3:0]);
                    msg[121] <= " ";

                    // IR: ITCH FIFO Read count
                    msg[122] <= "I";
                    msg[123] <= "R";
                    msg[124] <= ":";
                    msg[125] <= hex_char(ir_ss[15:12]);
                    msg[126] <= hex_char(ir_ss[11:8]);
                    msg[127] <= hex_char(ir_ss[7:4]);
                    msg[128] <= hex_char(ir_ss[3:0]);
                    msg[129] <= " ";

                    // BU: BBO Update count (from order book)
                    msg[130] <= "B";
                    msg[131] <= "U";
                    msg[132] <= ":";
                    msg[133] <= hex_char(bu_ss[15:12]);
                    msg[134] <= hex_char(bu_ss[11:8]);
                    msg[135] <= hex_char(bu_ss[7:4]);
                    msg[136] <= hex_char(bu_ss[3:0]);
                    msg[137] <= " ";

                    // BW: BBO FIFO Write count
                    msg[138] <= "B";
                    msg[139] <= "W";
                    msg[140] <= ":";
                    msg[141] <= hex_char(bw_ss[15:12]);
                    msg[142] <= hex_char(bw_ss[11:8]);
                    msg[143] <= hex_char(bw_ss[7:4]);
                    msg[144] <= hex_char(bw_ss[3:0]);
                    msg[145] <= " ";

                    // BR: BBO FIFO Read count
                    msg[146] <= "B";
                    msg[147] <= "R";
                    msg[148] <= ":";
                    msg[149] <= hex_char(br_ss[15:12]);
                    msg[150] <= hex_char(br_ss[11:8]);
                    msg[151] <= hex_char(br_ss[7:4]);
                    msg[152] <= hex_char(br_ss[3:0]);
                    msg[153] <= " ";

                    // TX: BBO TX sent count
                    msg[154] <= "T";
                    msg[155] <= "X";
                    msg[156] <= ":";
                    msg[157] <= hex_char(tx_ss[15:12]);
                    msg[158] <= hex_char(tx_ss[11:8]);
                    msg[159] <= hex_char(tx_ss[7:4]);
                    msg[160] <= hex_char(tx_ss[3:0]);

                    // RB: Raw first 8 Bytes from MoldUDP64 (before ITCH parser)
                    msg[161] <= " ";
                    msg[162] <= "R";
                    msg[163] <= "B";
                    msg[164] <= ":";
                    msg[165] <= hex_char(rb_ss[63:60]);
                    msg[166] <= hex_char(rb_ss[59:56]);
                    msg[167] <= hex_char(rb_ss[55:52]);
                    msg[168] <= hex_char(rb_ss[51:48]);
                    msg[169] <= hex_char(rb_ss[47:44]);
                    msg[170] <= hex_char(rb_ss[43:40]);
                    msg[171] <= hex_char(rb_ss[39:36]);
                    msg[172] <= hex_char(rb_ss[35:32]);
                    msg[173] <= hex_char(rb_ss[31:28]);
                    msg[174] <= hex_char(rb_ss[27:24]);
                    msg[175] <= hex_char(rb_ss[23:20]);
                    msg[176] <= hex_char(rb_ss[19:16]);
                    msg[177] <= hex_char(rb_ss[15:12]);
                    msg[178] <= hex_char(rb_ss[11:8]);
                    msg[179] <= hex_char(rb_ss[7:4]);
                    msg[180] <= hex_char(rb_ss[3:0]);

                    // SY: Last parsed Symbol from ITCH parser
                    msg[181] <= " ";
                    msg[182] <= "S";
                    msg[183] <= "Y";
                    msg[184] <= ":";
                    msg[185] <= hex_char(sy_ss[63:60]);
                    msg[186] <= hex_char(sy_ss[59:56]);
                    msg[187] <= hex_char(sy_ss[55:52]);
                    msg[188] <= hex_char(sy_ss[51:48]);
                    msg[189] <= hex_char(sy_ss[47:44]);
                    msg[190] <= hex_char(sy_ss[43:40]);
                    msg[191] <= hex_char(sy_ss[39:36]);
                    msg[192] <= hex_char(sy_ss[35:32]);
                    msg[193] <= hex_char(sy_ss[31:28]);
                    msg[194] <= hex_char(sy_ss[27:24]);
                    msg[195] <= hex_char(sy_ss[23:20]);
                    msg[196] <= hex_char(sy_ss[19:16]);
                    msg[197] <= hex_char(sy_ss[15:12]);
                    msg[198] <= hex_char(sy_ss[11:8]);
                    msg[199] <= hex_char(sy_ss[7:4]);
                    msg[200] <= hex_char(sy_ss[3:0]);

                    // CR/LF for proper line termination
                    msg[201] <= 8'h0D;  // CR
                    msg[202] <= 8'h0A;  // LF

                    char_idx <= 8'd0;
                    state <= STATE_SEND;
                end

                STATE_SEND: begin
                    if (!tx_busy && !tx_start) begin
                        if (char_idx < MSG_LEN) begin
                            tx_data <= msg[char_idx];
                            tx_start <= 1'b1;
                            char_idx <= char_idx + 1;
                            state <= STATE_WAIT;
                        end
                        else begin
                            state <= STATE_IDLE;
                        end
                    end
                end

                STATE_WAIT: begin
                    // Wait for current character to start transmitting
                    if (tx_busy) begin
                        state <= STATE_SEND;
                    end
                end

                default:
                    state <= STATE_IDLE;
            endcase
        end
    end

endmodule

`resetall
