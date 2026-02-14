--------------------------------------------------------------------------------
-- Module: async_fifo_itch
-- Description: XPM-based async FIFO for ITCH CDC path
--              Uses xpm_fifo_async to directly instantiate BRAM primitives,
--              bypassing Vivado inference engine which refuses BRAM for this
--              specific data path (Bug 8 - exhaustively tested, no RTL fix found)
--
-- Port interface matches async_fifo.vhd for drop-in replacement
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

library xpm;
use xpm.vcomponents.all;

entity async_fifo_itch is
    Generic (
        DATA_WIDTH : integer := 480;
        FIFO_DEPTH : integer := 256  -- Must be power of 2, minimum 16
    );
    Port (
        -- Write clock domain
        wr_clk   : in  std_logic;
        wr_rst   : in  std_logic;
        wr_en    : in  std_logic;
        wr_data  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        wr_full  : out std_logic;

        -- Read clock domain
        rd_clk   : in  std_logic;
        rd_rst   : in  std_logic;
        rd_en    : in  std_logic;
        rd_data  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        rd_empty : out std_logic
    );
end async_fifo_itch;

architecture Behavioral of async_fifo_itch is

    -- Calculate count width from depth
    constant COUNT_WIDTH : integer := integer(ceil(log2(real(FIFO_DEPTH)))) + 1;
     
begin

    xpm_fifo_inst : xpm_fifo_async
        generic map (
            CASCADE_HEIGHT      => 0,              -- Auto
            CDC_SYNC_STAGES     => 2,              -- 2-stage CDC (standard)
            DOUT_RESET_VALUE    => "0",
            ECC_MODE            => "no_ecc",
            FIFO_MEMORY_TYPE    => "block",        -- Forces BRAM - bypasses inference
            FIFO_READ_LATENCY   => 1,              -- 1 cycle read latency (matches async_fifo)
            FIFO_WRITE_DEPTH    => FIFO_DEPTH,
            FULL_RESET_VALUE    => 0,
            PROG_EMPTY_THRESH   => 10,
            PROG_FULL_THRESH    => 10,
            RD_DATA_COUNT_WIDTH => COUNT_WIDTH,
            READ_DATA_WIDTH     => DATA_WIDTH,
            READ_MODE           => "std",          -- Standard read (matches async_fifo behavior)
            RELATED_CLOCKS      => 0,              -- Independent clocks
            SIM_ASSERT_CHK      => 0,
            USE_ADV_FEATURES    => "0000",         -- No advanced features
            WAKEUP_TIME         => 0,
            WRITE_DATA_WIDTH    => DATA_WIDTH,
            WR_DATA_COUNT_WIDTH => COUNT_WIDTH
        )
        port map (
            -- Write side
            wr_clk         => wr_clk,
            wr_en          => wr_en,
            din            => wr_data,
            full           => wr_full,

            -- Read side
            rd_clk         => rd_clk,
            rd_en          => rd_en,
            dout           => rd_data,
            empty          => rd_empty,

            -- Reset (XPM uses single async reset for both domains)
            rst            => wr_rst,

            -- Unused inputs
            sleep          => '0',
            injectsbiterr  => '0',
            injectdbiterr  => '0',

            -- Unused outputs
            wr_rst_busy    => open,
            rd_rst_busy    => open,
            wr_ack         => open,
            overflow       => open,
            underflow      => open,
            wr_data_count  => open,
            rd_data_count  => open,
            prog_full      => open,
            prog_empty     => open,
            almost_full    => open,
            almost_empty   => open,
            sbiterr        => open,
            dbiterr        => open
        );
 
end Behavioral;
