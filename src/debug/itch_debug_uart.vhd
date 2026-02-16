--------------------------------------------------------------------------------
-- Module: itch_debug_uart
-- Description: ITCH-focused debug UART reporter for Project 38
--
-- Replaces gtx_debug_reporter with a stripped-down ITCH-focused debug output.
-- Network is confirmed working, so GTX status fields are reduced to Q/BL only.
--
-- Output Format (every REPORT_MS milliseconds):
--   Q:x BL:x FC:xxxx MC:xxxx MT:c SL:xxxx P$:xxxxxxxx IW:xxxx IR:xxxx
--   BU:xxxx TX:xxxx RB:xxxxxxxxxxxxxxxx SY:xxxxxxxxxxxxxxxx\r\n
--
-- Fields:
--   Q  = QPLL lock
--   BL = PCS block lock
--   FC = Frame count (MAC frames received)
--   MC = MoldUDP64 messages extracted
--   MT = Last ITCH message type (ASCII char)
--   SL = Last stock locate (hex)
--   P$ = Last price (hex, 32-bit fixed-point)
--   IW = ITCH FIFO write count
--   IR = ITCH FIFO read count
--   BU = BBO update count
--   TX = BBO TX count
--   RB = Raw first 8 bytes from MoldUDP64 output (before ITCH parser)
--   SY = Last parsed stock symbol from ITCH parser (8 ASCII chars as hex)
--   MB = First 8 bytes entering MoldUDP64 handler (after UDP header strip)
--
-- Self-contained: includes inline UART TX (8N1), no external dependencies.
--
-- ==============================================================================
-- Copyright 2026 Adilson Dias
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Author: Adilson Dias
-- GitHub: https://github.com/adilsondias-engineer/fpga-trading-systems
-- Date: February 2026
-- ==============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity itch_debug_uart is
    generic (
        CLK_FREQ  : integer := 200_000_000;
        BAUD_RATE : integer := 115200;
        REPORT_MS : integer := 500
    );
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;

        -- Key status (minimal)
        qpll_lock         : in  std_logic;
        block_lock        : in  std_logic;

        -- Parser counters
        frame_count       : in  std_logic_vector(31 downto 0);
        mold_msg_count    : in  std_logic_vector(31 downto 0);

        -- ITCH parsed fields (last message)
        itch_msg_type     : in  std_logic_vector(7 downto 0);
        itch_stock_locate : in  std_logic_vector(15 downto 0);
        itch_price        : in  std_logic_vector(31 downto 0);

        -- Raw debug bytes
        debug_raw_bytes   : in  std_logic_vector(63 downto 0);
        debug_itch_symbol : in  std_logic_vector(63 downto 0);
        debug_mold_input  : in  std_logic_vector(63 downto 0);

        -- BBO path counters
        itch_fifo_wr_count : in  std_logic_vector(15 downto 0);
        itch_fifo_rd_count : in  std_logic_vector(15 downto 0);
        bbo_update_count   : in  std_logic_vector(15 downto 0);
        bbo_tx_count       : in  std_logic_vector(15 downto 0);

        -- UART output
        uart_tx           : out std_logic
    );
end itch_debug_uart;

architecture rtl of itch_debug_uart is

    ----------------------------------------------------------------------------
    -- UART TX parameters
    ----------------------------------------------------------------------------
    constant BIT_PERIOD : integer := CLK_FREQ / BAUD_RATE;

    -- UART TX state machine
    type uart_state_type is (UART_IDLE, UART_START, UART_DATA, UART_STOP);
    signal uart_state  : uart_state_type := UART_IDLE;
    signal uart_clk    : integer range 0 to BIT_PERIOD - 1 := 0;
    signal uart_bit    : integer range 0 to 7 := 0;
    signal uart_shift  : std_logic_vector(7 downto 0) := (others => '1');
    signal uart_tx_reg : std_logic := '1';
    signal tx_busy     : std_logic := '0';
    signal tx_start    : std_logic := '0';
    signal tx_data     : std_logic_vector(7 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- Reporter state machine
    ----------------------------------------------------------------------------
    constant REPORT_CYCLES : integer := (CLK_FREQ / 1000) * REPORT_MS;

    type state_type is (S_IDLE, S_BUILD, S_SEND, S_WAIT);
    signal state    : state_type := S_IDLE;
    signal timer    : unsigned(31 downto 0) := (others => '0');
    signal char_idx : integer range 0 to 159 := 0;

    -- Message buffer
    -- "Q:x BL:x FC:xxxx MC:xxxx MT:c SL:xxxx P$:xxxxxxxx IW:xxxx IR:xxxx BU:xxxx TX:xxxx RB:xxxxxxxxxxxxxxxx SY:xxxxxxxxxxxxxxxx MB:xxxxxxxxxxxxxxxx\r\n"
    constant MSG_LEN : integer := 143;
    type msg_array_type is array (0 to MSG_LEN - 1) of std_logic_vector(7 downto 0);
    signal msg : msg_array_type := (others => (others => '0'));

    ----------------------------------------------------------------------------
    -- Double-registered CDC sampling
    ----------------------------------------------------------------------------
    signal fc_s, fc_ss : std_logic_vector(31 downto 0) := (others => '0');
    signal mc_s, mc_ss : std_logic_vector(31 downto 0) := (others => '0');
    signal mt_s, mt_ss : std_logic_vector(7 downto 0)  := (others => '0');
    signal sl_s, sl_ss : std_logic_vector(15 downto 0) := (others => '0');
    signal px_s, px_ss : std_logic_vector(31 downto 0) := (others => '0');
    signal rb_s, rb_ss : std_logic_vector(63 downto 0) := (others => '0');
    signal sy_s, sy_ss : std_logic_vector(63 downto 0) := (others => '0');
    signal mb_s, mb_ss : std_logic_vector(63 downto 0) := (others => '0');
    signal iw_s, iw_ss : std_logic_vector(15 downto 0) := (others => '0');
    signal ir_s, ir_ss : std_logic_vector(15 downto 0) := (others => '0');
    signal bu_s, bu_ss : std_logic_vector(15 downto 0) := (others => '0');
    signal tc_s, tc_ss : std_logic_vector(15 downto 0) := (others => '0');
    signal ql_s, ql_ss : std_logic := '0';
    signal bl_s, bl_ss : std_logic := '0';

    -- Convert nibble to hex ASCII character
    function hex(nibble : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        if unsigned(nibble) < 10 then
            return std_logic_vector(to_unsigned(48 + to_integer(unsigned(nibble)), 8));
        else
            return std_logic_vector(to_unsigned(55 + to_integer(unsigned(nibble)), 8));
        end if;
    end function;

begin

    uart_tx <= uart_tx_reg;

    ----------------------------------------------------------------------------
    -- UART TX (8N1, inline)
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                uart_state <= UART_IDLE;
                uart_tx_reg <= '1';
                tx_busy <= '0';
            else
                case uart_state is
                    when UART_IDLE =>
                        uart_tx_reg <= '1';
                        tx_busy <= '0';
                        if tx_start = '1' then
                            uart_shift <= tx_data;
                            uart_clk <= 0;
                            uart_state <= UART_START;
                            tx_busy <= '1';
                        end if;

                    when UART_START =>
                        uart_tx_reg <= '0';  -- Start bit
                        if uart_clk >= BIT_PERIOD - 1 then
                            uart_clk <= 0;
                            uart_bit <= 0;
                            uart_state <= UART_DATA;
                        else
                            uart_clk <= uart_clk + 1;
                        end if;

                    when UART_DATA =>
                        uart_tx_reg <= uart_shift(uart_bit);  -- LSB first
                        if uart_clk >= BIT_PERIOD - 1 then
                            uart_clk <= 0;
                            if uart_bit >= 7 then
                                uart_state <= UART_STOP;
                            else
                                uart_bit <= uart_bit + 1;
                            end if;
                        else
                            uart_clk <= uart_clk + 1;
                        end if;

                    when UART_STOP =>
                        uart_tx_reg <= '1';  -- Stop bit
                        if uart_clk >= BIT_PERIOD - 1 then
                            uart_state <= UART_IDLE;
                        else
                            uart_clk <= uart_clk + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- CDC sampling (double-register all inputs)
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            -- Stage 1
            fc_s <= frame_count;      mc_s <= mold_msg_count;
            mt_s <= itch_msg_type;    sl_s <= itch_stock_locate;
            px_s <= itch_price;       rb_s <= debug_raw_bytes;
            sy_s <= debug_itch_symbol; mb_s <= debug_mold_input;
            iw_s <= itch_fifo_wr_count;  ir_s <= itch_fifo_rd_count;
            bu_s <= bbo_update_count;    tc_s <= bbo_tx_count;
            ql_s <= qpll_lock;           bl_s <= block_lock;
            -- Stage 2
            fc_ss <= fc_s;      mc_ss <= mc_s;
            mt_ss <= mt_s;      sl_ss <= sl_s;
            px_ss <= px_s;      rb_ss <= rb_s;
            sy_ss <= sy_s;      mb_ss <= mb_s;
            iw_ss <= iw_s;      ir_ss <= ir_s;
            bu_ss <= bu_s;      tc_ss <= tc_s;
            ql_ss <= ql_s;      bl_ss <= bl_s;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Main reporter state machine
    ----------------------------------------------------------------------------
    process(clk)
        variable i : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= S_IDLE;
                timer <= (others => '0');
                char_idx <= 0;
                tx_start <= '0';
            else
                case state is
                    when S_IDLE =>
                        tx_start <= '0';
                        if timer >= to_unsigned(REPORT_CYCLES, 32) then
                            timer <= (others => '0');
                            state <= S_BUILD;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_BUILD =>
                        -- Build entire message in one cycle
                        i := 0;

                        -- "Q:x "
                        msg(i) <= x"51"; i := i + 1;  -- 'Q'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        if ql_ss = '1' then msg(i) <= x"31"; else msg(i) <= x"30"; end if;
                        i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "BL:x "
                        msg(i) <= x"42"; i := i + 1;  -- 'B'
                        msg(i) <= x"4C"; i := i + 1;  -- 'L'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        if bl_ss = '1' then msg(i) <= x"31"; else msg(i) <= x"30"; end if;
                        i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "FC:xxxx " (frame count, low 16 bits)
                        msg(i) <= x"46"; i := i + 1;  -- 'F'
                        msg(i) <= x"43"; i := i + 1;  -- 'C'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        msg(i) <= hex(fc_ss(15 downto 12)); i := i + 1;
                        msg(i) <= hex(fc_ss(11 downto 8));  i := i + 1;
                        msg(i) <= hex(fc_ss(7 downto 4));   i := i + 1;
                        msg(i) <= hex(fc_ss(3 downto 0));   i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "MC:xxxx " (mold msg extracted, low 16 bits)
                        msg(i) <= x"4D"; i := i + 1;  -- 'M'
                        msg(i) <= x"43"; i := i + 1;  -- 'C'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        msg(i) <= hex(mc_ss(15 downto 12)); i := i + 1;
                        msg(i) <= hex(mc_ss(11 downto 8));  i := i + 1;
                        msg(i) <= hex(mc_ss(7 downto 4));   i := i + 1;
                        msg(i) <= hex(mc_ss(3 downto 0));   i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "MT:c " (message type, raw ASCII)
                        msg(i) <= x"4D"; i := i + 1;  -- 'M'
                        msg(i) <= x"54"; i := i + 1;  -- 'T'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        msg(i) <= mt_ss;  i := i + 1;  -- raw ASCII char
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "SL:xxxx " (stock locate)
                        msg(i) <= x"53"; i := i + 1;  -- 'S'
                        msg(i) <= x"4C"; i := i + 1;  -- 'L'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        msg(i) <= hex(sl_ss(15 downto 12)); i := i + 1;
                        msg(i) <= hex(sl_ss(11 downto 8));  i := i + 1;
                        msg(i) <= hex(sl_ss(7 downto 4));   i := i + 1;
                        msg(i) <= hex(sl_ss(3 downto 0));   i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "P$:xxxxxxxx " (price, 32-bit)
                        msg(i) <= x"50"; i := i + 1;  -- 'P'
                        msg(i) <= x"24"; i := i + 1;  -- '$'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        msg(i) <= hex(px_ss(31 downto 28)); i := i + 1;
                        msg(i) <= hex(px_ss(27 downto 24)); i := i + 1;
                        msg(i) <= hex(px_ss(23 downto 20)); i := i + 1;
                        msg(i) <= hex(px_ss(19 downto 16)); i := i + 1;
                        msg(i) <= hex(px_ss(15 downto 12)); i := i + 1;
                        msg(i) <= hex(px_ss(11 downto 8));  i := i + 1;
                        msg(i) <= hex(px_ss(7 downto 4));   i := i + 1;
                        msg(i) <= hex(px_ss(3 downto 0));   i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "IW:xxxx " (ITCH FIFO write count)
                        msg(i) <= x"49"; i := i + 1;  -- 'I'
                        msg(i) <= x"57"; i := i + 1;  -- 'W'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        msg(i) <= hex(iw_ss(15 downto 12)); i := i + 1;
                        msg(i) <= hex(iw_ss(11 downto 8));  i := i + 1;
                        msg(i) <= hex(iw_ss(7 downto 4));   i := i + 1;
                        msg(i) <= hex(iw_ss(3 downto 0));   i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "IR:xxxx " (ITCH FIFO read count)
                        msg(i) <= x"49"; i := i + 1;  -- 'I'
                        msg(i) <= x"52"; i := i + 1;  -- 'R'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        msg(i) <= hex(ir_ss(15 downto 12)); i := i + 1;
                        msg(i) <= hex(ir_ss(11 downto 8));  i := i + 1;
                        msg(i) <= hex(ir_ss(7 downto 4));   i := i + 1;
                        msg(i) <= hex(ir_ss(3 downto 0));   i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "BU:xxxx " (BBO update count)
                        msg(i) <= x"42"; i := i + 1;  -- 'B'
                        msg(i) <= x"55"; i := i + 1;  -- 'U'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        msg(i) <= hex(bu_ss(15 downto 12)); i := i + 1;
                        msg(i) <= hex(bu_ss(11 downto 8));  i := i + 1;
                        msg(i) <= hex(bu_ss(7 downto 4));   i := i + 1;
                        msg(i) <= hex(bu_ss(3 downto 0));   i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "TX:xxxx " (BBO TX count)
                        msg(i) <= x"54"; i := i + 1;  -- 'T'
                        msg(i) <= x"58"; i := i + 1;  -- 'X'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        msg(i) <= hex(tc_ss(15 downto 12)); i := i + 1;
                        msg(i) <= hex(tc_ss(11 downto 8));  i := i + 1;
                        msg(i) <= hex(tc_ss(7 downto 4));   i := i + 1;
                        msg(i) <= hex(tc_ss(3 downto 0));   i := i + 1;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "RB:xxxxxxxxxxxxxxxx " (raw first 8 bytes, 16 hex chars)
                        msg(i) <= x"52"; i := i + 1;  -- 'R'
                        msg(i) <= x"42"; i := i + 1;  -- 'B'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        for j in 15 downto 0 loop
                            msg(i) <= hex(rb_ss(j*4+3 downto j*4));
                            i := i + 1;
                        end loop;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "SY:xxxxxxxxxxxxxxxx " (parsed symbol, 16 hex chars)
                        msg(i) <= x"53"; i := i + 1;  -- 'S'
                        msg(i) <= x"59"; i := i + 1;  -- 'Y'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        for j in 15 downto 0 loop
                            msg(i) <= hex(sy_ss(j*4+3 downto j*4));
                            i := i + 1;
                        end loop;
                        msg(i) <= x"20"; i := i + 1;  -- ' '

                        -- "MB:xxxxxxxxxxxxxxxx" (MoldUDP64 input first 8 bytes, 16 hex chars)
                        msg(i) <= x"4D"; i := i + 1;  -- 'M'
                        msg(i) <= x"42"; i := i + 1;  -- 'B'
                        msg(i) <= x"3A"; i := i + 1;  -- ':'
                        for j in 15 downto 0 loop
                            msg(i) <= hex(mb_ss(j*4+3 downto j*4));
                            i := i + 1;
                        end loop;

                        -- "\r\n"
                        msg(i) <= x"0D"; i := i + 1;  -- CR
                        msg(i) <= x"0A";               -- LF (index 142)

                        char_idx <= 0;
                        state <= S_SEND;

                    when S_SEND =>
                        if tx_busy = '0' then
                            tx_data <= msg(char_idx);
                            tx_start <= '1';
                            state <= S_WAIT;
                        else
                            tx_start <= '0';
                        end if;

                    when S_WAIT =>
                        tx_start <= '0';
                        if tx_busy = '0' and tx_start = '0' then
                            -- UART finished sending current byte
                            if char_idx >= MSG_LEN - 1 then
                                -- All bytes sent
                                state <= S_IDLE;
                            else
                                char_idx <= char_idx + 1;
                                state <= S_SEND;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end rtl;
