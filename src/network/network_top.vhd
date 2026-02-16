--------------------------------------------------------------------------------
-- Network Top-Level Module for Project 38 (10GbE Order Book)
-- Purpose: Integrates 10GbE network layer components
--          Pure network layer - no trading logic
--
-- Based on Project 23 ethernet_top architecture for layer separation
--
-- Components:
--   - GTX 10G Wrapper (transceiver interface)
--   - PCS 10GBASE-R (64B/66B encoding/decoding)
--   - MAC Parser (Ethernet frame parsing)
--   - MoldUDP64 Handler (MoldUDP64 protocol, ITCH message extraction)
--   - Link Init TX (sends startup packets for switch auto-negotiation)
--
-- Clock Domains:
--   - sys_clk (200 MHz): DRP clock for GTX, debug
--   - tx_clk (156.25 MHz): GTX user clock, all network processing
--
-- Data Flow:
--   SFP+ RX -> GTX RX -> PCS RX -> MAC Parser -> MoldUDP64 -> ITCH msg stream
--   BBO TX -> Link Init Mux -> PCS TX -> GTX TX -> SFP+ TX
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VCOMPONENTS.ALL;

entity network_top is
    generic (
        SIM_MODE    : boolean := false
    );
    port (
        -- System clock (200 MHz for DRP)
        sys_clk             : in  std_logic;
        sys_rst_n           : in  std_logic;

        -- SFP+ interface
        sfp_refclk_p        : in  std_logic;
        sfp_refclk_n        : in  std_logic;
        sfp_rx_p            : in  std_logic;
        sfp_rx_n            : in  std_logic;
        sfp_tx_p            : out std_logic;
        sfp_tx_n            : out std_logic;

        -- TX clock output (156.25 MHz)
        tx_clk              : out std_logic;
        tx_rst              : out std_logic;

        -- ITCH message stream output (tx_clk domain)
        mold_itch_valid     : out std_logic;
        mold_itch_data      : out std_logic_vector(7 downto 0);
        mold_itch_start     : out std_logic;
        mold_itch_end       : out std_logic;

        -- BBO UDP TX input (tx_clk domain)
        bbo_txd             : in  std_logic_vector(63 downto 0);
        bbo_txc             : in  std_logic_vector(7 downto 0);

        -- Link status
        link_init_done      : out std_logic;

        -- PHY status outputs
        qpll_lock           : out std_logic;
        gtx_ready           : out std_logic;
        pcs_block_lock      : out std_logic;
        pcs_hi_ber          : out std_logic;

        -- Debug counters (tx_clk domain)
        mac_frame_count     : out std_logic_vector(31 downto 0);
        mac_start_detect    : out std_logic_vector(31 downto 0);
        mold_packet_count   : out std_logic_vector(31 downto 0);
        mold_msg_extracted  : out std_logic_vector(31 downto 0);

        -- GTX debug signals
        debug_por_done      : out std_logic;
        debug_qpll_reset    : out std_logic;
        debug_gtx_reset     : out std_logic;
        debug_tx_userrdy    : out std_logic;
        debug_rx_userrdy    : out std_logic;
        debug_refclk_present: out std_logic;
        debug_rx_cdrlock    : out std_logic;
        debug_rx_elecidle   : out std_logic;
        debug_pcs_block_state: out std_logic_vector(2 downto 0);

        -- Raw byte captures for ITCH debug
        debug_mold_input_bytes : out std_logic_vector(63 downto 0)  -- First 8 bytes entering MoldUDP64
    );
end network_top;

architecture rtl of network_top is

    ----------------------------------------------------------------------------
    -- Internal Signals
    ----------------------------------------------------------------------------
    signal sys_rst          : std_logic;
    signal tx_clk_int       : std_logic;
    signal rx_clk_int       : std_logic;
    signal reset_sync       : std_logic := '1';
    signal pcs_rst          : std_logic;

    -- CDC synchronizer for phy_ready
    signal phy_ready_sync   : std_logic_vector(2 downto 0) := (others => '0');
    signal phy_ready_tx     : std_logic := '0';

    -- PHY status
    signal qpll_lock_int    : std_logic;
    signal qpll_refclk_lost : std_logic;
    signal tx_resetdone     : std_logic;
    signal rx_resetdone     : std_logic;
    signal phy_ready        : std_logic;

    -- GTX/PCS interface
    signal gtx_tx_data      : std_logic_vector(63 downto 0);
    signal gtx_tx_header    : std_logic_vector(1 downto 0);
    signal gtx_tx_valid     : std_logic;
    signal gtx_tx_sequence  : std_logic_vector(6 downto 0);
    signal gtx_rx_data      : std_logic_vector(63 downto 0);
    signal gtx_rx_header    : std_logic_vector(1 downto 0);
    signal gtx_rx_datavalid : std_logic;
    signal gtx_rx_valid     : std_logic;
    signal gtx_rx_slip      : std_logic;

    -- XGMII interface
    signal xgmii_rxd        : std_logic_vector(63 downto 0);
    signal xgmii_rxc        : std_logic_vector(7 downto 0);
    signal xgmii_rx_valid   : std_logic;  -- PCS decoder valid (gearbox drops ~1 in 33)
    signal xgmii_txd        : std_logic_vector(63 downto 0);
    signal xgmii_txc        : std_logic_vector(7 downto 0);

    -- Link init TX
    signal link_init_txd    : std_logic_vector(63 downto 0);
    signal link_init_txc    : std_logic_vector(7 downto 0);
    signal link_init_done_int : std_logic;
    signal link_init_active : std_logic;

    -- MAC parser outputs (IP payload = includes 8-byte UDP header)
    signal ip_payload_valid : std_logic;
    signal ip_payload_data  : std_logic_vector(7 downto 0);
    signal ip_payload_start : std_logic;
    signal ip_payload_end   : std_logic;
    signal ip_protocol      : std_logic_vector(7 downto 0);

    -- UDP header stripper + port filter
    -- Strips 8-byte UDP header and only forwards packets to ITCH port
    constant ITCH_UDP_PORT    : std_logic_vector(15 downto 0) := x"3039";  -- Port 12345
    signal udp_byte_cnt       : unsigned(3 downto 0) := (others => '0');
    signal udp_parsing        : std_logic := '0';
    signal udp_forwarding     : std_logic := '0';
    signal udp_first_byte     : std_logic := '0';
    signal udp_dst_port_hi    : std_logic_vector(7 downto 0) := (others => '0');
    signal udp_port_match     : std_logic := '0';
    signal udp_payload_valid_i: std_logic := '0';
    signal udp_payload_data_i : std_logic_vector(7 downto 0) := (others => '0');
    signal udp_payload_start_i: std_logic := '0';
    signal udp_payload_end_i  : std_logic := '0';

    -- PCS status
    signal pcs_block_lock_int : std_logic;
    signal pcs_hi_ber_int   : std_logic;
    signal pcs_block_state_int : std_logic_vector(2 downto 0);

    -- Debug: MoldUDP64 input raw byte capture
    signal mold_input_capture  : std_logic_vector(63 downto 0) := (others => '0');
    signal mold_input_byte_cnt : unsigned(3 downto 0) := (others => '0');
    signal mold_input_active   : std_logic := '0';
    
    
    ----------------------------------------------------------------------------
    -- Reset Synchronization - TWO RESETS
    ----------------------------------------------------------------------------
    
    -- Reset 1: Async assert, sync deassert (for PHY/PLL/PCS)
    signal pcs_rst_meta : std_logic := '1';
    signal pcs_rst_sync : std_logic := '1';
    
    -- Reset 2: FULLY SYNCHRONOUS (for MAC parser BRAM control)
    signal mac_rst_stage1 : std_logic := '1';
    signal mac_rst_stage2 : std_logic := '1';
    signal mac_rst        : std_logic := '1';
    
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of pcs_rst_meta   : signal is "TRUE";
    attribute ASYNC_REG of pcs_rst_sync   : signal is "TRUE";
    attribute ASYNC_REG of mac_rst_stage1 : signal is "TRUE";
    attribute ASYNC_REG of mac_rst_stage2 : signal is "TRUE";
    
--    attribute MAX_FANOUT : integer;
--    attribute MAX_FANOUT of phy_ready  : signal is 16;
--    attribute MAX_FANOUT of phy_ready_sync  : signal is 16;
--    attribute MAX_FANOUT of phy_ready_tx  : signal is 16;
--    attribute MAX_FANOUT of reset_sync : signal is 16;
--    attribute MAX_FANOUT of sys_rst : signal is 16;
--    attribute MAX_FANOUT of tx_clk_int : signal is 16;
--    attribute MAX_FANOUT of rx_clk_int : signal is 16;
--    attribute MAX_FANOUT of pcs_rst : signal is 16;
--    attribute MAX_FANOUT of tx_resetdone : signal is 16;
--    attribute MAX_FANOUT of rx_resetdone : signal is 16;
    
    
begin

    sys_rst <= not sys_rst_n;

    ----------------------------------------------------------------------------
    -- PCS Reset (async assert, sync deassert) - for PHY/PCS
    ----------------------------------------------------------------------------
        process(tx_clk_int, sys_rst_n)
        begin
            if sys_rst_n = '0' then
                pcs_rst_meta <= '1';
                pcs_rst_sync <= '1';
            elsif rising_edge(tx_clk_int) then
                pcs_rst_meta <= '0';
                pcs_rst_sync <= pcs_rst_meta;
            end if;
        end process;

    -- CDC synchronizer for phy_ready
    process(tx_clk_int)
    begin
        if rising_edge(tx_clk_int) then
            phy_ready_sync <= phy_ready_sync(1 downto 0) & phy_ready;
            phy_ready_tx <= phy_ready_sync(2);
        end if;
    end process;

    pcs_rst <= pcs_rst_sync or not phy_ready_tx;

-- MAC Parser Reset (FULLY SYNCHRONOUS) - for BRAM control
        process(tx_clk_int)
        begin
            if rising_edge(tx_clk_int) then
                mac_rst_stage1 <= sys_rst;
                mac_rst_stage2 <= mac_rst_stage1;
                
                -- Add phy_ready condition
                if phy_ready_tx = '0' then
                    mac_rst <= '1';
                else
                    mac_rst <= mac_rst_stage2;
                end if;
            end if;
        end process;
        
    ----------------------------------------------------------------------------
    -- Output Assignments
    ----------------------------------------------------------------------------
    tx_clk <= tx_clk_int;
    tx_rst <= pcs_rst;
    link_init_done <= link_init_done_int;
    qpll_lock <= qpll_lock_int;
    gtx_ready <= tx_resetdone and rx_resetdone;
    pcs_block_lock <= pcs_block_lock_int;
    pcs_hi_ber <= pcs_hi_ber_int;
    debug_pcs_block_state <= pcs_block_state_int;

    ----------------------------------------------------------------------------
    -- GTX 10G Wrapper
    ----------------------------------------------------------------------------
    gtx_inst : entity work.gtx_10g_wrapper
        generic map (
            SIM_MODE    => SIM_MODE,
            GTX_CHANNEL => 0
        )
        port map (
            refclk_p            => sfp_refclk_p,
            refclk_n            => sfp_refclk_n,
            drp_clk             => sys_clk,
            sys_reset           => sys_rst_n,
            gtx_txp             => sfp_tx_p,
            gtx_txn             => sfp_tx_n,
            gtx_rxp             => sfp_rx_p,
            gtx_rxn             => sfp_rx_n,
            tx_clk              => tx_clk_int,
            tx_data             => gtx_tx_data,
            tx_header           => gtx_tx_header,
            tx_valid            => gtx_tx_valid,
            tx_sequence         => gtx_tx_sequence,
            rx_clk              => rx_clk_int,
            rx_data             => gtx_rx_data,
            rx_header           => gtx_rx_header,
            rx_header_valid     => gtx_rx_valid,
            rx_datavalid        => gtx_rx_datavalid,
            rx_gearbox_slip     => gtx_rx_slip,
            qpll_lock           => qpll_lock_int,
            qpll_refclk_lost    => qpll_refclk_lost,
            tx_resetdone        => tx_resetdone,
            rx_resetdone        => rx_resetdone,
            phy_ready           => phy_ready,
            debug_por_done      => debug_por_done,
            debug_qpll_reset    => debug_qpll_reset,
            debug_gtx_reset     => debug_gtx_reset,
            debug_tx_userrdy    => debug_tx_userrdy,
            debug_rx_userrdy    => debug_rx_userrdy,
            debug_refclk_present=> debug_refclk_present,
            debug_rx_cdrlock    => debug_rx_cdrlock,
            debug_rx_elecidle   => debug_rx_elecidle,
            debug_rx_startofseq => open,
            debug_tx_gearbox_ready => open
        );

    gtx_tx_valid <= '1';

    ----------------------------------------------------------------------------
    -- Link Init TX
    ----------------------------------------------------------------------------
    link_init_inst : entity work.link_init_tx
        generic map (
            CLK_FREQ         => 161_130_000,
            STARTUP_DELAY_MS => 100,
            STARTUP_PACKETS  => 5,
            PACKET_GAP_MS    => 50
        )
        port map (
            clk             => tx_clk_int,
            rst             => pcs_rst,
            phy_ready       => phy_ready_tx,
            xgmii_txd       => link_init_txd,
            xgmii_txc       => link_init_txc,
            init_done       => link_init_done_int,
            init_active     => link_init_active,
            tx_count        => open
        );

    -- XGMII TX Mux: Link init during startup, BBO TX after
    xgmii_txd <= link_init_txd when link_init_done_int = '0' else bbo_txd;
    xgmii_txc <= link_init_txc when link_init_done_int = '0' else bbo_txc;

    ----------------------------------------------------------------------------
    -- PCS 10GBASE-R
    ----------------------------------------------------------------------------
    pcs_inst : entity work.pcs_10gbase_r
        port map (
            clk             => tx_clk_int,
            reset           => pcs_rst,
            xgmii_txd       => xgmii_txd,
            xgmii_txc       => xgmii_txc,
            xgmii_rxd       => xgmii_rxd,
            xgmii_rxc       => xgmii_rxc,
            xgmii_rx_valid  => xgmii_rx_valid,
            gtx_tx_data     => gtx_tx_data,
            gtx_tx_header   => gtx_tx_header,
            gtx_tx_valid    => open,
            gtx_rx_data     => gtx_rx_data,
            gtx_rx_header   => gtx_rx_header,
            gtx_rx_valid    => gtx_rx_datavalid,
            gtx_rx_header_valid => gtx_rx_valid,
            gtx_rx_slip     => gtx_rx_slip,
            pcs_block_lock  => pcs_block_lock_int,
            pcs_rx_sync     => open,
            pcs_tx_error    => open,
            pcs_rx_error    => open,
            pcs_hi_ber      => pcs_hi_ber_int,
            debug_tx_enc_error  => open,
            debug_rx_dec_error  => open,
            debug_header_errors => open,
            debug_block_state   => pcs_block_state_int,
            debug_ctrl_block_cnt => open,
            debug_data_block_cnt => open,
            debug_last_block_type => open,
            debug_hi_ber        => open,
            debug_tx_enc_header  => open,
            debug_tx_enc_type    => open,
            debug_tx_scram_header => open,
            debug_tx_header_raw  => open,
            debug_tx_gtx_data_hi => open,
            debug_tx_gtx_data_lo => open,
            debug_tx_block_cnt   => open,
            debug_tx_xgmii_ctrl  => open,
            debug_rx_header_value => open,
            debug_rx_header_raw   => open,
            debug_slip_count      => open,
            debug_rx_data_hi       => open,
            debug_rx_data_lo       => open,
            debug_rx_data_raw_hi   => open,
            debug_rx_data_raw_mid  => open,
            debug_rx_data_raw_lo   => open,
            debug_block_type_byte0 => open,
            debug_block_type_byte7 => open,
            debug_fsm_valid_cnt   => open,
            debug_fsm_invalid_cnt => open,
            debug_fsm_window_cnt  => open,
            debug_descram_sync    => open,
            debug_descram_data_hi => open,
            debug_descram_data_lo => open,
            debug_decoder_error   => open,
            debug_decoder_data_hi => open,
            debug_decoder_data_lo => open
        );

    ----------------------------------------------------------------------------
    -- MAC Parser
    ----------------------------------------------------------------------------
    mac_parser_inst : entity work.mac_parser_xgmii
        port map (
            clk                 => tx_clk_int,
            rst                 => mac_rst,
            xgmii_rxd           => xgmii_rxd,
            xgmii_rxc           => xgmii_rxc,
            xgmii_rx_valid      => xgmii_rx_valid,
            ip_payload_valid    => ip_payload_valid,
            ip_payload_data     => ip_payload_data,
            ip_payload_start    => ip_payload_start,
            ip_payload_end      => ip_payload_end,
            ip_protocol         => ip_protocol,
            ip_src_addr         => open,
            ip_dst_addr         => open,
            eth_dst_mac         => open,
            eth_src_mac         => open,
            eth_type            => open,
            frame_valid         => open,
            frame_error         => open,
            crc_error           => open,
            frame_count         => mac_frame_count,
            error_count         => open,
            start_detect_count  => mac_start_detect
        );

    ----------------------------------------------------------------------------
    -- UDP Header Stripper + Port Filter
    -- MAC parser outputs IP payload which INCLUDES the 8-byte UDP header.
    -- MoldUDP64 handler expects pure UDP payload (without UDP header).
    -- This process:
    --   1. Strips the 8-byte UDP header (src_port, dst_port, length, checksum)
    --   2. Only forwards packets to ITCH port (filters broadcast/mDNS/SSDP)
    --   3. Only processes UDP protocol (ip_protocol = 0x11)
    --
    -- UDP Header (8 bytes):
    --   Bytes 0-1: Source Port
    --   Bytes 2-3: Destination Port
    --   Bytes 4-5: Length
    --   Bytes 6-7: Checksum
    ----------------------------------------------------------------------------
    process(tx_clk_int)
    begin
        if rising_edge(tx_clk_int) then
            if pcs_rst = '1' then
                udp_byte_cnt <= (others => '0');
                udp_parsing <= '0';
                udp_forwarding <= '0';
                udp_first_byte <= '0';
                udp_dst_port_hi <= (others => '0');
                udp_port_match <= '0';
                udp_payload_valid_i <= '0';
                udp_payload_data_i <= (others => '0');
                udp_payload_start_i <= '0';
                udp_payload_end_i <= '0';
            else
                -- Default: pulse signals clear each cycle
                udp_payload_valid_i <= '0';
                udp_payload_start_i <= '0';
                udp_payload_end_i <= '0';

                -- New IP payload arriving (any IP protocol — port filter handles UDP selection)
                if ip_payload_start = '1' and ip_payload_valid = '1' then
                    -- Byte 0: UDP src port high byte (skip)
                    udp_byte_cnt <= to_unsigned(1, 4);
                    udp_parsing <= '1';
                    udp_forwarding <= '0';
                    udp_first_byte <= '0';
                    udp_port_match <= '0';
                elsif ip_payload_valid = '1' and udp_parsing = '1' and udp_forwarding = '0' then
                    -- Still consuming UDP header bytes
                    if udp_byte_cnt < 15 then
                        udp_byte_cnt <= udp_byte_cnt + 1;
                    end if;

                    case to_integer(udp_byte_cnt) is
                        when 2 =>  -- Byte 2: dst port high byte
                            udp_dst_port_hi <= ip_payload_data;
                        when 3 =>  -- Byte 3: dst port low byte — check match
                            if udp_dst_port_hi = ITCH_UDP_PORT(15 downto 8) and
                               ip_payload_data = ITCH_UDP_PORT(7 downto 0) then
                                udp_port_match <= '1';
                            end if;
                        when 7 =>  -- Byte 7: checksum low (last header byte)
                            if udp_port_match = '1' then
                                udp_forwarding <= '1';
                                udp_first_byte <= '1';
                            else
                                udp_parsing <= '0';  -- Wrong port, ignore rest
                            end if;
                        when others => null;
                    end case;
                end if;

                -- Forward UDP payload bytes (byte 8+) to MoldUDP64
                if ip_payload_valid = '1' and udp_forwarding = '1' then
                    udp_payload_valid_i <= '1';
                    udp_payload_data_i <= ip_payload_data;
                    if udp_first_byte = '1' then
                        udp_payload_start_i <= '1';
                        udp_first_byte <= '0';
                    end if;
                end if;

                -- End of IP payload
                if ip_payload_end = '1' then
                    if udp_forwarding = '1' then
                        udp_payload_end_i <= '1';
                    end if;
                    udp_parsing <= '0';
                    udp_forwarding <= '0';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Debug: Capture first 8 bytes entering MoldUDP64 (after UDP header strip)
    -- Should show MoldUDP64 session ID bytes if UDP strip is correct.
    -- If shows UDP header bytes instead, the stripper has a bug.
    ----------------------------------------------------------------------------
    process(tx_clk_int)
    begin
        if rising_edge(tx_clk_int) then
            if pcs_rst = '1' then
                mold_input_capture <= (others => '0');
                mold_input_byte_cnt <= (others => '0');
                mold_input_active <= '0';
            else
                if udp_payload_start_i = '1' and udp_payload_valid_i = '1' then
                    mold_input_capture(63 downto 56) <= udp_payload_data_i;
                    mold_input_byte_cnt <= to_unsigned(1, 4);
                    mold_input_active <= '1';
                elsif mold_input_active = '1' and udp_payload_valid_i = '1' then
                    case to_integer(mold_input_byte_cnt) is
                        when 1 => mold_input_capture(55 downto 48) <= udp_payload_data_i;
                        when 2 => mold_input_capture(47 downto 40) <= udp_payload_data_i;
                        when 3 => mold_input_capture(39 downto 32) <= udp_payload_data_i;
                        when 4 => mold_input_capture(31 downto 24) <= udp_payload_data_i;
                        when 5 => mold_input_capture(23 downto 16) <= udp_payload_data_i;
                        when 6 => mold_input_capture(15 downto 8) <= udp_payload_data_i;
                        when 7 =>
                            mold_input_capture(7 downto 0) <= udp_payload_data_i;
                            mold_input_active <= '0';
                        when others => null;
                    end case;
                    mold_input_byte_cnt <= mold_input_byte_cnt + 1;
                end if;
                if udp_payload_end_i = '1' then
                    mold_input_active <= '0';
                end if;
            end if;
        end if;
    end process;

    debug_mold_input_bytes <= mold_input_capture;

    ----------------------------------------------------------------------------
    -- MoldUDP64 Handler
    ----------------------------------------------------------------------------
    moldudp64_inst : entity work.moldudp64_handler
        port map (
            clk                 => tx_clk_int,
            rst                 => pcs_rst,
            udp_payload_valid   => udp_payload_valid_i,
            udp_payload_data    => udp_payload_data_i,
            udp_payload_start   => udp_payload_start_i,
            udp_payload_end     => udp_payload_end_i,
            itch_msg_valid      => mold_itch_valid,
            itch_msg_data       => mold_itch_data,
            itch_msg_start      => mold_itch_start,
            itch_msg_end        => mold_itch_end,
            session_id          => open,
            sequence_number     => open,
            message_count       => open,
            session_valid       => open,
            sequence_gap        => open,
            gap_count           => open,
            packet_count        => mold_packet_count,
            msg_extracted       => mold_msg_extracted
        );

end rtl;
