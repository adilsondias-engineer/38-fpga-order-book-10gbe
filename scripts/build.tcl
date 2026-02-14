# ==============================================================================
# Vivado Build Script for Project 38: Order Book 10GbE
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
#
# This project combines:
#   - Project 33: 10GBASE-R PHY (GTX transceiver, 64B/66B PCS)
#   - Project 34: ITCH protocol parsing (MAC, MoldUDP64, SoupBinTCP)
#   - Project 20: Order book management (BRAM-based, 8 symbols)
#   - Project 23: 4-point latency measurement
#
# Data Flow:
#   [10GbE RX] -> [ITCH Parser] -> [Order Book] -> [BBO Tracker] -> [UDP TX] -> [10GbE TX]
#        |              |               |               |               |
#       T1             T2              (processing)     T3              T4
#
# ==============================================================================
# Copyright 2026 Adilson Dias
# Licensed under the Apache License, Version 2.0
# ==============================================================================



set project_name "order-book-10gbe"
set project_dir  "[file dirname [info script]]/../vivado"
set src_dir      "[file dirname [info script]]/../src"
set constr_dir   "[file dirname [info script]]/../constraints"

# External project source directories
set phy_src_dir   "[file dirname [info script]]/../../33-10gbe-phy-custom/src"
set itch_src_dir  "[file dirname [info script]]/../../34-tcp-itch-parser/src"

# Target part (Kintex-7 325T on ALINX AX7325B)
set part_number "xc7k325tffg900-2"

# ==============================================================================
# Create Project
# ==============================================================================

puts "=============================================="
puts "Project 38: Order Book 10GbE Build"
puts "Target: $part_number"
puts "=============================================="

file mkdir $project_dir
file mkdir $project_dir/reports
create_project $project_name $project_dir -part $part_number -force


set_property target_language VHDL [current_project]

# ==============================================================================
# Add Sources - Project 38 Order Book (Local)
# ==============================================================================

puts "Adding Project 38 Order Book sources..."

# Order book package and types (must be added first)
add_files -norecurse $src_dir/order_book/order_book_pkg.vhd
add_files -norecurse $src_dir/order_book/symbol_filter_pkg.vhd

# Order book components (BRAM-based)
add_files -norecurse $src_dir/order_book/order_storage.vhd
add_files -norecurse $src_dir/order_book/price_level_table.vhd
add_files -norecurse $src_dir/order_book/bbo_tracker.vhd
add_files -norecurse $src_dir/order_book/order_book_manager.vhd
add_files -norecurse $src_dir/order_book/multi_symbol_order_book.vhd

# Latency measurement (from Project 23)
add_files -norecurse $src_dir/latency/latency_calculator.vhd

# Async FIFO for CDC (rx_clk -> tx_clk)
add_files -norecurse $src_dir/fifo/async_fifo.vhd

# BBO UDP TX over XGMII
add_files -norecurse $src_dir/integration/bbo_udp_tx.vhd

# Link Init TX (sends startup packets to establish 10GbE link)
add_files -norecurse $src_dir/xgmii/link_init_tx.vhd

# Debug reporter (UART output of GTX/Parser status - from Project 34)
add_files -norecurse $src_dir/debug/gtx_debug_reporter.v
add_files -norecurse $src_dir/debug/uart_tx_simple.v

# ==============================================================================
# Add Sources - Project 33 (10GBASE-R PHY)
# ==============================================================================

puts "Adding Project 33 PHY sources..."

# GTX wrapper
if {[file exists $phy_src_dir/gtx/gtx_10g_wrapper.vhd]} {
    add_files -norecurse $phy_src_dir/gtx/gtx_10g_wrapper.vhd
    puts "  Added: gtx_10g_wrapper.vhd"
} else {
    puts "  WARNING: gtx_10g_wrapper.vhd not found"
}

# PCS sources (10GBASE-R Physical Coding Sublayer)
if {[file exists $phy_src_dir/pcs/pcs_10gbase_r.vhd]} {
    add_files -norecurse $phy_src_dir/pcs/pcs_10gbase_r.vhd
    add_files -norecurse $phy_src_dir/pcs/encoder_64b66b.vhd
    add_files -norecurse $phy_src_dir/pcs/decoder_64b66b.vhd
    add_files -norecurse $phy_src_dir/pcs/block_lock_fsm.vhd
    puts "  Added: PCS components"
} else {
    puts "  WARNING: PCS sources not found"
}

# Scrambler sources
if {[file exists $phy_src_dir/scrambler/scrambler_tx.vhd]} {
    add_files -norecurse $phy_src_dir/scrambler/scrambler_tx.vhd
    add_files -norecurse $phy_src_dir/scrambler/descrambler_rx.vhd
    puts "  Added: Scrambler components"
} else {
    puts "  WARNING: Scrambler sources not found"
}

# Gearbox sources
if {[file exists $phy_src_dir/gearbox/tx_gearbox.vhd]} {
    add_files -norecurse $phy_src_dir/gearbox/tx_gearbox.vhd
    add_files -norecurse $phy_src_dir/gearbox/rx_gearbox.vhd
    puts "  Added: Gearbox components"
}

# ==============================================================================
# Add Sources - Project 34 (ITCH Parser)
# ==============================================================================

puts "Adding Project 34 ITCH Parser sources..."

# ITCH common package (shared types for NASDAQ/ASX)
if {[file exists $itch_src_dir/common/itch_msg_common_pkg.vhd]} {
    add_files -norecurse $itch_src_dir/common/itch_msg_common_pkg.vhd
    puts "  Added: itch_msg_common_pkg.vhd"
}

# MAC parser
if {[file exists $itch_src_dir/xgmii/mac_parser_xgmii.vhd]} {
    add_files -norecurse $itch_src_dir/xgmii/mac_parser_xgmii.vhd
    puts "  Added: mac_parser_xgmii.vhd"
}

# Protocol demultiplexer
if {[file exists $itch_src_dir/common/protocol_demux.vhd]} {
    add_files -norecurse $itch_src_dir/common/protocol_demux.vhd
    puts "  Added: protocol_demux.vhd"
}

# MoldUDP64 handler
if {[file exists $itch_src_dir/transport/moldudp64_handler.vhd]} {
    add_files -norecurse $itch_src_dir/transport/moldudp64_handler.vhd
    puts "  Added: moldudp64_handler.vhd"
}

# NASDAQ ITCH parser
if {[file exists $itch_src_dir/itch/nasdaq/nasdaq_itch_parser.vhd]} {
    add_files -norecurse $itch_src_dir/itch/nasdaq/nasdaq_itch_parser.vhd
    puts "  Added: nasdaq_itch_parser.vhd"
}

# SoupBinTCP handler (optional)
if {[file exists $itch_src_dir/transport/soupbintcp_handler.vhd]} {
    add_files -norecurse $itch_src_dir/transport/soupbintcp_handler.vhd
    puts "  Added: soupbintcp_handler.vhd"
}

# ==============================================================================
# Add Trading Logic Module (ITCH parser, CDC FIFOs, Order Book)
# ==============================================================================

puts "Adding trading logic module..."
add_files -norecurse $src_dir/itch/trading_top.vhd

# ==============================================================================
# Add Network Layer Module (GTX, PCS, MAC, MoldUDP64)
# ==============================================================================

puts "Adding network layer module..."
add_files -norecurse $src_dir/network/network_top.vhd

# ==============================================================================
# Add Top-Level Integration Module
# ==============================================================================

puts "Adding top-level integration..."
add_files -norecurse $src_dir/integration/order_book_10gbe_top.vhd

# ==============================================================================
# Set Top Module and File Properties
# ==============================================================================

set_property top order_book_10gbe_top [current_fileset]
set_property file_type {VHDL 2008} [get_files *.vhd]

# ==============================================================================
# Add Constraints
# ==============================================================================

puts "Adding constraints..."

if {[file exists $constr_dir/project38_pins.xdc]} {
    add_files -fileset constrs_1 -norecurse $constr_dir/project38_pins.xdc
    puts "  Added: project38_pins.xdc"
}

if {[file exists $constr_dir/project38_timing.xdc]} {
    add_files -fileset constrs_1 -norecurse $constr_dir/project38_timing.xdc
    puts "  Added: project38_timing.xdc"
}

# ==============================================================================
# Synthesis Settings (Strategy: Flow_AreaOptimized_high)
# ==============================================================================

set_property strategy Flow_AreaOptimized_high [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE AreaMapLargeShiftRegToBRAM [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FSM_EXTRACTION one_hot [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.CONTROL_SET_OPT_THRESHOLD 1 [get_runs synth_1]

# ==============================================================================
# Implementation Settings (Strategy: Performance_EarlyBlockPlacement)
# ==============================================================================

set_property strategy Performance_EarlyBlockPlacement [get_runs impl_1]
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE ExploreWithRemap [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveFanoutOpt [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

# ==============================================================================
# Run Synthesis
# ==============================================================================

puts ""
puts "Starting synthesis..."
reset_run synth_1
launch_runs synth_1 -jobs 16
wait_on_run synth_1

set synth_progress [get_property PROGRESS [get_runs synth_1]]
puts "Synthesis progress: $synth_progress"
if {$synth_progress != "100%"} {
    puts "ERROR: Synthesis failed! Progress: $synth_progress"
    report_drc -file $project_dir/reports/drc_synth.rpt
    exit 1
}

puts "Synthesis completed successfully."

# ==============================================================================
# Open Synthesized Design and Report
# ==============================================================================

open_run synth_1

report_utilization -file $project_dir/reports/utilization_synth.rpt
report_timing_summary -file $project_dir/reports/timing_synth.rpt
report_clocks -file $project_dir/reports/clocks_synth.rpt

puts ""
puts "Synthesis reports generated in: $project_dir/reports/"

# ==============================================================================
# Run Implementation
# ==============================================================================

puts ""
puts "Starting implementation..."
launch_runs impl_1 -jobs 16
wait_on_run impl_1

set impl_progress [get_property PROGRESS [get_runs impl_1]]
puts "Implementation progress: $impl_progress"
if {$impl_progress != "100%"} {
    puts "ERROR: Implementation failed! Progress: $impl_progress"
    exit 1
}

puts "Implementation completed successfully."

# Open implemented design
open_run impl_1

# Generate post-implementation reports
report_utilization -file $project_dir/reports/utilization_impl.rpt
report_timing_summary -file $project_dir/reports/timing_impl.rpt -max_paths 20
report_timing -file $project_dir/reports/timing_paths.rpt -max_paths 50 -slack_lesser_than 0
report_power -file $project_dir/reports/power_impl.rpt

# Check timing
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]

puts ""
puts "=============================================="
puts "Implementation Complete"
puts "=============================================="
puts "Worst Negative Slack (WNS): $wns ns"
puts "Total Negative Slack (TNS): $tns ns"
puts ""

if {$wns < 0} {
    puts "WARNING: Timing not met! WNS = $wns ns"
    puts "Review timing_paths.rpt for failing paths."
} else {
    puts "SUCCESS: All timing constraints met!"
}

# ==============================================================================
# Generate Bitstream
# ==============================================================================

puts ""
puts "Generating bitstream..."
write_bitstream -force $project_dir/order_book_10gbe.bit
puts "Bitstream generated: $project_dir/order_book_10gbe.bit"

# ==============================================================================
# Summary
# ==============================================================================

puts ""
puts "=============================================="
puts "BUILD COMPLETE - Project 38: Order Book 10GbE"
puts "=============================================="
puts ""
puts "Architecture:"
puts "  10GbE RX -> ITCH Parser -> Order Book (8 symbols) -> BBO -> UDP TX"
puts ""
puts "Components Used:"
puts "  - Project 33: 10GBASE-R PHY (GTX, 64B/66B PCS)"
puts "  - Project 34: ITCH Parser (MAC, MoldUDP64, SoupBinTCP)"
puts "  - Project 20: Order Book (BRAM: 1024 orders x 8 symbols)"
puts "  - Project 23: Latency Calculator (4-point measurement)"
puts ""
puts "Resource Estimates:"
puts "  - BRAM: ~32 RAMB36 (order storage + price levels)"
puts "  - GTX:  1 transceiver (10GBASE-R)"
puts ""
puts "BBO Output Format (44 bytes UDP payload):"
puts "  Symbol(8) + Bid(8) + Ask(8) + Spread(4) + T1-T4(16)"
puts ""
puts "Target Latency: < 500 ns (ITCH parse to UDP TX)"
puts ""
puts "Bitstream: $project_dir/order_book_10gbe.bit"
puts "Reports:   $project_dir/reports/"
puts ""
