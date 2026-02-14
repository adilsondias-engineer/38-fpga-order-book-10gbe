--------------------------------------------------------------------------------
-- Package: order_book_pkg
-- Description: Constants, types, and functions for hardware order book
--
-- Adapted from Project 20 for 10GbE integration (Project 38)
-- Adds 4-point timestamp support for latency measurement
--
-- BBO Data Format (44 bytes payload):
--   Symbol:     8 bytes ASCII (space-padded)
--   Bid Price:  4 bytes big-endian (divide by 10000 for dollars)
--   Bid Shares: 4 bytes big-endian
--   Ask Price:  4 bytes big-endian (divide by 10000 for dollars)
--   Ask Shares: 4 bytes big-endian
--   Spread:     4 bytes big-endian (divide by 10000 for dollars)
--   T1:         4 bytes timestamp (ITCH parse start)
--   T2:         4 bytes timestamp (CDC FIFO write)
--   T3:         4 bytes timestamp (BBO FIFO read)
--   T4:         4 bytes timestamp (UDP TX start)
--
-- Timestamps are 125 MHz cycle counts (8 ns per cycle)
--
-- ==============================================================================
-- Copyright 2026 Adilson Dias
--
-- Licensed under the Apache License, Version 2.0
-- ==============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package order_book_pkg is

    ------------------------------------------------------------------------
    -- Configuration Constants
    ------------------------------------------------------------------------

    -- Default target symbol
    constant TARGET_SYMBOL      : std_logic_vector(63 downto 0) := x"4141504C20202020";  -- "AAPL    "
    constant ENABLE_ORDER_BOOK  : boolean := true;

    -- Order storage configuration
    constant MAX_ORDERS         : integer := 1024;  -- Max concurrent orders per symbol
    constant ORDER_ADDR_WIDTH   : integer := 10;    -- log2(MAX_ORDERS) = 10 bits

    -- Price level configuration
    constant MAX_PRICE_LEVELS   : integer := 256;   -- 128 bids + 128 asks
    constant PRICE_ADDR_WIDTH   : integer := 8;      -- log2(MAX_PRICE_LEVELS) = 8 bits
    constant MAX_BID_LEVELS     : integer := 128;    -- Addresses 0-127
    constant MAX_ASK_LEVELS     : integer := 128;    -- Addresses 128-255

    -- BBO tracking configuration
    -- CRITICAL: With XOR hash, prices are distributed across ALL addresses.
    -- Must scan ALL levels to find best bid/ask, not just sequential addresses.
    constant BBO_SCAN_DEPTH     : integer := 64;   -- Scan all 128 levels per side

    -- Data width constants
    constant SYMBOL_WIDTH       : integer := 64;    -- 8 bytes = 64 bits
    constant PRICE_WIDTH        : integer := 32;    -- 4 bytes = 32 bits
    constant SHARES_WIDTH       : integer := 32;    -- 4 bytes = 32 bits
    constant TIMESTAMP_WIDTH    : integer := 32;    -- 4 bytes = 32 bits

    -- BBO payload constants
    constant BBO_PAYLOAD_BYTES  : integer := 44;    -- Full payload with timestamps
    constant BBO_PAYLOAD_BASIC  : integer := 28;    -- Basic payload without timestamps

    ------------------------------------------------------------------------
    -- Data Structure Types
    ------------------------------------------------------------------------

    -- Order Entry (stored in BRAM)
    -- Total: 130 bits (fits in dual 36Kb BRAM with width=130)
    type order_entry_t is record
        order_ref   : std_logic_vector(63 downto 0);  -- Unique order ID
        price       : std_logic_vector(31 downto 0);  -- 4-byte fixed point
        shares      : std_logic_vector(31 downto 0);  -- Remaining shares
        side        : std_logic;                      -- 0=Buy, 1=Sell
        valid       : std_logic;                      -- Order exists?
    end record;

    -- Price Level Entry (stored in BRAM)
    -- Total: 82 bits
    type price_level_t is record
        price           : std_logic_vector(31 downto 0);  -- Price level
        total_shares    : std_logic_vector(31 downto 0);  -- Aggregated shares
        order_count     : std_logic_vector(15 downto 0);  -- Number of orders
        side            : std_logic;                      -- 0=Buy, 1=Sell
        valid           : std_logic;                      -- Level has orders?
    end record;

    -- BBO (Best Bid/Offer) Output
    type bbo_t is record
        symbol          : std_logic_vector(63 downto 0);  -- Stock ticker
        bid_price       : std_logic_vector(31 downto 0);
        bid_shares      : std_logic_vector(31 downto 0);
        ask_price       : std_logic_vector(31 downto 0);
        ask_shares      : std_logic_vector(31 downto 0);
        spread          : std_logic_vector(31 downto 0);  -- ask - bid
        valid           : std_logic;                      -- BBO available?
    end record;

    constant BBO_INVALID : bbo_t := (
        symbol      => (others => '0'),
        bid_price   => (others => '0'),
        bid_shares  => (others => '0'),
        ask_price   => (others => '1'),  -- Max value (no ask)
        ask_shares  => (others => '0'),
        spread      => (others => '1'),
        valid       => '0'
    );

    -- 4-point timestamp record (Project 38 addition)
    type timestamps_t is record
        t1          : std_logic_vector(TIMESTAMP_WIDTH-1 downto 0);  -- ITCH parse start
        t2          : std_logic_vector(TIMESTAMP_WIDTH-1 downto 0);  -- CDC FIFO write
        t3          : std_logic_vector(TIMESTAMP_WIDTH-1 downto 0);  -- BBO FIFO read
        t4          : std_logic_vector(TIMESTAMP_WIDTH-1 downto 0);  -- UDP TX start
    end record;

    -- Latency statistics record (Project 38 addition)
    type latency_stats_t is record
        last_ns     : std_logic_vector(31 downto 0);
        min_ns      : std_logic_vector(31 downto 0);
        max_ns      : std_logic_vector(31 downto 0);
    end record;

    ------------------------------------------------------------------------
    -- Order Book Statistics
    ------------------------------------------------------------------------

    type order_book_stats_t is record
        total_orders        : unsigned(15 downto 0);  -- Total active orders
        bid_order_count     : unsigned(15 downto 0);  -- Active buy orders
        ask_order_count     : unsigned(15 downto 0);  -- Active sell orders
        bid_level_count     : unsigned(7 downto 0);   -- Active bid levels
        ask_level_count     : unsigned(7 downto 0);   -- Active ask levels
        add_count           : unsigned(31 downto 0);  -- Lifetime adds
        execute_count       : unsigned(31 downto 0);  -- Lifetime executions
        cancel_count        : unsigned(31 downto 0);  -- Lifetime cancels
        delete_count        : unsigned(31 downto 0);  -- Lifetime deletes
        replace_count       : unsigned(31 downto 0);  -- Lifetime replaces
    end record;

    ------------------------------------------------------------------------
    -- ITCH Message Type Constants
    ------------------------------------------------------------------------

    constant ITCH_ADD_ORDER      : std_logic_vector(7 downto 0) := x"41";  -- 'A'
    constant ITCH_ADD_ORDER_MPID : std_logic_vector(7 downto 0) := x"46";  -- 'F'
    constant ITCH_EXECUTE        : std_logic_vector(7 downto 0) := x"45";  -- 'E'
    constant ITCH_EXECUTE_PRICE  : std_logic_vector(7 downto 0) := x"43";  -- 'C'
    constant ITCH_CANCEL         : std_logic_vector(7 downto 0) := x"58";  -- 'X'
    constant ITCH_DELETE         : std_logic_vector(7 downto 0) := x"44";  -- 'D'
    constant ITCH_REPLACE        : std_logic_vector(7 downto 0) := x"55";  -- 'U'

    ------------------------------------------------------------------------
    -- Timing Constants
    ------------------------------------------------------------------------

    constant NS_PER_CYCLE_125MHZ : integer := 8;      -- 125 MHz = 8 ns per cycle
    constant NS_PER_CYCLE_161MHZ : real := 6.21;      -- 161.13 MHz = 6.21 ns per cycle

    ------------------------------------------------------------------------
    -- Conversion Functions (for BRAM storage)
    ------------------------------------------------------------------------

    -- Order entry conversion
    function order_to_slv(order : order_entry_t) return std_logic_vector;
    function slv_to_order(slv : std_logic_vector(129 downto 0)) return order_entry_t;

    -- Price level conversion
    function price_level_to_slv(level : price_level_t) return std_logic_vector;
    function slv_to_price_level(slv : std_logic_vector(81 downto 0)) return price_level_t;

    ------------------------------------------------------------------------
    -- Helper Functions
    ------------------------------------------------------------------------

    -- Price comparison (fixed-point)
    function price_greater_than(a, b : std_logic_vector(31 downto 0)) return boolean;
    function price_less_than(a, b : std_logic_vector(31 downto 0)) return boolean;
    function price_equal(a, b : std_logic_vector(31 downto 0)) return boolean;

    -- Shares arithmetic (prevent underflow)
    function shares_subtract(
        current : std_logic_vector(31 downto 0);
        amount  : std_logic_vector(31 downto 0)
    ) return std_logic_vector;

    -- Order reference hash (for BRAM addressing)
    function hash_order_ref(order_ref : std_logic_vector(63 downto 0))
        return std_logic_vector;

    -- Price to address mapping
    function price_to_addr(
        price : std_logic_vector(31 downto 0);
        side  : std_logic
    ) return std_logic_vector;

    -- Symbol conversion
    function symbol_to_slv(s : string) return std_logic_vector;
    function price_to_slv(price : integer) return std_logic_vector;

end package order_book_pkg;

package body order_book_pkg is

    ------------------------------------------------------------------------
    -- Order Entry Conversion Functions
    ------------------------------------------------------------------------

    function order_to_slv(order : order_entry_t) return std_logic_vector is
        variable slv : std_logic_vector(129 downto 0);
    begin
        slv(129)           := order.valid;
        slv(128)           := order.side;
        slv(127 downto 96) := order.shares;
        slv(95 downto 64)  := order.price;
        slv(63 downto 0)   := order.order_ref;
        return slv;
    end function;

    function slv_to_order(slv : std_logic_vector(129 downto 0)) return order_entry_t is
        variable order : order_entry_t;
    begin
        order.valid     := slv(129);
        order.side      := slv(128);
        order.shares    := slv(127 downto 96);
        order.price     := slv(95 downto 64);
        order.order_ref := slv(63 downto 0);
        return order;
    end function;

    ------------------------------------------------------------------------
    -- Price Level Conversion Functions
    ------------------------------------------------------------------------

    function price_level_to_slv(level : price_level_t) return std_logic_vector is
        variable slv : std_logic_vector(81 downto 0);
    begin
        slv(81)           := level.valid;
        slv(80)           := level.side;
        slv(79 downto 64) := level.order_count;
        slv(63 downto 32) := level.total_shares;
        slv(31 downto 0)  := level.price;
        return slv;
    end function;

    function slv_to_price_level(slv : std_logic_vector(81 downto 0)) return price_level_t is
        variable level : price_level_t;
    begin
        level.valid        := slv(81);
        level.side         := slv(80);
        level.order_count  := slv(79 downto 64);
        level.total_shares := slv(63 downto 32);
        level.price        := slv(31 downto 0);
        return level;
    end function;

    ------------------------------------------------------------------------
    -- Price Comparison Functions
    ------------------------------------------------------------------------

    function price_greater_than(a, b : std_logic_vector(31 downto 0)) return boolean is
    begin
        return unsigned(a) > unsigned(b);
    end function;

    function price_less_than(a, b : std_logic_vector(31 downto 0)) return boolean is
    begin
        return unsigned(a) < unsigned(b);
    end function;

    function price_equal(a, b : std_logic_vector(31 downto 0)) return boolean is
    begin
        return a = b;
    end function;

    ------------------------------------------------------------------------
    -- Shares Arithmetic
    ------------------------------------------------------------------------

    function shares_subtract(
        current : std_logic_vector(31 downto 0);
        amount  : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable result : unsigned(31 downto 0);
    begin
        if unsigned(current) >= unsigned(amount) then
            result := unsigned(current) - unsigned(amount);
        else
            result := (others => '0');  -- Prevent underflow
        end if;
        return std_logic_vector(result);
    end function;

    ------------------------------------------------------------------------
    -- Addressing Functions
    ------------------------------------------------------------------------

    function hash_order_ref(order_ref : std_logic_vector(63 downto 0))
        return std_logic_vector is
    begin
        -- Simple hash: Use lower 10 bits as address
        return order_ref(ORDER_ADDR_WIDTH-1 downto 0);
    end function;

    function price_to_addr(
        price : std_logic_vector(31 downto 0);
        side  : std_logic
    ) return std_logic_vector is
        variable addr : unsigned(PRICE_ADDR_WIDTH-1 downto 0);
        variable price_bits : unsigned(6 downto 0);
        variable upper_bits : unsigned(6 downto 0);
        variable lower_bits : unsigned(6 downto 0);
        variable hash_bits : unsigned(6 downto 0);
    begin
        -- Improved price-to-address mapping with XOR folding (from Project 23)
        -- Previous version used bits 31:25 which are zero for prices <$200
        -- causing massive collisions where all orders went to address 0.
        --
        -- XOR folding: combine bits 20:14 with bits 13:7 for better distribution
        -- This handles typical stock prices ($10-$2000) effectively.
        --
        -- Price examples (4 decimal fixed-point, ITCH format):
        --   $10.00  = 100,000   = 0x000186A0 -> hash varies
        --   $150.00 = 1,500,000 = 0x0016E360 -> hash varies
        --   $500.00 = 5,000,000 = 0x004C4B40 -> hash varies
        --
        upper_bits := unsigned(price(20 downto 14));
        lower_bits := unsigned(price(13 downto 7));
        hash_bits := upper_bits xor lower_bits;

        -- Take 7 bits of hash for 128-entry table per side
        price_bits := hash_bits(6 downto 0);

        if side = '0' then
            -- Buy: Map to [0-127]
            addr := resize(price_bits, PRICE_ADDR_WIDTH);
        else
            -- Sell: Map to [128-255]
            addr := resize(price_bits, PRICE_ADDR_WIDTH) + to_unsigned(128, PRICE_ADDR_WIDTH);
        end if;

        return std_logic_vector(addr);
    end function;

    ------------------------------------------------------------------------
    -- Symbol Conversion Functions
    ------------------------------------------------------------------------

    function symbol_to_slv(s : string) return std_logic_vector is
        variable result : std_logic_vector(63 downto 0) := (others => '0');
        variable byte_idx : integer;
    begin
        for i in 1 to 8 loop
            byte_idx := (8 - i) * 8;
            if i <= s'length then
                result(byte_idx + 7 downto byte_idx) :=
                    std_logic_vector(to_unsigned(character'pos(s(i)), 8));
            else
                result(byte_idx + 7 downto byte_idx) := x"20";  -- Space pad
            end if;
        end loop;
        return result;
    end function;

    function price_to_slv(price : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(price, 32));
    end function;

end package body order_book_pkg;
