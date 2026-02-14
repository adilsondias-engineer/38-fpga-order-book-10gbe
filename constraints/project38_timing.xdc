# ==============================================================================
# Project 38: Order Book 10GbE - Timing Constraints
# Target: Xilinx Kintex-7 XC7K325T (AX7325B board)
#
# Clock Domains:
#   sys_clk      - 200 MHz board oscillator (order book, debug UART)
#   sfp_refclk   - 156.25 MHz SFP+ reference (QPLL input only)
#   gtx_txoutclk - 322.27 MHz GTX parallel clock (MMCM input)
#     -> tx_usrclk  = 322.27 MHz (MMCM CLKOUT0, GTX TXUSRCLK)
#     -> tx_usrclk2 = 161.13 MHz (MMCM CLKOUT1, GTX TXUSRCLK2 = tx_clk)
# ==============================================================================

# ------------------------------------------------------------------------------
# Primary Clocks
# ------------------------------------------------------------------------------

# System clock: 200 MHz (differential, on-board oscillator)
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

# SFP+ reference clock: 156.25 MHz (drives QPLL only, not used in fabric logic)
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# GTX TXOUTCLK: 322.27 MHz (10.3125 Gbps / 32)
# Must be explicitly constrained because GTXE2_CHANNEL is manually instantiated
# (not wizard-generated). Vivado cannot trace through the analog QPLL.
# MMCM output clocks (tx_usrclk, tx_usrclk2) are auto-derived from this.
create_clock -period 3.103 -name gtx_txoutclk [get_pins network_inst/gtx_inst/gtxe2_channel_inst/TXOUTCLK]

# ------------------------------------------------------------------------------
# Clock Groups
# ------------------------------------------------------------------------------

# All three clock domains are asynchronous to each other:
#   - sys_clk: board oscillator (200 MHz)
#   - sfp_refclk: SFP+ reference (156.25 MHz, QPLL input only)
#   - gtx_txoutclk + MMCM-derived clocks (tx_usrclk 322 MHz, tx_usrclk2 161 MHz)
# CDC between sys_clk and tx_clk is handled by XPM async FIFOs with internal
# gray-code synchronizers — no additional CDC constraints needed.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sys_clk] -group [get_clocks -include_generated_clocks sfp_refclk] -group [get_clocks -include_generated_clocks gtx_txoutclk]

# ------------------------------------------------------------------------------
# False Paths (async control signals)
# ------------------------------------------------------------------------------

# System reset (async, no timing requirement)
set_false_path -from [get_ports sys_rst_n]

# UART TX (slow signal, 115200 baud)
set_false_path -to [get_ports uart_tx]

# Fan PWM (slow control signal)
set_false_path -to [get_ports fan_pwm]

# SFP TX disable (slow control signal)
set_false_path -to [get_ports sfp_tx_disable]


set_property CLOCK_BUFFER_TYPE BUFG [get_nets sys_clk]
#set_property CLOCK_BUFFER_TYPE BUFG [get_nets gtx_txoutclk]
#set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets gtx_txoutclk]
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets sys_clk]
set_clock_uncertainty -setup 0.100 [get_clocks sys_clk]
set_clock_uncertainty -hold -0.150 [get_clocks sys_clk]
#set_clock_uncertainty -setup 0.100 [get_clocks network_inst/gtx_inst/tx_mmcm_clk1]
#set_clock_uncertainty -hold -0.150 [get_clocks network_inst/gtx_inst/tx_mmcm_clk1]
#set_clock_uncertainty -setup 0.100 [get_clocks tx_mmcm_clk1]
# Use pin reference for auto-derived clock (avoids TIMING-28 warning)
set_clock_uncertainty -hold -0.150 [get_clocks -of_objects [get_pins network_inst/gtx_inst/tx_mmcm_inst/CLKOUT1]]
#set_max_delay -from [get_clocks -of_objects [get_pins network_inst/gtx_inst/tx_mmcm_inst/CLKOUT1]] -to [get_clocks -of_objects [get_pins network_inst/gtx_inst/tx_mmcm_inst/CLKOUT1]] 0.0
# ------------------------------------------------------------------------------
# Physical Constraints
# ------------------------------------------------------------------------------

# MMCM placement: move tx_mmcm from default X0Y3 (2 clock regions below logic)
# to X0Y5 where mac_parser and order book logic live. Reduces clock insertion
# delay and improves timing margin on tx_clk domain paths.
#set_property LOC MMCME2_ADV_X0Y5 [get_cells network_inst/gtx_inst/tx_mmcm_inst]

create_pblock pblock_tx_mmcm_inst
add_cells_to_pblock [get_pblocks pblock_tx_mmcm_inst] [get_cells -hierarchical *tx_mmcm_inst*]
add_cells_to_pblock [get_pblocks pblock_tx_mmcm_inst] [get_cells -quiet [list trading_inst/itch_cdc_fifo_inst*]]
resize_pblock [get_pblocks pblock_tx_mmcm_inst] -add {CLOCKREGION_X0Y3:CLOCKREGION_X0Y3}

# Order book + BBO FIFO: wide region with BRAM columns on both sides of clock spine
# Expanding to X0:X1 reduces clock skew between pipeline FFs and BRAM _bret registers
# (was split into X1-only arbiter + X0-only storage, causing +0.3ns skew at BRAM edge)
create_pblock pblock_order_book
add_cells_to_pblock [get_pblocks pblock_order_book] [get_cells -quiet [list trading_inst/multi_symbol_order_book_inst* trading_inst/bbo_cdc_fifo_inst*]]
resize_pblock [get_pblocks pblock_order_book] -add {CLOCKREGION_X0Y4:CLOCKREGION_X1Y5}

# ------------------------------------------------------------------------------
# Notes
# ------------------------------------------------------------------------------

# High-fanout signals (sys_exec_shares, sys_cancel_shares, etc.) feeding 8 order
# book instances are constrained via RTL MAX_FANOUT attributes in trading_top.vhd.
# XPM FIFO internals are pre-optimized by Xilinx — no fanout constraints needed.

# Latency target: < 500 ns total FPGA processing
#   MAC parse: ~50 ns | ITCH parse: ~100 ns | Order book: ~150 ns
#   BBO calc: ~100 ns | UDP TX: ~100 ns

#set_max_delay -from [get_pins {trading_inst/itch_cdc_wr_data_reg[23]/C}] -to [get_pins {trading_inst/itch_cdc_fifo_inst/xpm_fifo_inst/gnuram_async_fifo.xpm_fifo_base_inst/gen_sdpram.xpm_memory_base_inst/gen_wr_a.gen_word_narrow.mem_reg_0/DIADI[23]}] 0.2
#
