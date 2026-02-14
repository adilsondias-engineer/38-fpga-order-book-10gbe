--------------------------------------------------------------------------------
-- Module: bbo_udp_tx
-- Description: Transmits BBO updates via UDP over 10GbE XGMII interface
--
-- Adapted from simple_udp_tx.vhd (Project 34) for order book BBO transmission
--
-- BBO Payload Format (44 bytes):
--   Offset 0:  Symbol (8 bytes ASCII)
--   Offset 8:  Bid Price (4 bytes big-endian, divide by 10000)
--   Offset 12: Bid Shares (4 bytes big-endian)
--   Offset 16: Ask Price (4 bytes big-endian, divide by 10000)
--   Offset 20: Ask Shares (4 bytes big-endian)
--   Offset 24: Spread (4 bytes big-endian, divide by 10000)
--   Offset 28: T1 - ITCH parse timestamp (4 bytes)
--   Offset 32: T2 - CDC FIFO timestamp (4 bytes)
--   Offset 36: T3 - BBO FIFO read timestamp (4 bytes)
--   Offset 40: T4 - UDP TX start timestamp (4 bytes)
--
-- XGMII TX: 64b/8c interface at 161.13 MHz
--
-- ==============================================================================
-- Copyright 2026 Adilson Dias
--
-- Licensed under the Apache License, Version 2.0
-- ==============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.order_book_pkg.all;

entity bbo_udp_tx is
    generic (
        SRC_MAC         : std_logic_vector(47 downto 0) := x"000A3501FEC0";
        DST_MAC         : std_logic_vector(47 downto 0) := x"FFFFFFFFFFFF";  -- Broadcast
        SRC_IP          : std_logic_vector(31 downto 0) := x"C0A800D7";       -- 192.168.0.215
        DST_IP          : std_logic_vector(31 downto 0) := x"C0A80090";       -- 192.168.0.144
        SRC_PORT        : std_logic_vector(15 downto 0) := x"3039";           -- 12345
        DST_PORT        : std_logic_vector(15 downto 0) := x"1388";           -- 5000
        -- Test mode: send fixed test packets every ~1 second (bypasses bbo_valid)
        TEST_MODE       : boolean := false
    );
    port (
        clk             : in  std_logic;  -- 161.13 MHz tx_clk
        rst             : in  std_logic;

        -- BBO input (trigger on update)
        bbo_valid       : in  std_logic;
        bbo_symbol      : in  std_logic_vector(63 downto 0);
        bbo_bid_price   : in  std_logic_vector(31 downto 0);
        bbo_bid_shares  : in  std_logic_vector(31 downto 0);
        bbo_ask_price   : in  std_logic_vector(31 downto 0);
        bbo_ask_shares  : in  std_logic_vector(31 downto 0);
        bbo_spread      : in  std_logic_vector(31 downto 0);

        -- Timestamps input (captured before TX)
        ts_t1           : in  std_logic_vector(31 downto 0);
        ts_t2           : in  std_logic_vector(31 downto 0);
        ts_t3           : in  std_logic_vector(31 downto 0);

        -- XGMII TX output
        xgmii_txd       : out std_logic_vector(63 downto 0);
        xgmii_txc       : out std_logic_vector(7 downto 0);

        -- T4 capture (captured at TX_START state)
        ts_t4_capture   : out std_logic_vector(31 downto 0);
        ts_t4_valid     : out std_logic;

        -- Status
        tx_count        : out std_logic_vector(31 downto 0);
        tx_busy         : out std_logic
    );
end bbo_udp_tx;

architecture rtl of bbo_udp_tx is

    -- Timestamp counter for T4 capture (125 MHz equivalent in 161 MHz domain)
    -- For simplicity, capture raw cycle count; software converts
    signal timestamp_counter : unsigned(31 downto 0) := (others => '0');

    -- Packet counter
    signal pkt_cnt          : unsigned(31 downto 0) := (others => '0');

    -- Frame assembly (86 bytes: 14 ETH + 20 IP + 8 UDP + 44 BBO payload)
    -- Minimum Ethernet = 60 bytes, so 86 > 60 (no padding needed)
    constant FRAME_LEN      : integer := 86;
    constant IP_LEN         : std_logic_vector(15 downto 0) := x"0048";  -- 72 = 20 + 8 + 44
    constant UDP_LEN        : std_logic_vector(15 downto 0) := x"0034";  -- 52 = 8 + 44

    -- Latched BBO data (captured on bbo_valid)
    signal lat_symbol       : std_logic_vector(63 downto 0) := (others => '0');
    signal lat_bid_price    : std_logic_vector(31 downto 0) := (others => '0');
    signal lat_bid_shares   : std_logic_vector(31 downto 0) := (others => '0');
    signal lat_ask_price    : std_logic_vector(31 downto 0) := (others => '0');
    signal lat_ask_shares   : std_logic_vector(31 downto 0) := (others => '0');
    signal lat_spread       : std_logic_vector(31 downto 0) := (others => '0');
    signal lat_t1           : std_logic_vector(31 downto 0) := (others => '0');
    signal lat_t2           : std_logic_vector(31 downto 0) := (others => '0');
    signal lat_t3           : std_logic_vector(31 downto 0) := (others => '0');
    signal lat_t4           : std_logic_vector(31 downto 0) := (others => '0');

    -- CRC-32 computation
    signal crc_reg          : std_logic_vector(31 downto 0) := (others => '1');
    signal crc_byte_idx     : unsigned(6 downto 0) := (others => '0');
    signal crc_done         : std_logic := '0';
    signal crc_final        : std_logic_vector(31 downto 0) := (others => '0');

    -- Frame bytes array for CRC calculation
    type frame_array_t is array (0 to FRAME_LEN-1) of std_logic_vector(7 downto 0);
    signal frame_data       : frame_array_t := (others => (others => '0'));

    -- IP header checksum (precomputed for static fields)
    -- Calculation: Sum of 16-bit words (version/IHL, total_len, id, flags, TTL/proto, src_ip, dst_ip)
    --   0x4500 + 0x0048 + 0x0001 + 0x4000 + 0x4011 + 0xC0A8 + 0x00D7 + 0xC0A8 + 0x0090 = 0x4813
    --   One's complement: ~0x4813 = 0xB7EC
    constant IP_HDR_CHECKSUM : std_logic_vector(15 downto 0) := x"B7EC";

    -- CRC-32 byte-at-a-time function (reflected polynomial 0xEDB88320)
    function crc32_byte(crc_in : std_logic_vector(31 downto 0);
                        data   : std_logic_vector(7 downto 0))
        return std_logic_vector is
        variable crc : std_logic_vector(31 downto 0);
    begin
        crc := crc_in;
        crc(7 downto 0) := crc(7 downto 0) xor data;
        for i in 0 to 7 loop
            if crc(0) = '1' then
                crc := ('0' & crc(31 downto 1)) xor x"EDB88320";
            else
                crc := '0' & crc(31 downto 1);
            end if;
        end loop;
        return crc;
    end function;

    -- TX state machine
    type tx_state_t is (
        TX_IDLE,
        TX_LATCH_DATA,
        TX_BUILD_FRAME,
        TX_CRC_COMPUTE,
        TX_START,
        TX_DATA_1, TX_DATA_2, TX_DATA_3, TX_DATA_4,
        TX_DATA_5, TX_DATA_6, TX_DATA_7, TX_DATA_8,
        TX_DATA_9, TX_DATA_10, TX_DATA_11,
        TX_CRC_OUT,
        TX_TERM
    );
    signal tx_state : tx_state_t := TX_IDLE;

    -- XGMII idle constant
    constant XGMII_IDLE_D : std_logic_vector(63 downto 0) := x"0707070707070707";
    constant XGMII_IDLE_C : std_logic_vector(7 downto 0)  := x"FF";

    -- Pending TX flag
    signal tx_pending       : std_logic := '0';

    -- Test mode: timer for periodic test packets (~1 second at 156.25 MHz)
    constant TEST_INTERVAL  : unsigned(27 downto 0) := x"9502F90";  -- 156,250,000 cycles = 1 sec
    signal test_timer       : unsigned(27 downto 0) := (others => '0');
    signal test_trigger     : std_logic := '0';

    -- Test mode: fixed test data (recognizable pattern)
    constant TEST_SYMBOL    : std_logic_vector(63 downto 0) := x"5445535420202020";  -- "TEST    "
    constant TEST_BID_PRICE : std_logic_vector(31 downto 0) := x"000186A0";  -- 100000 = $10.0000
    constant TEST_BID_SHARES: std_logic_vector(31 downto 0) := x"00000064";  -- 100 shares
    constant TEST_ASK_PRICE : std_logic_vector(31 downto 0) := x"000186B4";  -- 100020 = $10.0020
    constant TEST_ASK_SHARES: std_logic_vector(31 downto 0) := x"000000C8";  -- 200 shares
    constant TEST_SPREAD    : std_logic_vector(31 downto 0) := x"00000014";  -- 20 = $0.0020

begin

    tx_count <= std_logic_vector(pkt_cnt);
    tx_busy <= '1' when tx_state /= TX_IDLE else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tx_state <= TX_IDLE;
                timestamp_counter <= (others => '0');
                pkt_cnt <= (others => '0');
                crc_reg <= (others => '1');
                crc_byte_idx <= (others => '0');
                crc_done <= '0';
                xgmii_txd <= XGMII_IDLE_D;
                xgmii_txc <= XGMII_IDLE_C;
                tx_pending <= '0';
                ts_t4_capture <= (others => '0');
                ts_t4_valid <= '0';
                test_timer <= (others => '0');
                test_trigger <= '0';
            else
                -- Free-running timestamp counter
                timestamp_counter <= timestamp_counter + 1;

                -- Default outputs
                xgmii_txd <= XGMII_IDLE_D;
                xgmii_txc <= XGMII_IDLE_C;
                ts_t4_valid <= '0';
                test_trigger <= '0';

                -- Test mode: periodic timer
                if TEST_MODE then
                    if test_timer >= TEST_INTERVAL then
                        test_timer <= (others => '0');
                        test_trigger <= '1';
                    else
                        test_timer <= test_timer + 1;
                    end if;
                end if;

                -- Capture pending TX request (normal mode or test mode)
                if bbo_valid = '1' or test_trigger = '1' then
                    tx_pending <= '1';
                end if;

                case tx_state is

                    when TX_IDLE =>
                        if tx_pending = '1' then
                            tx_state <= TX_LATCH_DATA;
                            tx_pending <= '0';
                        end if;

                    when TX_LATCH_DATA =>
                        -- Latch BBO data and timestamps (use test data in TEST_MODE)
                        if TEST_MODE then
                            lat_symbol <= TEST_SYMBOL;
                            lat_bid_price <= TEST_BID_PRICE;
                            lat_bid_shares <= TEST_BID_SHARES;
                            lat_ask_price <= TEST_ASK_PRICE;
                            lat_ask_shares <= TEST_ASK_SHARES;
                            lat_spread <= TEST_SPREAD;
                            lat_t1 <= x"11111111";  -- Recognizable test pattern
                            lat_t2 <= x"22222222";
                            lat_t3 <= x"33333333";
                        else
                            lat_symbol <= bbo_symbol;
                            lat_bid_price <= bbo_bid_price;
                            lat_bid_shares <= bbo_bid_shares;
                            lat_ask_price <= bbo_ask_price;
                            lat_ask_shares <= bbo_ask_shares;
                            lat_spread <= bbo_spread;
                            lat_t1 <= ts_t1;
                            lat_t2 <= ts_t2;
                            lat_t3 <= ts_t3;
                        end if;
                        tx_state <= TX_BUILD_FRAME;

                    when TX_BUILD_FRAME =>
                        -- Capture T4 timestamp NOW (before CRC computation)
                        -- This ensures CRC is computed over the actual T4 value
                        lat_t4 <= std_logic_vector(timestamp_counter);
                        ts_t4_capture <= std_logic_vector(timestamp_counter);
                        ts_t4_valid <= '1';

                        -- Build frame in array for CRC computation
                        -- Ethernet header (14 bytes)
                        frame_data(0) <= DST_MAC(47 downto 40);
                        frame_data(1) <= DST_MAC(39 downto 32);
                        frame_data(2) <= DST_MAC(31 downto 24);
                        frame_data(3) <= DST_MAC(23 downto 16);
                        frame_data(4) <= DST_MAC(15 downto 8);
                        frame_data(5) <= DST_MAC(7 downto 0);
                        frame_data(6) <= SRC_MAC(47 downto 40);
                        frame_data(7) <= SRC_MAC(39 downto 32);
                        frame_data(8) <= SRC_MAC(31 downto 24);
                        frame_data(9) <= SRC_MAC(23 downto 16);
                        frame_data(10) <= SRC_MAC(15 downto 8);
                        frame_data(11) <= SRC_MAC(7 downto 0);
                        frame_data(12) <= x"08";  -- EtherType IPv4
                        frame_data(13) <= x"00";

                        -- IP header (20 bytes)
                        frame_data(14) <= x"45";  -- Version/IHL
                        frame_data(15) <= x"00";  -- DSCP/ECN
                        frame_data(16) <= IP_LEN(15 downto 8);
                        frame_data(17) <= IP_LEN(7 downto 0);
                        frame_data(18) <= x"00";  -- Identification
                        frame_data(19) <= x"01";
                        frame_data(20) <= x"40";  -- Flags: DF
                        frame_data(21) <= x"00";  -- Fragment offset
                        frame_data(22) <= x"40";  -- TTL = 64
                        frame_data(23) <= x"11";  -- Protocol = UDP
                        frame_data(24) <= IP_HDR_CHECKSUM(15 downto 8);
                        frame_data(25) <= IP_HDR_CHECKSUM(7 downto 0);
                        frame_data(26) <= SRC_IP(31 downto 24);
                        frame_data(27) <= SRC_IP(23 downto 16);
                        frame_data(28) <= SRC_IP(15 downto 8);
                        frame_data(29) <= SRC_IP(7 downto 0);
                        frame_data(30) <= DST_IP(31 downto 24);
                        frame_data(31) <= DST_IP(23 downto 16);
                        frame_data(32) <= DST_IP(15 downto 8);
                        frame_data(33) <= DST_IP(7 downto 0);

                        -- UDP header (8 bytes)
                        frame_data(34) <= SRC_PORT(15 downto 8);
                        frame_data(35) <= SRC_PORT(7 downto 0);
                        frame_data(36) <= DST_PORT(15 downto 8);
                        frame_data(37) <= DST_PORT(7 downto 0);
                        frame_data(38) <= UDP_LEN(15 downto 8);
                        frame_data(39) <= UDP_LEN(7 downto 0);
                        frame_data(40) <= x"00";  -- UDP checksum disabled
                        frame_data(41) <= x"00";

                        -- BBO payload (44 bytes)
                        -- Symbol (8 bytes) - bytes 42-49
                        frame_data(42) <= lat_symbol(63 downto 56);
                        frame_data(43) <= lat_symbol(55 downto 48);
                        frame_data(44) <= lat_symbol(47 downto 40);
                        frame_data(45) <= lat_symbol(39 downto 32);
                        frame_data(46) <= lat_symbol(31 downto 24);
                        frame_data(47) <= lat_symbol(23 downto 16);
                        frame_data(48) <= lat_symbol(15 downto 8);
                        frame_data(49) <= lat_symbol(7 downto 0);

                        -- Bid price (4 bytes) - bytes 50-53
                        frame_data(50) <= lat_bid_price(31 downto 24);
                        frame_data(51) <= lat_bid_price(23 downto 16);
                        frame_data(52) <= lat_bid_price(15 downto 8);
                        frame_data(53) <= lat_bid_price(7 downto 0);

                        -- Bid shares (4 bytes) - bytes 54-57
                        frame_data(54) <= lat_bid_shares(31 downto 24);
                        frame_data(55) <= lat_bid_shares(23 downto 16);
                        frame_data(56) <= lat_bid_shares(15 downto 8);
                        frame_data(57) <= lat_bid_shares(7 downto 0);

                        -- Ask price (4 bytes) - bytes 58-61
                        frame_data(58) <= lat_ask_price(31 downto 24);
                        frame_data(59) <= lat_ask_price(23 downto 16);
                        frame_data(60) <= lat_ask_price(15 downto 8);
                        frame_data(61) <= lat_ask_price(7 downto 0);

                        -- Ask shares (4 bytes) - bytes 62-65
                        frame_data(62) <= lat_ask_shares(31 downto 24);
                        frame_data(63) <= lat_ask_shares(23 downto 16);
                        frame_data(64) <= lat_ask_shares(15 downto 8);
                        frame_data(65) <= lat_ask_shares(7 downto 0);

                        -- Spread (4 bytes) - bytes 66-69
                        frame_data(66) <= lat_spread(31 downto 24);
                        frame_data(67) <= lat_spread(23 downto 16);
                        frame_data(68) <= lat_spread(15 downto 8);
                        frame_data(69) <= lat_spread(7 downto 0);

                        -- T1 (4 bytes) - bytes 70-73
                        frame_data(70) <= lat_t1(31 downto 24);
                        frame_data(71) <= lat_t1(23 downto 16);
                        frame_data(72) <= lat_t1(15 downto 8);
                        frame_data(73) <= lat_t1(7 downto 0);

                        -- T2 (4 bytes) - bytes 74-77
                        frame_data(74) <= lat_t2(31 downto 24);
                        frame_data(75) <= lat_t2(23 downto 16);
                        frame_data(76) <= lat_t2(15 downto 8);
                        frame_data(77) <= lat_t2(7 downto 0);

                        -- T3 (4 bytes) - bytes 78-81
                        frame_data(78) <= lat_t3(31 downto 24);
                        frame_data(79) <= lat_t3(23 downto 16);
                        frame_data(80) <= lat_t3(15 downto 8);
                        frame_data(81) <= lat_t3(7 downto 0);

                        -- T4 (4 bytes) - bytes 82-85 - captured NOW before CRC computation
                        -- Use timestamp_counter directly to ensure CRC is computed over actual value
                        frame_data(82) <= std_logic_vector(timestamp_counter(31 downto 24));
                        frame_data(83) <= std_logic_vector(timestamp_counter(23 downto 16));
                        frame_data(84) <= std_logic_vector(timestamp_counter(15 downto 8));
                        frame_data(85) <= std_logic_vector(timestamp_counter(7 downto 0));

                        -- Start CRC computation
                        crc_reg <= (others => '1');
                        crc_byte_idx <= (others => '0');
                        tx_state <= TX_CRC_COMPUTE;

                    when TX_CRC_COMPUTE =>
                        -- Compute CRC one byte per clock
                        if crc_byte_idx < FRAME_LEN then
                            crc_reg <= crc32_byte(crc_reg, frame_data(to_integer(crc_byte_idx)));
                            crc_byte_idx <= crc_byte_idx + 1;
                        else
                            -- CRC done: complement and store
                            crc_final <= not crc_reg;
                            crc_done <= '1';
                            tx_state <= TX_START;
                        end if;

                    when TX_START =>
                        -- T4 already captured in TX_BUILD_FRAME (before CRC computation)
                        -- Do NOT update frame_data here - CRC was computed over TX_BUILD_FRAME values

                        -- XGMII Start: FB + 6x 55 + D5
                        xgmii_txd <= x"D5" & x"55" & x"55" & x"55" &
                                     x"55" & x"55" & x"55" & x"FB";
                        xgmii_txc <= "00000001";
                        tx_state <= TX_DATA_1;

                    -- Data states: 8 bytes per clock (88 bytes = 11 clocks)
                    when TX_DATA_1 =>
                        xgmii_txd <= frame_data(7) & frame_data(6) & frame_data(5) & frame_data(4) &
                                     frame_data(3) & frame_data(2) & frame_data(1) & frame_data(0);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_2;

                    when TX_DATA_2 =>
                        xgmii_txd <= frame_data(15) & frame_data(14) & frame_data(13) & frame_data(12) &
                                     frame_data(11) & frame_data(10) & frame_data(9) & frame_data(8);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_3;

                    when TX_DATA_3 =>
                        xgmii_txd <= frame_data(23) & frame_data(22) & frame_data(21) & frame_data(20) &
                                     frame_data(19) & frame_data(18) & frame_data(17) & frame_data(16);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_4;

                    when TX_DATA_4 =>
                        xgmii_txd <= frame_data(31) & frame_data(30) & frame_data(29) & frame_data(28) &
                                     frame_data(27) & frame_data(26) & frame_data(25) & frame_data(24);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_5;

                    when TX_DATA_5 =>
                        xgmii_txd <= frame_data(39) & frame_data(38) & frame_data(37) & frame_data(36) &
                                     frame_data(35) & frame_data(34) & frame_data(33) & frame_data(32);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_6;

                    when TX_DATA_6 =>
                        xgmii_txd <= frame_data(47) & frame_data(46) & frame_data(45) & frame_data(44) &
                                     frame_data(43) & frame_data(42) & frame_data(41) & frame_data(40);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_7;

                    when TX_DATA_7 =>
                        xgmii_txd <= frame_data(55) & frame_data(54) & frame_data(53) & frame_data(52) &
                                     frame_data(51) & frame_data(50) & frame_data(49) & frame_data(48);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_8;

                    when TX_DATA_8 =>
                        xgmii_txd <= frame_data(63) & frame_data(62) & frame_data(61) & frame_data(60) &
                                     frame_data(59) & frame_data(58) & frame_data(57) & frame_data(56);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_9;

                    when TX_DATA_9 =>
                        xgmii_txd <= frame_data(71) & frame_data(70) & frame_data(69) & frame_data(68) &
                                     frame_data(67) & frame_data(66) & frame_data(65) & frame_data(64);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_10;

                    when TX_DATA_10 =>
                        xgmii_txd <= frame_data(79) & frame_data(78) & frame_data(77) & frame_data(76) &
                                     frame_data(75) & frame_data(74) & frame_data(73) & frame_data(72);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_11;

                    when TX_DATA_11 =>
                        -- Bytes 80-85 (6 bytes) + first 2 CRC bytes
                        -- Frame is 86 bytes, CRC is 4 bytes. 86+4=90 bytes = 11*8+2
                        -- So we need to start CRC in this cycle to maintain alignment
                        xgmii_txd <= crc_final(15 downto 8) & crc_final(7 downto 0) &
                                     frame_data(85) & frame_data(84) &
                                     frame_data(83) & frame_data(82) & frame_data(81) & frame_data(80);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_CRC_OUT;

                    when TX_CRC_OUT =>
                        -- Output last 2 CRC bytes + Terminate (FD) + 5 idle
                        xgmii_txd <= x"07" & x"07" & x"07" & x"07" & x"07" & x"FD" &
                                     crc_final(31 downto 24) & crc_final(23 downto 16);
                        xgmii_txc <= "11111100";
                        tx_state <= TX_TERM;

                    when TX_TERM =>
                        -- Terminate frame
                        xgmii_txd <= XGMII_IDLE_D;
                        xgmii_txc <= XGMII_IDLE_C;
                        pkt_cnt <= pkt_cnt + 1;
                        tx_state <= TX_IDLE;

                end case;
            end if;
        end if;
    end process;

end rtl;
