--------------------------------------------------------------------------------
-- Module: link_init_tx
-- Description: Sends a few UDP packets at startup to establish 10GbE link
--
-- Unlike simple_udp_tx which sends continuously, this module:
--   1. Waits for PHY ready (block lock achieved)
--   2. Sends STARTUP_PACKETS packets (default 5)
--   3. Stops permanently - BBO TX takes over for ongoing traffic
--
-- This ensures the switch learns the FPGA's MAC address without wasting
-- bandwidth with continuous "hello" packets in production.
--
-- Packet format:
--   Dst MAC: FF:FF:FF:FF:FF:FF (broadcast)
--   Src MAC: 00:0A:35:01:FE:C0
--   Src IP:  192.168.0.215
--   Dst IP:  192.168.0.144
--   UDP port: 12345 -> 12345
--   Payload: "LINK_INIT"
--
-- ==============================================================================
-- Copyright 2026 Adilson Dias
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- ==============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity link_init_tx is
    generic (
        CLK_FREQ        : integer := 161_130_000;  -- tx_clk frequency
        STARTUP_DELAY_MS: integer := 100;          -- Wait after PHY ready before sending
        STARTUP_PACKETS : integer := 5;            -- Number of init packets to send
        PACKET_GAP_MS   : integer := 50            -- Gap between init packets
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- PHY status (wait for this before sending)
        phy_ready       : in  std_logic;

        -- XGMII TX output (directly drives XGMII when active)
        xgmii_txd       : out std_logic_vector(63 downto 0);
        xgmii_txc       : out std_logic_vector(7 downto 0);

        -- Control outputs
        init_done       : out std_logic;  -- High after all init packets sent
        init_active     : out std_logic;  -- High while sending init packet
        tx_count        : out std_logic_vector(7 downto 0)  -- Packets sent
    );
end link_init_tx;

architecture rtl of link_init_tx is

    -- Timing constants
    constant STARTUP_DELAY : integer := (CLK_FREQ / 1000) * STARTUP_DELAY_MS;
    constant PACKET_GAP    : integer := (CLK_FREQ / 1000) * PACKET_GAP_MS;

    signal delay_cnt       : unsigned(27 downto 0) := (others => '0');
    signal pkt_cnt         : unsigned(7 downto 0) := (others => '0');
    signal init_complete   : std_logic := '0';

    -- Frame data: 60 bytes (minimum Ethernet frame, no CRC yet)
    type byte_array_t is array (0 to 59) of std_logic_vector(7 downto 0);
    constant FRAME_DATA : byte_array_t := (
        -- Dst MAC: FF:FF:FF:FF:FF:FF (broadcast)
        x"FF", x"FF", x"FF", x"FF", x"FF", x"FF",
        -- Src MAC: 00:0A:35:01:FE:C0
        x"00", x"0A", x"35", x"01", x"FE", x"C0",
        -- EtherType: 0x0800 (IPv4)
        x"08", x"00",
        -- IP Header (20 bytes)
        x"45", x"00",       -- Version/IHL=5, DSCP/ECN=0
        x"00", x"25",       -- Total Length = 37 (20 IP + 8 UDP + 9 payload)
        x"00", x"01",       -- Identification
        x"40", x"00",       -- Flags: Don't Fragment, Fragment Offset: 0
        x"40", x"11",       -- TTL=64, Protocol=17 (UDP)
        x"B8", x"0F",       -- Header Checksum: ~(0x4500+0x0025+0x0001+0x4000+0x4011+0xC0A8+0x00D7+0xC0A8+0x0090) = 0xB80F
        x"C0", x"A8", x"00", x"D7",  -- Src IP: 192.168.0.215
        x"C0", x"A8", x"00", x"90",  -- Dst IP: 192.168.0.144
        -- UDP Header (8 bytes)
        x"30", x"39",       -- Src Port: 12345
        x"30", x"39",       -- Dst Port: 12345
        x"00", x"11",       -- Length: 17 (8 header + 9 payload)
        x"00", x"00",       -- Checksum: 0 (disabled)
        -- Payload: "LINK_INIT" (9 bytes)
        x"4C", x"49", x"4E", x"4B", x"5F",  -- "LINK_"
        x"49", x"4E", x"49", x"54",          -- "INIT"
        -- Padding to 60 bytes (9 zero bytes)
        x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00"
    );

    -- CRC-32 computation
    signal crc_reg         : std_logic_vector(31 downto 0) := (others => '1');
    signal crc_byte_idx    : unsigned(5 downto 0) := (others => '0');
    signal crc_final       : std_logic_vector(31 downto 0) := (others => '0');

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
        WAIT_PHY_READY,   -- Wait for PHY/PCS to be ready
        WAIT_STARTUP,     -- Initial delay after PHY ready
        TX_CRC_COMPUTE,   -- Compute CRC for packet
        TX_START,         -- Send preamble/SFD
        TX_DATA_1, TX_DATA_2, TX_DATA_3, TX_DATA_4,
        TX_DATA_5, TX_DATA_6, TX_DATA_7, TX_DATA_8,
        TX_TERM,          -- Terminate packet
        WAIT_GAP,         -- Wait between packets
        INIT_COMPLETE_ST     -- All done, permanent idle
    );
    signal tx_state : tx_state_t := WAIT_PHY_READY;

    -- XGMII idle constant
    constant XGMII_IDLE_D : std_logic_vector(63 downto 0) := x"0707070707070707";
    constant XGMII_IDLE_C : std_logic_vector(7 downto 0)  := x"FF";

begin

    tx_count <= std_logic_vector(pkt_cnt);
    init_done <= init_complete;

    -- Active when transmitting a packet
    init_active <= '1' when tx_state = TX_START or
                           tx_state = TX_DATA_1 or tx_state = TX_DATA_2 or
                           tx_state = TX_DATA_3 or tx_state = TX_DATA_4 or
                           tx_state = TX_DATA_5 or tx_state = TX_DATA_6 or
                           tx_state = TX_DATA_7 or tx_state = TX_DATA_8 or
                           tx_state = TX_TERM else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tx_state <= WAIT_PHY_READY;
                delay_cnt <= (others => '0');
                pkt_cnt <= (others => '0');
                init_complete <= '0';
                crc_reg <= (others => '1');
                crc_byte_idx <= (others => '0');
                xgmii_txd <= XGMII_IDLE_D;
                xgmii_txc <= XGMII_IDLE_C;
            else
                -- Default: idle
                xgmii_txd <= XGMII_IDLE_D;
                xgmii_txc <= XGMII_IDLE_C;

                case tx_state is

                    when WAIT_PHY_READY =>
                        -- Wait for PHY to be ready (QPLL locked, GTX reset done)
                        if phy_ready = '1' then
                            delay_cnt <= (others => '0');
                            tx_state <= WAIT_STARTUP;
                        end if;

                    when WAIT_STARTUP =>
                        -- Wait startup delay before sending first packet
                        if delay_cnt >= to_unsigned(STARTUP_DELAY, 28) then
                            crc_reg <= (others => '1');
                            crc_byte_idx <= (others => '0');
                            tx_state <= TX_CRC_COMPUTE;
                        else
                            delay_cnt <= delay_cnt + 1;
                        end if;

                    when TX_CRC_COMPUTE =>
                        -- Compute CRC one byte per clock (60 clocks)
                        if crc_byte_idx < 60 then
                            crc_reg <= crc32_byte(crc_reg, FRAME_DATA(to_integer(crc_byte_idx)));
                            crc_byte_idx <= crc_byte_idx + 1;
                        else
                            crc_final <= not crc_reg;
                            tx_state <= TX_START;
                        end if;

                    when TX_START =>
                        -- XGMII Start word: Lane 0=FB(Start), Lanes 1-6=55(preamble), Lane 7=D5(SFD)
                        xgmii_txd <= x"D5" & x"55" & x"55" & x"55" &
                                     x"55" & x"55" & x"55" & x"FB";
                        xgmii_txc <= "00000001";
                        tx_state <= TX_DATA_1;

                    when TX_DATA_1 =>
                        -- Bytes 0-7
                        xgmii_txd <= FRAME_DATA(7) & FRAME_DATA(6) & FRAME_DATA(5) & FRAME_DATA(4) &
                                     FRAME_DATA(3) & FRAME_DATA(2) & FRAME_DATA(1) & FRAME_DATA(0);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_2;

                    when TX_DATA_2 =>
                        -- Bytes 8-15
                        xgmii_txd <= FRAME_DATA(15) & FRAME_DATA(14) & FRAME_DATA(13) & FRAME_DATA(12) &
                                     FRAME_DATA(11) & FRAME_DATA(10) & FRAME_DATA(9) & FRAME_DATA(8);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_3;

                    when TX_DATA_3 =>
                        -- Bytes 16-23
                        xgmii_txd <= FRAME_DATA(23) & FRAME_DATA(22) & FRAME_DATA(21) & FRAME_DATA(20) &
                                     FRAME_DATA(19) & FRAME_DATA(18) & FRAME_DATA(17) & FRAME_DATA(16);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_4;

                    when TX_DATA_4 =>
                        -- Bytes 24-31
                        xgmii_txd <= FRAME_DATA(31) & FRAME_DATA(30) & FRAME_DATA(29) & FRAME_DATA(28) &
                                     FRAME_DATA(27) & FRAME_DATA(26) & FRAME_DATA(25) & FRAME_DATA(24);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_5;

                    when TX_DATA_5 =>
                        -- Bytes 32-39
                        xgmii_txd <= FRAME_DATA(39) & FRAME_DATA(38) & FRAME_DATA(37) & FRAME_DATA(36) &
                                     FRAME_DATA(35) & FRAME_DATA(34) & FRAME_DATA(33) & FRAME_DATA(32);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_6;

                    when TX_DATA_6 =>
                        -- Bytes 40-47
                        xgmii_txd <= FRAME_DATA(47) & FRAME_DATA(46) & FRAME_DATA(45) & FRAME_DATA(44) &
                                     FRAME_DATA(43) & FRAME_DATA(42) & FRAME_DATA(41) & FRAME_DATA(40);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_7;

                    when TX_DATA_7 =>
                        -- Bytes 48-55
                        xgmii_txd <= FRAME_DATA(55) & FRAME_DATA(54) & FRAME_DATA(53) & FRAME_DATA(52) &
                                     FRAME_DATA(51) & FRAME_DATA(50) & FRAME_DATA(49) & FRAME_DATA(48);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_DATA_8;

                    when TX_DATA_8 =>
                        -- Bytes 56-59 (padding) + 4 CRC bytes
                        xgmii_txd <= crc_final(31 downto 24) & crc_final(23 downto 16) &
                                     crc_final(15 downto 8) & crc_final(7 downto 0) &
                                     FRAME_DATA(59) & FRAME_DATA(58) & FRAME_DATA(57) & FRAME_DATA(56);
                        xgmii_txc <= "00000000";
                        tx_state <= TX_TERM;

                    when TX_TERM =>
                        -- Terminate in lane 0
                        xgmii_txd <= x"07" & x"07" & x"07" & x"07" &
                                     x"07" & x"07" & x"07" & x"FD";
                        xgmii_txc <= "11111111";
                        pkt_cnt <= pkt_cnt + 1;

                        -- Check if we've sent enough packets
                        if pkt_cnt + 1 >= to_unsigned(STARTUP_PACKETS, 8) then
                            init_complete <= '1';
                            tx_state <= INIT_COMPLETE_ST;
                        else
                            delay_cnt <= (others => '0');
                            tx_state <= WAIT_GAP;
                        end if;

                    when WAIT_GAP =>
                        -- Wait between packets
                        if delay_cnt >= to_unsigned(PACKET_GAP, 28) then
                            crc_reg <= (others => '1');
                            crc_byte_idx <= (others => '0');
                            tx_state <= TX_CRC_COMPUTE;
                        else
                            delay_cnt <= delay_cnt + 1;
                        end if;

                    when INIT_COMPLETE_ST =>
                        -- Permanently idle - BBO TX takes over
                        null;

                end case;
            end if;
        end if;
    end process;

end rtl;
