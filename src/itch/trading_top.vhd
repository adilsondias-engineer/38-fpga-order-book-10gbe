----------------------------------------------------------------------------------
-- Trading Top-Level Module for Project 38 (10GbE Order Book)
-- Purpose: Integrates NASDAQ ITCH parser, ITCH CDC FIFO, Order Book, BBO CDC FIFO
--          Pure trading logic layer - no board I/O, no network components
--
-- Based on Project 23 architecture: trading_top includes ITCH parser internally
--
-- Clock Domains:
--   - tx_clk (156 MHz): ITCH message input from MoldUDP64, BBO output to UDP TX
--   - sys_clk (200 MHz): Order book processing
--
-- Data Flow:
--   [MoldUDP64] --> [ITCH Parser] --> [ITCH CDC FIFO] --> [Order Book] --> [BBO CDC FIFO] --> [BBO UDP TX]
--     (tx_clk)       (tx_clk)        (tx->sys)          (sys_clk)        (sys->tx)           (tx_clk)
--
-- Latency Measurement (per Project 23):
--   T1: ITCH message arrival (tx_clk domain)
--   T2: ITCH CDC FIFO write (tx_clk domain)
--   T3: BBO CDC FIFO read (tx_clk domain)
--   T4: UDP TX start (tx_clk domain, captured in bbo_udp_tx)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.order_book_pkg.all;
use work.symbol_filter_pkg.all;

entity trading_top is
    Port (
        -- TX clock domain (156 MHz from GTX)
        tx_clk            : in  STD_LOGIC;
        tx_rst            : in  STD_LOGIC;

        -- System clock domain (200 MHz)
        sys_clk           : in  STD_LOGIC;
        sys_rst           : in  STD_LOGIC;

        -- ITCH message stream from MoldUDP64 (tx_clk domain)
        -- This is the raw ITCH message data, not yet parsed
        mold_itch_valid   : in  STD_LOGIC;
        mold_itch_data    : in  STD_LOGIC_VECTOR(7 downto 0);
        mold_itch_start   : in  STD_LOGIC;
        mold_itch_end     : in  STD_LOGIC;

        -- Timestamp counter input (tx_clk domain)
        ts_counter        : in  STD_LOGIC_VECTOR(31 downto 0);

        -- BBO outputs (tx_clk domain, to BBO UDP TX)
        bbo_valid         : out STD_LOGIC;
        bbo_symbol        : out STD_LOGIC_VECTOR(63 downto 0);
        bbo_bid_price     : out STD_LOGIC_VECTOR(31 downto 0);
        bbo_bid_shares    : out STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_price     : out STD_LOGIC_VECTOR(31 downto 0);
        bbo_ask_shares    : out STD_LOGIC_VECTOR(31 downto 0);
        bbo_spread        : out STD_LOGIC_VECTOR(31 downto 0);

        -- Timestamp outputs (tx_clk domain, for BBO UDP TX)
        ts_t1_out         : out STD_LOGIC_VECTOR(31 downto 0);
        ts_t2_out         : out STD_LOGIC_VECTOR(31 downto 0);
        ts_t3_out         : out STD_LOGIC_VECTOR(31 downto 0);

        -- Debug counters (various domains)
        itch_msg_count    : out STD_LOGIC_VECTOR(15 downto 0);
        itch_fifo_wr_count: out STD_LOGIC_VECTOR(15 downto 0);
        itch_fifo_rd_count: out STD_LOGIC_VECTOR(15 downto 0);
        bbo_update_count  : out STD_LOGIC_VECTOR(15 downto 0);
        bbo_fifo_wr_count : out STD_LOGIC_VECTOR(15 downto 0);
        bbo_fifo_rd_count : out STD_LOGIC_VECTOR(15 downto 0);

        -- Last ITCH message fields (for debug, tx_clk domain)
        last_itch_msg_type    : out STD_LOGIC_VECTOR(7 downto 0);
        last_itch_stock_locate: out STD_LOGIC_VECTOR(15 downto 0);
        last_itch_price       : out STD_LOGIC_VECTOR(31 downto 0);

        -- Raw debug bytes (tx_clk domain, for UART debug)
        debug_raw_bytes       : out STD_LOGIC_VECTOR(63 downto 0);
        debug_itch_symbol     : out STD_LOGIC_VECTOR(63 downto 0)
    );
end trading_top;

architecture Behavioral of trading_top is

    ----------------------------------------------------------------------------
    -- NASDAQ ITCH Parser Signals (tx_clk domain)
    ----------------------------------------------------------------------------
    signal itch_msg_valid   : STD_LOGIC;
    signal itch_msg_type    : STD_LOGIC_VECTOR(7 downto 0);
    signal itch_stock_locate: STD_LOGIC_VECTOR(15 downto 0);
    signal itch_order_ref   : STD_LOGIC_VECTOR(63 downto 0);
    signal itch_buy_sell    : STD_LOGIC;
    signal itch_shares      : STD_LOGIC_VECTOR(31 downto 0);
    signal itch_symbol      : STD_LOGIC_VECTOR(63 downto 0);
    signal itch_price       : STD_LOGIC_VECTOR(31 downto 0);
    signal itch_exec_shares : STD_LOGIC_VECTOR(31 downto 0);
    signal itch_cancel_shares: STD_LOGIC_VECTOR(31 downto 0);
    signal itch_new_order_ref: STD_LOGIC_VECTOR(63 downto 0);
    signal itch_new_price   : STD_LOGIC_VECTOR(31 downto 0);
    signal itch_new_shares  : STD_LOGIC_VECTOR(31 downto 0);

    -- Debug counters
    signal itch_count       : unsigned(15 downto 0) := (others => '0');

    -- Last ITCH fields (latched for debug)
    signal last_msg_type    : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal last_stock_locate: STD_LOGIC_VECTOR(15 downto 0) := (others => '0');
    signal last_price       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal last_symbol      : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');

    -- Raw byte capture: first 8 bytes of each ITCH message from MoldUDP64
    signal raw_byte_capture : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal raw_byte_cnt     : unsigned(3 downto 0) := (others => '0');
    signal raw_byte_active  : STD_LOGIC := '0';

    ----------------------------------------------------------------------------
    -- ITCH CDC FIFO Signals (tx_clk -> sys_clk)
    -- Carries ITCH message data + T1 + T2 timestamps + Execute/Cancel/Replace fields
    -- Width: 480 bits = msg_type(8) + symbol(64) + order_ref(64) + buy_sell(1) +
    --                   shares(32) + price(32) + exec_shares(32) + cancel_shares(32) +
    --                   new_order_ref(64) + new_price(32) + new_shares(32) +
    --                   T1(32) + T2(32) + padding(23) = 480
    ----------------------------------------------------------------------------
    constant ITCH_CDC_FIFO_WIDTH : integer := 480;

    -- Timestamp capture (tx_clk domain)
    signal t1_capture       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal t2_capture       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- Write side (tx_clk domain)
    signal itch_cdc_wr_en   : STD_LOGIC := '0';
    signal itch_cdc_wr_data : STD_LOGIC_VECTOR(ITCH_CDC_FIFO_WIDTH-1 downto 0) := (others => '0');
    signal itch_cdc_wr_full : STD_LOGIC;

    -- Read side (sys_clk domain)
    signal itch_cdc_rd_en   : STD_LOGIC := '0';
    signal itch_cdc_rd_data : STD_LOGIC_VECTOR(ITCH_CDC_FIFO_WIDTH-1 downto 0);
    signal itch_cdc_rd_empty: STD_LOGIC;
    signal itch_cdc_rd_prev : STD_LOGIC := '0';
    signal itch_rd_cooldown : unsigned(2 downto 0) := (others => '0');  -- Prevent double-reads

    -- Unpacked ITCH data in sys_clk domain
    signal sys_msg_valid    : STD_LOGIC := '0';
    signal sys_msg_type     : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal sys_symbol       : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal sys_order_ref    : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal sys_buy_sell     : STD_LOGIC := '0';
    signal sys_shares       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal sys_price        : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal sys_exec_shares  : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal sys_cancel_shares: STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal sys_new_order_ref: STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal sys_new_price    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal sys_new_shares   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal sys_t1           : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal sys_t2           : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');


    -- Debug counters
    signal itch_wr_count    : unsigned(15 downto 0) := (others => '0');
    signal itch_rd_count    : unsigned(15 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- Order Book Signals (sys_clk domain)
    ----------------------------------------------------------------------------
    signal ob_bbo_update    : STD_LOGIC;
    signal ob_bbo_symbol    : STD_LOGIC_VECTOR(63 downto 0);
    signal ob_bbo_valid     : STD_LOGIC;
    signal ob_bid_price     : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_bid_shares    : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_ask_price     : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_ask_shares    : STD_LOGIC_VECTOR(31 downto 0);
    signal ob_spread        : STD_LOGIC_VECTOR(31 downto 0);

    -- Debug counter
    signal bbo_upd_count    : unsigned(15 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- BBO CDC FIFO Signals (sys_clk -> tx_clk)
    -- Carries BBO data + T1/T2 timestamps for latency measurement
    -- Width: 320 bits = symbol(64) + bid_price(32) + bid_shares(32) +
    --                   ask_price(32) + ask_shares(32) + spread(32) +
    --                   T1(32) + T2(32) + padding(32) = 320
    ----------------------------------------------------------------------------
    constant BBO_CDC_FIFO_WIDTH : integer := 320;

    -- Write side (sys_clk domain)
    signal bbo_cdc_wr_en    : STD_LOGIC := '0';
    signal bbo_cdc_wr_data  : STD_LOGIC_VECTOR(BBO_CDC_FIFO_WIDTH-1 downto 0) := (others => '0');
    signal bbo_cdc_wr_full  : STD_LOGIC;

    -- Read side (tx_clk domain)
    signal bbo_cdc_rd_en    : STD_LOGIC := '0';
    signal bbo_cdc_rd_data  : STD_LOGIC_VECTOR(BBO_CDC_FIFO_WIDTH-1 downto 0);
    signal bbo_cdc_rd_empty : STD_LOGIC;
    signal bbo_cdc_rd_prev  : STD_LOGIC := '0';
    signal bbo_rd_cooldown  : unsigned(2 downto 0) := (others => '0');  -- Prevent double-reads

    -- T3 capture (tx_clk domain)
    signal t3_capture       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- Debug counters
    signal bbo_wr_count     : unsigned(15 downto 0) := (others => '0');
    signal bbo_rd_count     : unsigned(15 downto 0) := (others => '0');
    
    
    -- Limit fanout on high-fanout signals feeding 8 order book instances
    attribute MAX_FANOUT : integer;
    attribute MAX_FANOUT of sys_exec_shares  : signal is 16;
    attribute MAX_FANOUT of sys_cancel_shares : signal is 16;
    attribute MAX_FANOUT of sys_shares       : signal is 16;
    attribute MAX_FANOUT of sys_price        : signal is 16;
    attribute MAX_FANOUT of sys_order_ref    : signal is 16;
    attribute MAX_FANOUT of sys_msg_type     : signal is 16;
    attribute MAX_FANOUT of sys_msg_valid    : signal is 16;
    attribute MAX_FANOUT of sys_buy_sell     : signal is 16;
    attribute MAX_FANOUT of sys_symbol       : signal is 16;
    attribute MAX_FANOUT of sys_new_order_ref: signal is 16;
    attribute MAX_FANOUT of sys_new_price    : signal is 16;
    attribute MAX_FANOUT of sys_new_shares   : signal is 16;
    attribute MAX_FANOUT of sys_t1           : signal is 16;
    attribute MAX_FANOUT of sys_t2           : signal is 16;
    attribute MAX_FANOUT of itch_cdc_wr_data           : signal is 16;
    attribute MAX_FANOUT of itch_cdc_wr_full           : signal is 16;
    attribute MAX_FANOUT of itch_cdc_wr_en           : signal is 16;
    attribute MAX_FANOUT of itch_cdc_rd_en           : signal is 16;
    attribute MAX_FANOUT of itch_cdc_rd_data           : signal is 16;
    attribute MAX_FANOUT of itch_cdc_rd_empty           : signal is 16;
    attribute MAX_FANOUT of itch_cdc_rd_prev           : signal is 16;
    attribute MAX_FANOUT of itch_rd_cooldown           : signal is 16;
    attribute MAX_FANOUT of bbo_cdc_wr_en           : signal is 16;
    attribute MAX_FANOUT of bbo_cdc_wr_data           : signal is 16;
    attribute MAX_FANOUT of bbo_cdc_wr_full           : signal is 16;
    attribute MAX_FANOUT of bbo_cdc_rd_en           : signal is 16;
    attribute MAX_FANOUT of bbo_cdc_rd_data           : signal is 16;  
    attribute MAX_FANOUT of bbo_cdc_rd_empty           : signal is 16;  
    attribute MAX_FANOUT of bbo_cdc_rd_prev           : signal is 16;  
    attribute MAX_FANOUT of bbo_rd_cooldown           : signal is 16;  
    attribute MAX_FANOUT of bbo_wr_count           : signal is 16;  
    attribute MAX_FANOUT of bbo_rd_count           : signal is 16;    
    


begin


    ----------------------------------------------------------------------------
    -- NASDAQ ITCH Parser (tx_clk domain)
    -- Receives raw ITCH message stream from MoldUDP64 and parses it
    ----------------------------------------------------------------------------
    itch_parser_inst : entity work.nasdaq_itch_parser
        port map (
            clk                 => tx_clk,
            rst                 => tx_rst,
            -- ITCH message stream from MoldUDP64
            itch_msg_valid      => mold_itch_valid,
            itch_msg_data       => mold_itch_data,
            itch_msg_start      => mold_itch_start,
            itch_msg_end        => mold_itch_end,
            -- Parsed message outputs
            msg_valid           => itch_msg_valid,
            msg_type            => itch_msg_type,
            msg_error           => open,
            add_order_valid     => open,
            stock_locate        => itch_stock_locate,
            tracking_number     => open,
            timestamp           => open,
            order_ref           => itch_order_ref,
            buy_sell            => itch_buy_sell,
            shares              => itch_shares,
            stock_symbol        => itch_symbol,
            price               => itch_price,
            order_executed_valid => open,
            exec_shares          => itch_exec_shares,
            match_number         => open,
            order_cancel_valid  => open,
            cancel_shares       => itch_cancel_shares,
            order_delete_valid  => open,
            order_replace_valid => open,
            original_order_ref  => open,
            new_order_ref       => itch_new_order_ref,
            new_shares          => itch_new_shares,
            new_price           => itch_new_price,
            total_messages      => open,
            filtered_messages   => open
        );

    ----------------------------------------------------------------------------
    -- ITCH Parser Message Counter and Debug Capture (tx_clk domain)
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            if tx_rst = '1' then
                itch_count <= (others => '0');
                last_msg_type <= (others => '0');
                last_stock_locate <= (others => '0');
                last_price <= (others => '0');
            elsif itch_msg_valid = '1' then
                itch_count <= itch_count + 1;
                last_msg_type <= itch_msg_type;
                last_stock_locate <= itch_stock_locate;
                last_price <= itch_price;
                last_symbol <= itch_symbol;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Raw Byte Capture (tx_clk domain)
    -- Captures first 8 bytes of each ITCH message from MoldUDP64 output
    -- Byte 0 should be message type (0x41='A', 0x45='E', etc.)
    -- If byte 0 shows UDP header data (e.g. 0xD4), confirms UDP header leak
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            if tx_rst = '1' then
                raw_byte_capture <= (others => '0');
                raw_byte_cnt <= (others => '0');
                raw_byte_active <= '0';
            else
                -- Start capture on message start
                if mold_itch_start = '1' and mold_itch_valid = '1' then
                    -- First byte arrives with start pulse
                    raw_byte_capture(63 downto 56) <= mold_itch_data;
                    raw_byte_cnt <= to_unsigned(1, 4);
                    raw_byte_active <= '1';
                elsif raw_byte_active = '1' and mold_itch_valid = '1' then
                    case to_integer(raw_byte_cnt) is
                        when 1 => raw_byte_capture(55 downto 48) <= mold_itch_data;
                        when 2 => raw_byte_capture(47 downto 40) <= mold_itch_data;
                        when 3 => raw_byte_capture(39 downto 32) <= mold_itch_data;
                        when 4 => raw_byte_capture(31 downto 24) <= mold_itch_data;
                        when 5 => raw_byte_capture(23 downto 16) <= mold_itch_data;
                        when 6 => raw_byte_capture(15 downto 8) <= mold_itch_data;
                        when 7 =>
                            raw_byte_capture(7 downto 0) <= mold_itch_data;
                            raw_byte_active <= '0';
                        when others => null;
                    end case;
                    raw_byte_cnt <= raw_byte_cnt + 1;
                end if;

                -- Stop capture on message end
                if mold_itch_end = '1' then
                    raw_byte_active <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Debug output assignments
    debug_raw_bytes   <= raw_byte_capture;
    debug_itch_symbol <= last_symbol;

    ----------------------------------------------------------------------------
    -- ITCH CDC FIFO Writer (tx_clk domain)
    -- Captures T1 (message arrival) and T2 (FIFO write)
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            if tx_rst = '1' then
                itch_cdc_wr_en <= '0';
                itch_cdc_wr_data <= (others => '0');
                t1_capture <= (others => '0');
                t2_capture <= (others => '0');
                itch_wr_count <= (others => '0');
            else
                itch_cdc_wr_en <= '0';  -- Default: no write

                -- Capture T1 on ITCH message arrival (start of message)
                if mold_itch_start = '1' and mold_itch_valid = '1' then
                    t1_capture <= ts_counter;
                end if;

                -- Write ITCH data to CDC FIFO when message is parsed
                if itch_msg_valid = '1' and itch_cdc_wr_full = '0' then
                    itch_wr_count <= itch_wr_count + 1;

                    -- Capture T2 at FIFO write boundary
                    t2_capture <= ts_counter;

                    -- Pack ITCH data (480 bits)
                    -- [479:472] msg_type (8 bits)
                    itch_cdc_wr_data(479 downto 472) <= itch_msg_type;
                    -- [471:408] symbol (64 bits)
                    itch_cdc_wr_data(471 downto 408) <= itch_symbol;
                    -- [407:344] order_ref (64 bits)
                    itch_cdc_wr_data(407 downto 344) <= itch_order_ref;
                    -- [343] buy_sell (1 bit)
                    itch_cdc_wr_data(343) <= itch_buy_sell;
                    -- [342:311] shares (32 bits)
                    itch_cdc_wr_data(342 downto 311) <= itch_shares;
                    -- [310:279] price (32 bits)
                    itch_cdc_wr_data(310 downto 279) <= itch_price;
                    -- [278:247] exec_shares (32 bits)
                    itch_cdc_wr_data(278 downto 247) <= itch_exec_shares;
                    -- [246:215] cancel_shares (32 bits)
                    itch_cdc_wr_data(246 downto 215) <= itch_cancel_shares;
                    -- [214:151] new_order_ref (64 bits)
                    itch_cdc_wr_data(214 downto 151) <= itch_new_order_ref;
                    -- [150:119] new_price (32 bits)
                    itch_cdc_wr_data(150 downto 119) <= itch_new_price;
                    -- [118:87] new_shares (32 bits)
                    itch_cdc_wr_data(118 downto 87) <= itch_new_shares;
                    -- [86:55] T1 timestamp (32 bits)
                    itch_cdc_wr_data(86 downto 55) <= t1_capture;
                    -- [54:23] T2 timestamp (32 bits)
                    itch_cdc_wr_data(54 downto 23) <= ts_counter;
                    -- [22:0] padding (23 bits)
                    itch_cdc_wr_data(22 downto 0) <= (others => '0');

                    itch_cdc_wr_en <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- ITCH CDC FIFO (tx_clk -> sys_clk)
    -- Hand-coded TDP BRAM FIFO with registered reads and gray-code CDC.
    -- Previously used XPM (Bug 8) but XPM introduces -0.072 hold paths.
    -- async_fifo.vhd has correct TDP template: unconditional registered read.
    -- If Vivado refuses BRAM inference, revert to async_fifo_itch (XPM).
    ----------------------------------------------------------------------------

    itch_cdc_fifo_inst : entity work.async_fifo
        generic map (
            DATA_WIDTH => ITCH_CDC_FIFO_WIDTH,
            FIFO_DEPTH => 256
        )
        port map (
            -- Write side (tx_clk domain)
            wr_clk   => tx_clk,
            wr_rst   => tx_rst,
            wr_en    => itch_cdc_wr_en,
            wr_data  => itch_cdc_wr_data,
            wr_full  => itch_cdc_wr_full,
            -- Read side (sys_clk domain)
            rd_clk   => sys_clk,
            rd_rst   => sys_rst,
            rd_en    => itch_cdc_rd_en,
            rd_data  => itch_cdc_rd_data,
            rd_empty => itch_cdc_rd_empty
        );
   
    ----------------------------------------------------------------------------
    -- ITCH CDC FIFO Reader (sys_clk domain)
    -- Unpacks ITCH data for Order Book
    -- Uses cooldown counter to prevent double-reads due to CDC delay on empty flag
    ----------------------------------------------------------------------------
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if sys_rst = '1' then
                itch_cdc_rd_en <= '0';
                itch_cdc_rd_prev <= '0';
                itch_rd_cooldown <= (others => '0');
                sys_msg_valid <= '0';
                sys_msg_type <= (others => '0');
                sys_symbol <= (others => '0');
                sys_order_ref <= (others => '0');
                sys_buy_sell <= '0';
                sys_shares <= (others => '0');
                sys_price <= (others => '0');
                sys_exec_shares <= (others => '0');
                sys_cancel_shares <= (others => '0');
                sys_new_order_ref <= (others => '0');
                sys_new_price <= (others => '0');
                sys_new_shares <= (others => '0');
                sys_t1 <= (others => '0');
                sys_t2 <= (others => '0');
                itch_rd_count <= (others => '0');
            else
                itch_cdc_rd_en <= '0';  -- Default: no read
                sys_msg_valid <= '0';   -- Default: no valid pulse

                -- Cooldown counter (wait for empty flag CDC to settle)
                if itch_rd_cooldown > 0 then
                    itch_rd_cooldown <= itch_rd_cooldown - 1;
                end if;

                -- Read from FIFO when data available AND cooldown expired
                if itch_cdc_rd_empty = '0' and itch_cdc_rd_prev = '0' and itch_rd_cooldown = 0 then
                    itch_cdc_rd_en <= '1';
                    -- Start cooldown (4 cycles for CDC gray code sync)
                    itch_rd_cooldown <= "100";
                elsif itch_cdc_rd_prev = '1' then
                    itch_rd_count <= itch_rd_count + 1;

                    -- Unpack ITCH data (480-bit layout)
                    sys_msg_type      <= itch_cdc_rd_data(479 downto 472);
                    sys_symbol        <= itch_cdc_rd_data(471 downto 408);
                    sys_order_ref     <= itch_cdc_rd_data(407 downto 344);
                    sys_buy_sell      <= itch_cdc_rd_data(343);
                    sys_shares        <= itch_cdc_rd_data(342 downto 311);
                    sys_price         <= itch_cdc_rd_data(310 downto 279);
                    sys_exec_shares   <= itch_cdc_rd_data(278 downto 247);
                    sys_cancel_shares <= itch_cdc_rd_data(246 downto 215);
                    sys_new_order_ref <= itch_cdc_rd_data(214 downto 151);
                    sys_new_price     <= itch_cdc_rd_data(150 downto 119);
                    sys_new_shares    <= itch_cdc_rd_data(118 downto 87);
                    sys_t1            <= itch_cdc_rd_data(86 downto 55);
                    sys_t2            <= itch_cdc_rd_data(54 downto 23);
                    sys_msg_valid     <= '1';
                end if;

                itch_cdc_rd_prev <= itch_cdc_rd_en;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Multi-Symbol Order Book (sys_clk domain)
    ----------------------------------------------------------------------------
    multi_symbol_order_book_inst : entity work.multi_symbol_order_book
        port map (
            clk             => sys_clk,
            reset           => sys_rst,
            -- ITCH message inputs
            msg_valid       => sys_msg_valid,
            msg_type        => sys_msg_type,
            stock_symbol    => sys_symbol,
            order_ref       => sys_order_ref,
            buy_sell        => sys_buy_sell,
            shares          => sys_shares,
            price           => sys_price,
            -- Execute/Cancel/Replace fields
            exec_shares     => sys_exec_shares,
            cancel_shares   => sys_cancel_shares,
            new_order_ref   => sys_new_order_ref,
            new_price       => sys_new_price,
            new_shares      => sys_new_shares,
            -- BBO outputs
            bbo_update      => ob_bbo_update,
            bbo_symbol      => ob_bbo_symbol,
            bbo_valid       => ob_bbo_valid,
            bid_price       => ob_bid_price,
            bid_shares      => ob_bid_shares,
            ask_price       => ob_ask_price,
            ask_shares      => ob_ask_shares,
            spread          => ob_spread
        );
    ----------------------------------------------------------------------------
    -- BBO CDC FIFO Writer (sys_clk domain)
    -- Packs BBO data + T1/T2 timestamps for transfer to tx_clk domain
    ----------------------------------------------------------------------------
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if sys_rst = '1' then
                bbo_cdc_wr_en <= '0';
                bbo_cdc_wr_data <= (others => '0');
                bbo_upd_count <= (others => '0');
                bbo_wr_count <= (others => '0');
            else
                bbo_cdc_wr_en <= '0';  -- Default: no write

                -- Count all BBO update pulses
                if ob_bbo_update = '1' then
                    bbo_upd_count <= bbo_upd_count + 1;
                end if;

                -- Write BBO update to CDC FIFO
                if ob_bbo_update = '1' and bbo_cdc_wr_full = '0' then
                    bbo_wr_count <= bbo_wr_count + 1;

                    -- Pack BBO data (320 bits)
                    -- [319:256] symbol (64 bits)
                    bbo_cdc_wr_data(319 downto 256) <= ob_bbo_symbol;
                    -- [255:224] bid_price (32 bits)
                    bbo_cdc_wr_data(255 downto 224) <= ob_bid_price;
                    -- [223:192] bid_shares (32 bits)
                    bbo_cdc_wr_data(223 downto 192) <= ob_bid_shares;
                    -- [191:160] ask_price (32 bits)
                    bbo_cdc_wr_data(191 downto 160) <= ob_ask_price;
                    -- [159:128] ask_shares (32 bits)
                    bbo_cdc_wr_data(159 downto 128) <= ob_ask_shares;
                    -- [127:96] spread (32 bits)
                    bbo_cdc_wr_data(127 downto 96) <= ob_spread;
                    -- [95:64] T1 timestamp (32 bits)
                    bbo_cdc_wr_data(95 downto 64) <= sys_t1;
                    -- [63:32] T2 timestamp (32 bits)
                    bbo_cdc_wr_data(63 downto 32) <= sys_t2;
                    -- [31:0] reserved (32 bits)
                    bbo_cdc_wr_data(31 downto 0) <= (others => '0');

                    bbo_cdc_wr_en <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- BBO CDC FIFO (sys_clk -> tx_clk)
    -- Hand-coded TDP BRAM FIFO with registered reads and gray-code CDC.
    ----------------------------------------------------------------------------
    bbo_cdc_fifo_inst : entity work.async_fifo
        generic map (
            DATA_WIDTH => BBO_CDC_FIFO_WIDTH,
            FIFO_DEPTH => 256
        )
        port map (
            -- Write side (sys_clk domain)
            wr_clk   => sys_clk,
            wr_rst   => sys_rst,
            wr_en    => bbo_cdc_wr_en,
            wr_data  => bbo_cdc_wr_data,
            wr_full  => bbo_cdc_wr_full,
            -- Read side (tx_clk domain)
            rd_clk   => tx_clk,
            rd_rst   => tx_rst,
            rd_en    => bbo_cdc_rd_en,
            rd_data  => bbo_cdc_rd_data,
            rd_empty => bbo_cdc_rd_empty
        );

    ----------------------------------------------------------------------------
    -- BBO CDC FIFO Reader (tx_clk domain)
    -- Unpacks BBO data for BBO UDP TX
    -- T3 captured locally at FIFO read boundary
    -- Uses cooldown counter to prevent double-reads due to CDC delay on empty flag
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            if tx_rst = '1' then
                bbo_cdc_rd_en <= '0';
                bbo_cdc_rd_prev <= '0';
                bbo_rd_cooldown <= (others => '0');
                bbo_valid <= '0';
                bbo_symbol <= (others => '0');
                bbo_bid_price <= (others => '0');
                bbo_bid_shares <= (others => '0');
                bbo_ask_price <= (others => '0');
                bbo_ask_shares <= (others => '0');
                bbo_spread <= (others => '0');
                ts_t1_out <= (others => '0');
                ts_t2_out <= (others => '0');
                ts_t3_out <= (others => '0');
                t3_capture <= (others => '0');
                bbo_rd_count <= (others => '0');
            else
                bbo_cdc_rd_en <= '0';  -- Default: no read
                bbo_valid <= '0';      -- Default: no valid pulse

                -- Cooldown counter (wait for empty flag CDC to settle)
                if bbo_rd_cooldown > 0 then
                    bbo_rd_cooldown <= bbo_rd_cooldown - 1;
                end if;

                -- Read from FIFO when data available AND cooldown expired
                if bbo_cdc_rd_empty = '0' and bbo_cdc_rd_prev = '0' and bbo_rd_cooldown = 0 then
                    bbo_cdc_rd_en <= '1';
                    -- Capture T3 at FIFO read boundary
                    t3_capture <= ts_counter;
                    -- Start cooldown (4 cycles for CDC gray code sync)
                    bbo_rd_cooldown <= "100";
                elsif bbo_cdc_rd_prev = '1' then
                    bbo_rd_count <= bbo_rd_count + 1;

                    -- Unpack BBO data (320-bit layout)
                    bbo_symbol     <= bbo_cdc_rd_data(319 downto 256);
                    bbo_bid_price  <= bbo_cdc_rd_data(255 downto 224);
                    bbo_bid_shares <= bbo_cdc_rd_data(223 downto 192);
                    bbo_ask_price  <= bbo_cdc_rd_data(191 downto 160);
                    bbo_ask_shares <= bbo_cdc_rd_data(159 downto 128);
                    bbo_spread     <= bbo_cdc_rd_data(127 downto 96);
                    -- T1 and T2 passed through from rx_clk domain
                    ts_t1_out      <= bbo_cdc_rd_data(95 downto 64);
                    ts_t2_out      <= bbo_cdc_rd_data(63 downto 32);
                    -- T3 captured locally
                    ts_t3_out      <= t3_capture;
                    bbo_valid      <= '1';
                end if;

                bbo_cdc_rd_prev <= bbo_cdc_rd_en;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Debug Counter Outputs
    ----------------------------------------------------------------------------
    itch_msg_count     <= std_logic_vector(itch_count);
    itch_fifo_wr_count <= std_logic_vector(itch_wr_count);
    itch_fifo_rd_count <= std_logic_vector(itch_rd_count);
    bbo_update_count   <= std_logic_vector(bbo_upd_count);
    bbo_fifo_wr_count  <= std_logic_vector(bbo_wr_count);
    bbo_fifo_rd_count  <= std_logic_vector(bbo_rd_count);

    -- Last ITCH message debug outputs
    last_itch_msg_type     <= last_msg_type;
    last_itch_stock_locate <= last_stock_locate;
    last_itch_price        <= last_price;

end Behavioral;
