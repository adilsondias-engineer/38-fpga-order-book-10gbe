--------------------------------------------------------------------------------
-- Package: symbol_filter_pkg
-- Description: Symbol routing package for multi-symbol order book
--              Maps each symbol to a dedicated order book instance (0-7)
--
-- WARNING: Symbol filtering MUST remain enabled. When disabled, all messages
--          route to order book instance 0 regardless of symbol. This corrupts
--          the book state with mixed-symbol orders and produces invalid BBO.
--          The "filter" is actually the routing mechanism for multi-symbol
--          operation — it is NOT optional.
--
-- Adapted from Project 20 for 10GbE integration (Project 38)
--
-- ==============================================================================
-- Copyright 2026 Adilson Dias
--
-- Licensed under the Apache License, Version 2.0
-- ==============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package symbol_filter_pkg is

    -- Symbol configuration
    constant SYMBOL_WIDTH : integer := 64; -- 8 bytes = 64 bits
    constant MAX_SYMBOLS  : integer := 8;  -- Support up to 8 symbols

    -- Symbol routing list (8 bytes each, space-padded)
    -- Each entry maps to a dedicated order book instance by index
    -- Index 0 = AAPL, Index 1 = TSLA, etc.
    type symbol_array_t is array (0 to MAX_SYMBOLS-1) of std_logic_vector(SYMBOL_WIDTH-1 downto 0);

    constant FILTER_SYMBOL_LIST : symbol_array_t := (
        0 => x"4141504C20202020",  -- "AAPL    "
        1 => x"54534C4120202020",  -- "TSLA    "
        2 => x"5350592020202020",  -- "SPY     "
        3 => x"5151512020202020",  -- "QQQ     "
        4 => x"474F4F474C202020",  -- "GOOGL   "
        5 => x"4D53465420202020",  -- "MSFT    "
        6 => x"414D5A4E20202020",  -- "AMZN    "
        7 => x"4E56444120202020"   -- "NVDA    "
    );

    -- Function to check if symbol matches routing list
    function is_symbol_filtered(symbol : std_logic_vector(SYMBOL_WIDTH-1 downto 0)) return boolean;

end package symbol_filter_pkg;

package body symbol_filter_pkg is

    -- Check if symbol is in the routing list
    function is_symbol_filtered(symbol : std_logic_vector(SYMBOL_WIDTH-1 downto 0)) return boolean is
    begin
        for i in 0 to MAX_SYMBOLS-1 loop
            if symbol = FILTER_SYMBOL_LIST(i) then
                return true;
            end if;
        end loop;

        return false;  -- Symbol not in routing list
    end function;

end package body symbol_filter_pkg;
