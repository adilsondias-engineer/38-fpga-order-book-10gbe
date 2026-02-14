--------------------------------------------------------------------------------
-- Module: order_book_10gbe_top
-- Description: Top-level integration for Project 38 Order Book 10GbE
--
-- This is the INTEGRATION layer - pure module instantiation, minimal logic.
-- Following Project 23 architecture: each layer has its own top module.
--
-- Layer separation:
--   - network_top: 10GbE network (GTX, PCS, MAC, MoldUDP64)
--   - trading_top: Trading logic (ITCH parser, CDC FIFOs, Order Book)
--   - bbo_udp_tx: BBO packet transmission
--   - latency_calculator: Latency measurement
--   - gtx_debug_reporter: UART debug output
--
-- Clock Domains:
--   - sys_clk: 200 MHz (board oscillator) - Order Book, debug
--   - tx_clk: 156.25 MHz (GTX user clock) - Network, trading IO
--
-- ==============================================================================
-- Copyright 2026 Adilson Dias
-- Licensed under the Apache License, Version 2.0
-- ==============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VCOMPONENTS.ALL;

library work;
use work.order_book_pkg.all;

entity order_book_10gbe_top is
    generic (
        -- Network configuration
        SRC_MAC         : std_logic_vector(47 downto 0) := x"000A3501FEC0";
        DST_MAC         : std_logic_vector(47 downto 0) := x"FFFFFFFFFFFF";
        SRC_IP          : std_logic_vector(31 downto 0) := x"C0A800D7";  -- 192.168.0.215
        DST_IP          : std_logic_vector(31 downto 0) := x"C0A80090";  -- 192.168.0.144
        BBO_UDP_PORT    : std_logic_vector(15 downto 0) := x"1388"       -- 5000
    );
    port (
        -- System clock (200 MHz differential from on-board oscillator)
        sys_clk_p           : in  std_logic;
        sys_clk_n           : in  std_logic;
        sys_rst_n           : in  std_logic;  -- Active-low reset

        -- 10GbE SFP+ interface
        sfp_refclk_p        : in  std_logic;  -- 156.25 MHz reference
        sfp_refclk_n        : in  std_logic;
        sfp_rx_p            : in  std_logic;
        sfp_rx_n            : in  std_logic;
        sfp_tx_p            : out std_logic;
        sfp_tx_n            : out std_logic;
        sfp_tx_disable      : out std_logic;

        -- Status LEDs
        led_qpll_lock       : out std_logic;
        led_gtx_ready       : out std_logic;
        led_pcs_lock        : out std_logic;
        led_bbo_activity    : out std_logic;

        -- Debug UART (115200 baud)
        uart_tx             : out std_logic;

        -- Fan control
        fan_pwm             : out std_logic
    );
end order_book_10gbe_top;

architecture rtl of order_book_10gbe_top is

    ----------------------------------------------------------------------------
    -- Clock and Reset Signals
    ----------------------------------------------------------------------------
    signal sys_clk          : std_logic;
    signal sys_rst          : std_logic;
    signal tx_clk           : std_logic;
    signal tx_rst           : std_logic;

    ----------------------------------------------------------------------------
    -- Network Layer Signals
    ----------------------------------------------------------------------------
    signal mold_itch_valid  : std_logic;
    signal mold_itch_data   : std_logic_vector(7 downto 0);
    signal mold_itch_start  : std_logic;
    signal mold_itch_end    : std_logic;
    signal link_init_done   : std_logic;

    -- PHY status
    signal qpll_lock        : std_logic;
    signal gtx_ready        : std_logic;
    signal pcs_block_lock   : std_logic;
    signal pcs_hi_ber       : std_logic;

    -- Debug counters from network
    signal mac_frame_count  : std_logic_vector(31 downto 0);
    signal mac_start_detect : std_logic_vector(31 downto 0);
    signal mold_packet_count: std_logic_vector(31 downto 0);
    signal mold_msg_extracted: std_logic_vector(31 downto 0);

    -- GTX debug signals
    signal debug_por_done       : std_logic;
    signal debug_qpll_reset     : std_logic;
    signal debug_gtx_reset      : std_logic;
    signal debug_tx_userrdy     : std_logic;
    signal debug_rx_userrdy     : std_logic;
    signal debug_refclk_present : std_logic;
    signal debug_rx_cdrlock     : std_logic;
    signal debug_rx_elecidle    : std_logic;
    signal debug_pcs_block_state: std_logic_vector(2 downto 0);

    ----------------------------------------------------------------------------
    -- Trading Layer Signals
    ----------------------------------------------------------------------------
    signal trading_bbo_valid    : std_logic;
    signal trading_bbo_symbol   : std_logic_vector(63 downto 0);
    signal trading_bid_price    : std_logic_vector(31 downto 0);
    signal trading_bid_shares   : std_logic_vector(31 downto 0);
    signal trading_ask_price    : std_logic_vector(31 downto 0);
    signal trading_ask_shares   : std_logic_vector(31 downto 0);
    signal trading_spread       : std_logic_vector(31 downto 0);
    signal trading_ts_t1        : std_logic_vector(31 downto 0);
    signal trading_ts_t2        : std_logic_vector(31 downto 0);
    signal trading_ts_t3        : std_logic_vector(31 downto 0);

    -- Debug counters from trading
    signal itch_msg_count       : std_logic_vector(15 downto 0);
    signal itch_fifo_wr_count   : std_logic_vector(15 downto 0);
    signal itch_fifo_rd_count   : std_logic_vector(15 downto 0);
    signal bbo_update_count     : std_logic_vector(15 downto 0);
    signal bbo_fifo_wr_count    : std_logic_vector(15 downto 0);
    signal bbo_fifo_rd_count    : std_logic_vector(15 downto 0);
    signal last_itch_msg_type   : std_logic_vector(7 downto 0);
    signal last_itch_stock_locate: std_logic_vector(15 downto 0);
    signal last_itch_price      : std_logic_vector(31 downto 0);

    ----------------------------------------------------------------------------
    -- BBO TX Signals
    ----------------------------------------------------------------------------
    signal bbo_txd          : std_logic_vector(63 downto 0);
    signal bbo_txc          : std_logic_vector(7 downto 0);
    signal tx_ts_t4         : std_logic_vector(31 downto 0);
    signal tx_ts_t4_valid   : std_logic;
    signal tx_pkt_count     : std_logic_vector(31 downto 0);
    signal tx_busy          : std_logic;

    ----------------------------------------------------------------------------
    -- Latency Signals
    ----------------------------------------------------------------------------
    signal last_latency_ns  : std_logic_vector(31 downto 0);
    signal max_latency_ns   : std_logic_vector(31 downto 0);
    signal min_latency_ns   : std_logic_vector(31 downto 0);

    ----------------------------------------------------------------------------
    -- Timestamp Counter (tx_clk domain)
    ----------------------------------------------------------------------------
    signal tx_ts_counter    : unsigned(31 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- Heartbeat (for debug reporter)
    ----------------------------------------------------------------------------
    signal tx_clk_counter   : unsigned(27 downto 0) := (others => '0');
    signal tx_clk_heartbeat : std_logic := '0';

begin

    ----------------------------------------------------------------------------
    -- System Clock Buffer (200 MHz)
    ----------------------------------------------------------------------------
    sys_clk_ibuf : IBUFDS
        generic map (
            DIFF_TERM    => FALSE,
            IBUF_LOW_PWR => FALSE,
            IOSTANDARD   => "DIFF_SSTL15"
        )
        port map (
            I  => sys_clk_p,
            IB => sys_clk_n,
            O  => sys_clk
        );

    sys_rst <= not sys_rst_n;

    -- Board control
    sfp_tx_disable <= '0';
    fan_pwm <= '1';

    ----------------------------------------------------------------------------
    -- Status LEDs
    ----------------------------------------------------------------------------
    led_qpll_lock    <= qpll_lock;
    led_gtx_ready    <= gtx_ready;
    led_pcs_lock     <= pcs_block_lock;
    led_bbo_activity <= tx_clk_heartbeat;

    ----------------------------------------------------------------------------
    -- Timestamp Counter (tx_clk domain)
    -- Simple counter for latency measurement
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            if tx_rst = '1' then
                tx_ts_counter <= (others => '0');
            else
                tx_ts_counter <= tx_ts_counter + 1;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- TX Clock Heartbeat (for debug)
    ----------------------------------------------------------------------------
    process(tx_clk)
    begin
        if rising_edge(tx_clk) then
            if tx_rst = '1' then
                tx_clk_counter <= (others => '0');
                tx_clk_heartbeat <= '0';
            else
                tx_clk_counter <= tx_clk_counter + 1;
                if tx_clk_counter(27) = '1' and tx_clk_counter(26 downto 0) = 0 then
                    tx_clk_heartbeat <= not tx_clk_heartbeat;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Network Top (10GbE layer: GTX, PCS, MAC, MoldUDP64)
    ----------------------------------------------------------------------------
    network_inst : entity work.network_top
        generic map (
            SIM_MODE    => false
        )
        port map (
            -- System clock
            sys_clk             => sys_clk,
            sys_rst_n           => sys_rst_n,
            -- SFP+ interface
            sfp_refclk_p        => sfp_refclk_p,
            sfp_refclk_n        => sfp_refclk_n,
            sfp_rx_p            => sfp_rx_p,
            sfp_rx_n            => sfp_rx_n,
            sfp_tx_p            => sfp_tx_p,
            sfp_tx_n            => sfp_tx_n,
            -- TX clock output
            tx_clk              => tx_clk,
            tx_rst              => tx_rst,
            -- ITCH message stream output
            mold_itch_valid     => mold_itch_valid,
            mold_itch_data      => mold_itch_data,
            mold_itch_start     => mold_itch_start,
            mold_itch_end       => mold_itch_end,
            -- BBO TX input
            bbo_txd             => bbo_txd,
            bbo_txc             => bbo_txc,
            -- Link status
            link_init_done      => link_init_done,
            -- PHY status
            qpll_lock           => qpll_lock,
            gtx_ready           => gtx_ready,
            pcs_block_lock      => pcs_block_lock,
            pcs_hi_ber          => pcs_hi_ber,
            -- Debug counters
            mac_frame_count     => mac_frame_count,
            mac_start_detect    => mac_start_detect,
            mold_packet_count   => mold_packet_count,
            mold_msg_extracted  => mold_msg_extracted,
            -- GTX debug
            debug_por_done      => debug_por_done,
            debug_qpll_reset    => debug_qpll_reset,
            debug_gtx_reset     => debug_gtx_reset,
            debug_tx_userrdy    => debug_tx_userrdy,
            debug_rx_userrdy    => debug_rx_userrdy,
            debug_refclk_present=> debug_refclk_present,
            debug_rx_cdrlock    => debug_rx_cdrlock,
            debug_rx_elecidle   => debug_rx_elecidle,
            debug_pcs_block_state => debug_pcs_block_state
        );

    ----------------------------------------------------------------------------
    -- Trading Top (ITCH parser, CDC FIFOs, Order Book)
    ----------------------------------------------------------------------------
    trading_inst : entity work.trading_top
        port map (
            -- TX clock domain
            tx_clk            => tx_clk,
            tx_rst            => tx_rst,
            -- System clock domain
            sys_clk           => sys_clk,
            sys_rst           => sys_rst,
            -- ITCH message stream from network
            mold_itch_valid   => mold_itch_valid,
            mold_itch_data    => mold_itch_data,
            mold_itch_start   => mold_itch_start,
            mold_itch_end     => mold_itch_end,
            -- Timestamp counter
            ts_counter        => std_logic_vector(tx_ts_counter),
            -- BBO outputs
            bbo_valid         => trading_bbo_valid,
            bbo_symbol        => trading_bbo_symbol,
            bbo_bid_price     => trading_bid_price,
            bbo_bid_shares    => trading_bid_shares,
            bbo_ask_price     => trading_ask_price,
            bbo_ask_shares    => trading_ask_shares,
            bbo_spread        => trading_spread,
            -- Timestamp outputs
            ts_t1_out         => trading_ts_t1,
            ts_t2_out         => trading_ts_t2,
            ts_t3_out         => trading_ts_t3,
            -- Debug counters
            itch_msg_count    => itch_msg_count,
            itch_fifo_wr_count=> itch_fifo_wr_count,
            itch_fifo_rd_count=> itch_fifo_rd_count,
            bbo_update_count  => bbo_update_count,
            bbo_fifo_wr_count => bbo_fifo_wr_count,
            bbo_fifo_rd_count => bbo_fifo_rd_count,
            -- Last ITCH message debug
            last_itch_msg_type    => last_itch_msg_type,
            last_itch_stock_locate=> last_itch_stock_locate,
            last_itch_price       => last_itch_price
        );

    ----------------------------------------------------------------------------
    -- BBO UDP TX
    ----------------------------------------------------------------------------
    bbo_tx_inst : entity work.bbo_udp_tx
        generic map (
            SRC_MAC     => SRC_MAC,
            DST_MAC     => DST_MAC,
            SRC_IP      => SRC_IP,
            DST_IP      => DST_IP,
            SRC_PORT    => x"3039",      -- 12345
            DST_PORT    => BBO_UDP_PORT,
            TEST_MODE   => false         -- Normal mode: triggered by real BBO updates
        )
        port map (
            clk             => tx_clk,
            rst             => tx_rst,
            bbo_valid       => trading_bbo_valid,
            bbo_symbol      => trading_bbo_symbol,
            bbo_bid_price   => trading_bid_price,
            bbo_bid_shares  => trading_bid_shares,
            bbo_ask_price   => trading_ask_price,
            bbo_ask_shares  => trading_ask_shares,
            bbo_spread      => trading_spread,
            ts_t1           => trading_ts_t1,
            ts_t2           => trading_ts_t2,
            ts_t3           => trading_ts_t3,
            xgmii_txd       => bbo_txd,
            xgmii_txc       => bbo_txc,
            ts_t4_capture   => tx_ts_t4,
            ts_t4_valid     => tx_ts_t4_valid,
            tx_count        => tx_pkt_count,
            tx_busy         => tx_busy
        );

    ----------------------------------------------------------------------------
    -- Latency Calculator
    ----------------------------------------------------------------------------
    latency_inst : entity work.latency_calculator
        generic map (
            NS_PER_CYCLE => 6  -- 156.25 MHz = 6.4 ns
        )
        port map (
            clk             => tx_clk,
            rst             => tx_rst,
            ts_valid        => tx_ts_t4_valid,
            ts_t1           => trading_ts_t1,
            ts_t2           => trading_ts_t2,
            ts_t3           => trading_ts_t3,
            ts_t4           => tx_ts_t4,
            stats_reset     => '0',
            last_latency_ns => last_latency_ns,
            max_latency_ns  => max_latency_ns,
            min_latency_ns  => min_latency_ns,
            latency_a_ns    => open,
            latency_b_ns    => open,
            last_rx_ts      => open,
            last_tx_ts      => open,
            stats_valid     => open
        );

    ----------------------------------------------------------------------------
    -- Debug UART Reporter
    ----------------------------------------------------------------------------
    debug_reporter_inst : entity work.gtx_debug_reporter
        generic map (
            CLK_FREQ  => 200_000_000,
            BAUD_RATE => 115200,
            REPORT_MS => 500
        )
        port map (
            clk                   => sys_clk,
            rst                   => sys_rst,
            -- PHY status
            qpll_lock             => qpll_lock,
            qpll_refclk_lost      => '0',
            tx_resetdone          => gtx_ready,
            rx_resetdone          => gtx_ready,
            -- GTX debug
            debug_por_done        => debug_por_done,
            debug_qpll_reset      => debug_qpll_reset,
            debug_gtx_reset       => debug_gtx_reset,
            debug_tx_userrdy      => debug_tx_userrdy,
            debug_rx_userrdy      => debug_rx_userrdy,
            debug_refclk_present  => debug_refclk_present,
            -- PCS status
            pcs_block_lock        => pcs_block_lock,
            rx_header_valid       => '1',
            rx_datavalid          => '1',
            block_lock_state      => debug_pcs_block_state,
            rx_cdrlock            => debug_rx_cdrlock,
            rx_elecidle           => debug_rx_elecidle,
            tx_clk_heartbeat      => tx_clk_heartbeat,
            pcs_reset             => tx_rst,
            reset_int_dbg         => sys_rst,
            gtx_ready_dbg         => gtx_ready,
            -- Network counters
            start_detect_count    => mac_start_detect,
            frame_count           => mac_frame_count,
            udp_packet_count      => mold_packet_count,
            mold_packet_count     => mold_packet_count,
            mold_msg_extracted    => mold_msg_extracted,
            nasdaq_total_messages => mold_msg_extracted,
            -- ITCH debug
            itch_msg_type         => last_itch_msg_type,
            itch_stock_locate     => last_itch_stock_locate,
            itch_price            => last_itch_price,
            -- Trading counters
            itch_fifo_wr_count    => itch_fifo_wr_count,
            itch_fifo_rd_count    => itch_fifo_rd_count,
            bbo_update_count      => bbo_update_count,
            bbo_fifo_wr_count     => bbo_fifo_wr_count,
            bbo_fifo_rd_count     => bbo_fifo_rd_count,
            bbo_tx_count          => tx_pkt_count(15 downto 0),  -- Actual BBO UDP TX packet count
            -- UART output
            uart_tx               => uart_tx
        );

end rtl;
