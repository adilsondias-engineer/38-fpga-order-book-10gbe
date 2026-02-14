--------------------------------------------------------------------------------
-- Module: multi_symbol_order_book
-- Description: Multi-symbol order book wrapper
--              Instantiates 8 order book managers (one per symbol)
--              Routes ITCH messages based on symbol matching
--              Arbitrates BBO outputs using round-robin scheduling
--
-- Adapted from Project 20 for 10GbE integration (Project 38)
--
-- Supported Symbols: AAPL, TSLA, SPY, QQQ, GOOGL, MSFT, AMZN, NVDA
--
-- Resource Usage: ~32 RAMB36 tiles (4% of Kintex-7 325T capacity)
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
use work.symbol_filter_pkg.all;

entity multi_symbol_order_book is
    port (
        clk                 : in  std_logic;
        reset               : in  std_logic;

        -- ITCH message inputs (from parser)
        msg_valid           : in  std_logic;
        msg_type            : in  std_logic_vector(7 downto 0);
        stock_symbol        : in  std_logic_vector(63 downto 0);
        order_ref           : in  std_logic_vector(63 downto 0);
        buy_sell            : in  std_logic;
        shares              : in  std_logic_vector(31 downto 0);
        price               : in  std_logic_vector(31 downto 0);

        -- Execute/Cancel/Replace fields (from parser via CDC FIFO)
        exec_shares         : in  std_logic_vector(31 downto 0);
        cancel_shares       : in  std_logic_vector(31 downto 0);
        new_order_ref       : in  std_logic_vector(63 downto 0);
        new_price           : in  std_logic_vector(31 downto 0);
        new_shares          : in  std_logic_vector(31 downto 0);

        -- BBO output (round-robin through symbols)
        bbo_update          : out std_logic;
        bbo_symbol          : out std_logic_vector(63 downto 0);
        bbo_valid           : out std_logic;
        bid_price           : out std_logic_vector(31 downto 0);
        bid_shares          : out std_logic_vector(31 downto 0);
        ask_price           : out std_logic_vector(31 downto 0);
        ask_shares          : out std_logic_vector(31 downto 0);
        spread              : out std_logic_vector(31 downto 0)

        -- Note: Timestamps are captured at CDC FIFO boundaries in top-level
        -- per Project 23 architecture (T1/T2 in rx_clk, T3/T4 in tx_clk)
    );
end multi_symbol_order_book;

architecture rtl of multi_symbol_order_book is

    -- Number of symbols
    constant NUM_SYMBOLS : integer := MAX_SYMBOLS;  -- 8

    -- Symbol match signals
    signal symbol_match : std_logic_vector(NUM_SYMBOLS-1 downto 0);

    -- Per-symbol message valid signals
    type msg_valid_array is array (0 to NUM_SYMBOLS-1) of std_logic;
    signal book_msg_valid : msg_valid_array;

    -- Per-symbol BBO outputs
    type bbo_update_array is array (0 to NUM_SYMBOLS-1) of std_logic;
    type bbo_data_array is array (0 to NUM_SYMBOLS-1) of bbo_t;
    type stats_array is array (0 to NUM_SYMBOLS-1) of order_book_stats_t;
    type ready_array is array (0 to NUM_SYMBOLS-1) of std_logic;

    signal bbo_update_vec  : bbo_update_array;
    signal bbo_data_vec    : bbo_data_array;
    signal stats_vec       : stats_array;
    signal ready_vec       : ready_array;

    -- BBO arbiter
    signal current_symbol  : integer range 0 to NUM_SYMBOLS-1 := 0;
    signal arbiter_counter : unsigned(9 downto 0) := (others => '0');

    -- PIPELINE STAGE 1: Replicated registers (reduce fanout)
  --  signal current_symbol_match : integer range 0 to NUM_SYMBOLS-1 := 0;
  --  signal current_symbol_storage :integer range 0 to NUM_SYMBOLS-1 := 0;
  --  signal current_symbol_output : integer range 0 to NUM_SYMBOLS-1 := 0;
    

    -- Previous BBO state (for change detection per symbol)
    type prev_bbo_array is array (0 to NUM_SYMBOLS-1) of bbo_t;
    signal prev_bbo : prev_bbo_array;

    -- Pipeline stage 1: comparison results (registered to meet timing)
    signal pipe_changed     : std_logic := '0';
    signal pipe_symbol_idx  : integer range 0 to NUM_SYMBOLS-1 := 0;
    signal pipe_bbo_data    : bbo_t;

    -- Polarity inversion for ITCH side
    signal itch_side_inverted : std_logic;

    -- Force replication
--    attribute MAX_FANOUT : integer;
--    attribute MAX_FANOUT of current_symbol: signal is 16;
--    attribute MAX_FANOUT of pipe_bbo_data : signal is 16;
--    attribute MAX_FANOUT of pipe_symbol_idx : signal is 16;
--    attribute MAX_FANOUT of pipe_changed : signal is 16;
--    attribute MAX_FANOUT of itch_side_inverted : signal is 16;
--    attribute MAX_FANOUT of prev_bbo : signal is 16;
--    attribute MAX_FANOUT of arbiter_counter : signal is 16;
--    attribute MAX_FANOUT of stats_vec : signal is 16;
    
    signal symbol_select : std_logic_vector(NUM_SYMBOLS-1 downto 0);
    
    -- Captured BBO per symbol (registered on selection)
    signal selected_bbo_current : bbo_t;
    signal selected_bbo_prev : bbo_t; 

begin

    -- Invert buy_sell polarity for order book managers
    itch_side_inverted <= not buy_sell;

    ----------------------------------------------------------------------------
    -- Symbol Demultiplexer
    -- When ENABLE_SYMBOL_FILTER is false, route ALL messages to book 0
    -- This allows testing without matching specific symbols
    ----------------------------------------------------------------------------
    process(stock_symbol)
    begin
        symbol_match <= (others => '0');

        if not ENABLE_SYMBOL_FILTER then
            -- Bypass mode: route all messages to first order book (index 0)
            -- This allows testing with any symbol data
            symbol_match(0) <= '1';
        else
            -- Normal mode: match against filter list
            for i in 0 to NUM_SYMBOLS-1 loop
                if stock_symbol = FILTER_SYMBOL_LIST(i) then
                    symbol_match(i) <= '1';
                end if;
            end loop;
        end if;
    end process;

    -- Route msg_valid to matched order book
    gen_msg_valid: for i in 0 to NUM_SYMBOLS-1 generate
        book_msg_valid(i) <= msg_valid when symbol_match(i) = '1' else '0';
    end generate;

    ----------------------------------------------------------------------------
    -- Order Book Instances (one per symbol)
    ----------------------------------------------------------------------------
    gen_order_books: for i in 0 to NUM_SYMBOLS-1 generate
        book_inst: entity work.order_book_manager
            generic map (
                TARGET_SYMBOL => FILTER_SYMBOL_LIST(i)
            )
            port map (
                clk => clk,
                rst => reset,

                itch_valid          => book_msg_valid(i),
                itch_msg_type       => msg_type,
                itch_order_ref      => order_ref,
                itch_symbol         => stock_symbol,
                itch_side           => itch_side_inverted,
                itch_shares         => shares,
                itch_price          => price,
                itch_exec_shares    => exec_shares,
                itch_cancel_shares  => cancel_shares,
                itch_new_order_ref  => new_order_ref,
                itch_new_price      => new_price,
                itch_new_shares     => new_shares,

                bbo                 => bbo_data_vec(i),
                bbo_update          => bbo_update_vec(i),
                stats               => stats_vec(i),
                ready               => ready_vec(i)
            );
    end generate;

    ----------------------------------------------------------------------------
    -- BBO Arbiter (Round-Robin with Change Detection)
    -- 2-stage pipeline to meet 200 MHz timing:
    --   Stage 1 (counter=999): Compare BBO, register result
    --   Stage 2 (next cycle): Output update, write prev_bbo
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                current_symbol <= 0;
                symbol_select <= (0 => '1', others => '0');
                
                arbiter_counter <= (others => '0');
                bbo_update <= '0';
                pipe_changed <= '0';
                pipe_symbol_idx <= 0;

                for i in 0 to NUM_SYMBOLS-1 loop
                    prev_bbo(i).valid <= '0';
                    prev_bbo(i).bid_price <= (others => '0');
                    prev_bbo(i).bid_shares <= (others => '0');
                    prev_bbo(i).ask_price <= (others => '1');
                    prev_bbo(i).ask_shares <= (others => '0');
                    prev_bbo(i).spread <= (others => '0');
                end loop;

            else
                -- Stage 3: Output BBO update and write prev_bbo (from previous cycle's comparison)
                bbo_update <= '0';
                if pipe_changed = '1' then
                    bbo_update <= '1';
                    bbo_symbol <= FILTER_SYMBOL_LIST(pipe_symbol_idx);
                    bbo_valid <= pipe_bbo_data.valid;
                    bid_price <= pipe_bbo_data.bid_price;
                    bid_shares <= pipe_bbo_data.bid_shares;
                    ask_price <= pipe_bbo_data.ask_price;
                    ask_shares <= pipe_bbo_data.ask_shares;
                    spread <= pipe_bbo_data.spread;
                    prev_bbo(pipe_symbol_idx) <= pipe_bbo_data;
                end if;

                -- Stage 2: Compare and register result
                pipe_changed <= '0';  -- Default: no change

                if (selected_bbo_current.valid /= selected_bbo_prev.valid) or
                   (selected_bbo_current.bid_price /= selected_bbo_prev.bid_price) or
                   (selected_bbo_current.bid_shares /= selected_bbo_prev.bid_shares) or
                   (selected_bbo_current.ask_price /= selected_bbo_prev.ask_price) or
                   (selected_bbo_current.ask_shares /= selected_bbo_prev.ask_shares) or
                   (selected_bbo_current.spread /= selected_bbo_prev.spread) then
                    pipe_changed <= '1';
                    pipe_symbol_idx <= current_symbol;
                    pipe_bbo_data <= selected_bbo_current;
                end if;

                -- Stage 1: Capture selected BBO using one-hot decode
                if arbiter_counter = 999 then
                    arbiter_counter <= (others => '0');

                    -- Advance to next symbol
                    if current_symbol = NUM_SYMBOLS-1 then
                        current_symbol <= 0;
                        symbol_select <= (0 => '1', others => '0');
                    else
                        current_symbol <= current_symbol + 1;
                        symbol_select <= symbol_select(NUM_SYMBOLS-2 downto 0) & '0';
                        symbol_select(current_symbol + 1) <= '1';
                    end if;

                    -- Use one-hot select (OR tree, not MUX!)
                    selected_bbo_current.valid <= '0';
                    selected_bbo_current.bid_price <= (others => '0');
                    selected_bbo_current.bid_shares <= (others => '0');
                    selected_bbo_current.ask_price <= (others => '0');
                    selected_bbo_current.ask_shares <= (others => '0');
                    selected_bbo_current.spread <= (others => '0');
                    
                    selected_bbo_prev.valid <= '0';
                    selected_bbo_prev.bid_price <= (others => '0');
                    selected_bbo_prev.bid_shares <= (others => '0');
                    selected_bbo_prev.ask_price <= (others => '0');
                    selected_bbo_prev.ask_shares <= (others => '0');
                    selected_bbo_prev.spread <= (others => '0');
                    
                    for i in 0 to NUM_SYMBOLS-1 loop
                        if symbol_select(i) = '1' then
                            selected_bbo_current <= bbo_data_vec(i);
                            selected_bbo_prev <= prev_bbo(i);
                        end if;
                    end loop;

                else
                    arbiter_counter <= arbiter_counter + 1;
                end if;

            end if;
        end if;
    end process;

end rtl;
