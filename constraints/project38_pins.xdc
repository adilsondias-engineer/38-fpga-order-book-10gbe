# ==============================================================================
# Project 38: Order Book 10GbE - Pin Constraints
# Target: Xilinx Kintex-7 XC7K325T (AX7325B board)
#
# Based on Project 34 constraints (working 10GbE implementation)
# ==============================================================================

# ==============================================================================
# System Clock (200 MHz differential from on-board oscillator)
# Pins and IOSTANDARD verified from working Project 33/34 on AX7325B
# ==============================================================================
set_property PACKAGE_PIN AE10 [get_ports sys_clk_p]
set_property PACKAGE_PIN AF10 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_n]
#already defined in the timing.xdc
#create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

# ==============================================================================
# System Reset (active low, directly from key button)
# ==============================================================================
set_property PACKAGE_PIN AG28 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS25 [get_ports sys_rst_n]

# ==============================================================================
# 10GbE SFP+ Interface
# ==============================================================================

# SFP+ Reference Clock (156.25 MHz differential from SFP+ cage)
set_property PACKAGE_PIN G8 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN G7 [get_ports sfp_refclk_n]

# SFP+ GTX Transceiver (Serial Interface) - GTX Quad 117, Channel 0

# SFP+ Control Signals (matching Project 34)
set_property PACKAGE_PIN T28 [get_ports sfp_tx_disable]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_tx_disable]

# ==============================================================================
# Fan Control (PWM)
# ==============================================================================
set_property IOSTANDARD LVCMOS25 [get_ports fan_pwm]
set_property PACKAGE_PIN AE26 [get_ports fan_pwm]

# ==============================================================================
# Status LEDs (Active low LEDs on AX7325B)
# ==============================================================================
set_property PACKAGE_PIN A22 [get_ports led_qpll_lock]
set_property PACKAGE_PIN C19 [get_ports led_gtx_ready]
set_property PACKAGE_PIN B19 [get_ports led_pcs_lock]
set_property PACKAGE_PIN E18 [get_ports led_bbo_activity]

set_property IOSTANDARD LVCMOS15 [get_ports led_qpll_lock]
set_property IOSTANDARD LVCMOS15 [get_ports led_gtx_ready]
set_property IOSTANDARD LVCMOS15 [get_ports led_pcs_lock]
set_property IOSTANDARD LVCMOS15 [get_ports led_bbo_activity]

# ==============================================================================
# Debug UART (115200 baud, FT232 on board)
# ==============================================================================
set_property PACKAGE_PIN AK26 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS25 [get_ports uart_tx]

# ==============================================================================
# False Paths for Slow Control Signals
# ==============================================================================
set_false_path -to [get_ports led_*]
set_false_path -to [get_ports sfp_tx_disable]
set_false_path -to [get_ports uart_tx]
set_false_path -to [get_ports fan_pwm]
set_false_path -from [get_ports sys_rst_n]

# ==============================================================================
# GTX Location Constraints (from working Project 33/34)
# G7/G8 = MGTREFCLK0_117, K1/K2/K5/K6 = QUAD 117 lane 0
# ==============================================================================

# QPLL for QUAD 117
set_property LOC GTXE2_COMMON_X0Y2 [get_cells -hier -filter REF_NAME==GTXE2_COMMON]

# SFP+ GTX Channel - QUAD 117, Lane 0 (X0Y8)
set_property LOC GTXE2_CHANNEL_X0Y8 [get_cells -hier -filter REF_NAME==GTXE2_CHANNEL]
set_property PACKAGE_PIN K5 [get_ports sfp_rx_n]
set_property PACKAGE_PIN K6 [get_ports sfp_rx_p]
set_property PACKAGE_PIN K1 [get_ports sfp_tx_n]
set_property PACKAGE_PIN K2 [get_ports sfp_tx_p]

# ==============================================================================
# Bitstream Configuration
# ==============================================================================
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ==============================================================================
# DRC Waivers
# ==============================================================================

# ==============================================================================
# End of constraints
# ==============================================================================



