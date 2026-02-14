# Project 38: Order Book 10GbE - FPGA Order Book with UDP TX and Latency Measurement

This project is part of a complete end-to-end trading system:
- **Main Repository:** [fpga-trading-systems](https://github.com/adilsondias-engineer/fpga-trading-systems)
- **Project Number:** 38 of 38(for now, more to come)
- **Category:** FPGA Core 
- **Dependencies:**         
       Project 33 - Custom 10GBASE-R PHY (VHDL)
       Project 34 - ITCH Parser

---

**Platform:** Xilinx Kintex-7 XC7K325T (AX7325B)
**Technology:** VHDL, 10GBASE-R PHY, XGMII, MoldUDP64/SoupBinTCP ITCH
**Status:** Hardware Tested - WNS +0.640ns, 0 critical warnings, all memories in BRAM

---

## Overview

FPGA-based order book implementation with 10GbE UDP transmission and 4-point latency measurement. This project combines:

- **Project 34**: 10GBASE-R PHY and ITCH protocol parsing
- **Project 20**: Order book management and BBO tracking
- **Project 23**: 4-point latency measurement

**Data Flow:**
```
[10GbE RX] --> [ITCH Parser] --> [Order Book] --> [BBO Tracker] --> [UDP TX] --> [10GbE TX]
                   |                   |               |                |
                  T1                  T2              T3               T4
```

**Trading Relevance:** Provides on-FPGA order book construction with measured latency for market data processing.

---

## Architecture

### Clock Domains

| Domain | Frequency | Source | Usage |
|--------|-----------|--------|-------|
| sys_clk | 200 MHz | Board oscillator (IBUFDS) | Order book, debug UART, DRP |
| tx_clk (tx_usrclk2) | 161.13 MHz | GTX TXOUTCLK -> MMCM CLKOUT1 | Network, ITCH parser, BBO TX |
| tx_usrclk | 322.27 MHz | GTX TXOUTCLK -> MMCM CLKOUT0 | GTX internal 32-bit interface |
| sfp_refclk | 156.25 MHz | SFP+ oscillator | QPLL reference only |

### CDC Crossings

| Crossing | Direction | Mechanism |
|----------|-----------|-----------|
| ITCH messages | tx_clk -> sys_clk | XPM async FIFO (480-bit, 256 deep) |
| BBO updates | sys_clk -> tx_clk | XPM async FIFO (320-bit, 256 deep) |
| Reset sync | sys_clk -> tx_clk | 2FF synchronizer in network_top |
| PHY ready | sys_clk -> tx_clk | 3FF synchronizer in network_top |

---

## 4-Point Latency Measurement

Based on Project 23's latency calculator:

| Point | Description | Clock Domain |
|-------|-------------|--------------|
| **T1** | ITCH message parse start | TX (161 MHz) |
| **T2** | CDC FIFO write (order book entry) | TX (161 MHz) |
| **T3** | BBO FIFO read (BBO update detected) | TX (161 MHz) |
| **T4** | UDP TX start (packet transmission) | TX (161 MHz) |

**Target Latency:** < 500 ns total FPGA processing

---

## BBO Payload Format

44-byte UDP payload (sent to Project 14/36/37):

| Offset | Field | Size | Description |
|--------|-------|------|-------------|
| 0 | Symbol | 8 | ASCII stock ticker (space-padded) |
| 8 | Bid Price | 4 | Big-endian, /10000 for dollars |
| 12 | Bid Shares | 4 | Big-endian quantity |
| 16 | Ask Price | 4 | Big-endian, /10000 for dollars |
| 20 | Ask Shares | 4 | Big-endian quantity |
| 24 | Spread | 4 | Big-endian, /10000 for dollars |
| 28 | T1 | 4 | ITCH parse timestamp |
| 32 | T2 | 4 | CDC FIFO timestamp |
| 36 | T3 | 4 | BBO FIFO timestamp |
| 40 | T4 | 4 | UDP TX timestamp |

---

## Source Files

```
38-order-book-10gbe/
+-- README.md
+-- TIMING_FIX_PLAN.md                 # Timing constraint fix plan (Feb 2026)
+-- constraints/
|   +-- project38_pins.xdc             # Pin assignments (AX7325B)
|   +-- project38_timing.xdc           # Timing constraints (3 clock domains)
+-- src/
|   +-- fifo/
|   |   +-- async_fifo.vhd            # Gray-code async FIFO (inference-based)
|   |   +-- async_fifo_itch.vhd       # XPM async FIFO wrapper (BRAM guaranteed)
|   +-- itch/
|   |   +-- trading_top.vhd           # Trading integration (parser + CDC + OB)
|   +-- order_book/
|   |   +-- order_book_pkg.vhd        # Data types and constants
|   |   +-- symbol_filter_pkg.vhd     # Symbol filtering (8 symbols)
|   |   +-- order_storage.vhd         # BRAM-based order storage (1024 x 130)
|   |   +-- price_level_table.vhd     # BRAM-based price aggregation (256 x 82)
|   |   +-- bbo_tracker.vhd           # Best bid/offer tracker
|   |   +-- order_book_manager.vhd    # Order book FSM
|   |   +-- multi_symbol_order_book.vhd # 8 parallel order books + arbiter
|   +-- latency/
|   |   +-- latency_calculator.vhd    # 4-point latency measurement
|   +-- network/
|   |   +-- network_top.vhd           # 10GbE network layer (GTX, PCS, MAC)
|   +-- xgmii/
|   |   +-- link_init_tx.vhd          # Link startup packets
|   +-- integration/
|   |   +-- order_book_10gbe_top.vhd  # Top-level integration
|   |   +-- bbo_udp_tx.vhd            # BBO UDP TX over XGMII
|   +-- debug/
|       +-- gtx_debug_reporter.v      # UART debug output
|       +-- uart_tx_simple.v          # UART TX primitive
+-- vivado/
    +-- reports/                       # Synthesis/implementation reports
```

### CDC FIFOs

| FIFO | Width | Depth | Direction | Implementation |
|------|-------|-------|-----------|----------------|
| ITCH CDC | 480 bits | 256 | tx_clk -> sys_clk | XPM (xpm_fifo_async) |
| BBO CDC | 320 bits | 256 | sys_clk -> tx_clk | XPM (xpm_fifo_async) |

Both FIFOs use `async_fifo_itch.vhd` (XPM wrapper with `FIFO_MEMORY_TYPE => "block"`) to guarantee BRAM allocation.

### Files Reused from Other Projects

| Source | Project | Description |
|--------|---------|-------------|
| `gtx_10g_wrapper.vhd` | 33 | GTX 10GBASE-R transceiver |
| `pcs_10gbase_r.vhd` | 33 | 64B/66B PCS encoder/decoder |
| `mac_parser_xgmii.vhd` | 34 | Ethernet MAC parser |
| `moldudp64_handler.vhd` | 34 | MoldUDP64 protocol handler |
| `nasdaq_itch_parser.vhd` | 34 | NASDAQ ITCH message parser |
| `latency_calculator.vhd` | 23 | 4-point latency measurement |

---

## Resource Utilization (post-implementation, Feb 13 2026)

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| Slice LUTs | 13,605 | 203,800 | 6.68% |
| LUT as Logic | 13,538 | 203,800 | 6.64% |
| LUT as Distributed RAM | 64 | 64,000 | 0.10% |
| Slice Registers | 19,684 | 407,600 | 4.83% |
| BRAM Tiles | 48.5 | 445 | 10.90% |
| F7 Muxes | 225 | 101,900 | 0.22% |
| GTX Transceivers | 1 | 16 | 6.25% |
| BUFG | 4 | 32 | 12.50% |
| MMCM | 1 | 10 | 10.00% |

**BRAM Breakdown (48.5 tiles):**
- Order storage: 8 x 4 = 32 BRAM36 (1024 x 130 per symbol)
- Price level table: 8 x 1 = 8 BRAM36 (256 x 82 per symbol)
- ITCH CDC FIFO: ~4 BRAM36 + BRAM18 (256 x 480, XPM)
- BBO CDC FIFO: ~4 BRAM18 (256 x 320, XPM)

**Timing Summary:**
- sys_clk (200 MHz): WNS +0.640ns, 0 failing paths
- tx_mmcm_clk1 (161.13 MHz): WNS +1.008ns, 0 failing paths
- 0 TIMING-17 critical warnings, 0 unconstrained registers

---

## Debug History

### Bug 1: CDC FIFO Double-Read
- **Symptom:** ITCH FIFO read count = 2x write count
- **Root cause:** Empty flag CDC latency -- flag still shows not-empty after read
- **Fix:** Cooldown counter (4 cycles) after each FIFO read to let empty flag settle

### Bug 2: TX Counter Mapping
- **Symptom:** TX count showed ITCH message count, not actual BBO TX packets
- **Fix:** Map `bbo_tx_count => tx_pkt_count(15 downto 0)` in top-level

### Bug 3: price_to_addr Collision (All Orders -> Address 0)
- **Symptom:** Only 1 BBO update from 80,000 ITCH messages
- **Root cause:** `price(31 downto 25)` = top 7 bits, always 0 for prices < $3,355
- **Fix:** XOR folding: `upper(20:14) XOR lower(13:7)` for good distribution

### Bug 4: CRC Computed Before T4 Timestamp
- **Symptom:** TX counter shows 101 packets, but none visible on network
- **Root cause:** T4 written in TX_START (after CRC), frame_data had zeros during CRC
- **Fix:** Capture T4 and populate frame_data in TX_BUILD_FRAME (before CRC)
- **Validation:** TEST_MODE with fixed packets confirmed TX path works with valid CRC

### Bug 5: Symbol Filter Disabled
- **Symptom:** Only 101 BBO updates from 80K messages across 8 symbols
- **Root cause:** `ENABLE_SYMBOL_FILTER = false` -- all 80K messages to single order book
- **Fix:** Set `ENABLE_SYMBOL_FILTER = true` in `symbol_filter_pkg.vhd`

### Bug 6: Arbiter Timing Violation (-0.07ns)
- **Symptom:** Path from current_symbol_reg to prev_bbo_reg CE, 8 logic levels
- **Root cause:** Compare + decode + write all in one cycle at counter=999
- **Fix:** 2-stage pipeline: register comparison result, update prev_bbo next cycle

### Bug 7: order_storage Using LUTRAM Instead of BRAM
- **Symptom:** 23,104 LUTs as Distributed RAM
- **Root cause:** Write and read in separate processes -- Xilinx can't infer SDP BRAM
- **Fix:** Merge into single process following Xilinx Simple Dual-Port template
- **Impact:** 8 instances x 1024 x 130 bits = ~32 BRAM36 instead of 23K LUTs

### Bug 8: ITCH CDC FIFO Not Inferring BRAM
- **Symptom:** WARNING [Synth 8-6026] + [Synth 8-6849] on ITCH FIFO only; BBO FIFO (same entity) infers BRAM fine
- **Root cause:** Unknown Vivado synthesis quirk -- exhaustive testing (depth, width, template, entity, clocks) found no RTL fix
- **Fix:** `xpm_fifo_async` wrapper (`async_fifo_itch.vhd`) with `FIFO_MEMORY_TYPE => "block"` bypasses inference engine entirely
- **Also applied to:** BBO CDC FIFO (converted to XPM for consistency)

### Bug 9: Broken XDC Fanout Constraints
- **Symptom:** Critical warnings for exec_shares/cancel_shares fanning out >100; XDC constraints fail with "object/path not found"
- **Root cause:** XDC referenced old FIFO internals (fifo_mem, rd_ptr_reg_rep) that don't exist in XPM FIFO
- **Fix:** Removed broken XDC constraints; added RTL `MAX_FANOUT` attributes in `trading_top.vhd`

### Bug 10: TXOUTCLK Not Constrained (1000 TIMING-17 Critical Warnings)
- **Symptom:** 1000 TIMING-17 (non-clocked sequential cell), 2963 unconstrained registers, 8505 unconstrained endpoints
- **Root cause:** GTX TXOUTCLK (322.27 MHz) had no clock definition. Manually instantiated GTXE2_CHANNEL -- Vivado cannot auto-discover through analog QPLL. Entire tx_clk domain invisible to timing engine.
- **Fix:** Added `create_clock -period 3.103 -name gtx_txoutclk` on TXOUTCLK pin. MMCM outputs auto-derived. Replaced duplicate `set_clock_groups` with single 3-domain constraint. Removed stale multicycle path and commented-out constraints.

### Bug 11: mac_parser_xgmii Timing Violation (-9.65ns, 58 Logic Levels)
- **Symptom:** -9.653ns setup violation on tx_mmcm_clk1 (161 MHz) revealed after Bug 10 fix constrained the tx_clk domain
- **Root cause:** PS_PAYLOAD state computed `payload_total - payload_written` (16-bit subtract) then fed result into 8x 16-bit comparisons for keep mask, then loop-summed bytes, then compared for wr_last -- all combinational in one cycle (58 logic levels, 15.9ns vs 6.2ns budget)
- **Fix:** Added pre-registered `remaining_r` counter that tracks `payload_total - payload_written` as a running decrement. Replaced 16-bit subtract + 8x compare loop with 13-bit NOR (>=8 check) + 3-bit decode table for keep mask
- **Impact:** 58 logic levels reduced to ~5. tx_clk WNS improved from -9.65ns to +0.84ns
- **File:** `mac_parser_xgmii.vhd` (shared with Project 34)

### Bug 12: multi_symbol_order_book Arbiter Array Fanout
- **Symptom:** sys_clk critical path from `current_symbol_reg` through array MUX to BBO comparison, WNS +0.352ns
- **Root cause:** Stage 2 comparisons accessed `bbo_data_vec(i)` and `prev_bbo(i)` via variable index -- array MUX feeds directly into comparator chain (MUX -> compare -> decode -> write)
- **Fix:** Added pre-registered `selected_bbo_current` and `selected_bbo_prev` signals. Stage 1 (counter=999): capture array elements into flat signals via one-hot decode. Stage 2 (next cycle): compare flat signals with no array indexing
- **Impact:** WNS improved from +0.352ns to +0.457ns. Critical path reduced to pure routing (0 logic levels, 91% net delay)

---

## Hardware Requirements

| Component | Specification |
|-----------|---------------|
| FPGA | Xilinx Kintex-7 XC7K325T |
| Board | ALINX AX7325B |
| SFP+ | 10GBASE-SR/LR module |
| Fiber | OM3/OM4 multimode or OS2 singlemode |
| Reference Clock | 156.25 MHz (on-board) |

---

## Building

### Prerequisites

- Vivado 2023.1+ (2025.2 recommended)
- Xilinx Kintex-7 license

### Build Steps

```tcl
# In Vivado Tcl console:
cd 38-order-book-10gbe
source scripts/build.tcl

# Or via GUI:
# 1. Create new project targeting xc7k325tffg900-2
# 2. Add all sources from src/
# 3. Add constraints from constraints/
# 4. Run synthesis, implementation, bitstream generation
```

---

## Network Configuration

### Default Settings

| Parameter | Value |
|-----------|-------|
| Source MAC | 00:0A:35:01:FE:C0 |
| Destination MAC | FF:FF:FF:FF:FF:FF (broadcast) |
| Source IP | 192.168.0.215 |
| Destination IP | 192.168.0.144 |
| Source Port | 12345 |
| Destination Port | 5000 |

### Modifying Network Settings

Edit generics in `order_book_10gbe_top.vhd` or `bbo_udp_tx.vhd`:

```vhdl
generic (
    SRC_MAC  : std_logic_vector(47 downto 0) := x"000A3501FEC0";
    DST_MAC  : std_logic_vector(47 downto 0) := x"FFFFFFFFFFFF";
    SRC_IP   : std_logic_vector(31 downto 0) := x"C0A800D7";  -- 192.168.0.215
    DST_IP   : std_logic_vector(31 downto 0) := x"C0A80090";  -- 192.168.0.144
    SRC_PORT : std_logic_vector(15 downto 0) := x"3039";      -- 12345
    DST_PORT : std_logic_vector(15 downto 0) := x"1388"       -- 5000
);
```

---

## Troubleshooting

### No link established
- Check SFP+ module is inserted correctly
- Verify fiber connection (TX to RX, RX to TX)
- Check LED status (link LED should be on)

### No BBO packets received
- Verify ITCH data source is sending valid messages
- Check symbol filter configuration (`symbol_filter_pkg.vhd`)
- Monitor debug counters via UART (115200 baud)
- Verify CRC: packets with bad CRC are silently dropped by switch/NIC

### BRAM inference issues
- Ensure write + read are in same process (Xilinx SDP template)
- One write address, one read address per BRAM process
- For persistent issues: use `xpm_fifo_async` or `xpm_memory_sdpram` to bypass inference

---

## Related Projects

- **[33-10gbe-phy-custom/](../33-10gbe-phy-custom/)** - 10GBASE-R PHY (GTX transceiver)
- **[14-order-gateway-cpp/](../14-order-gateway-cpp/)** - C++ receiver
- **[36-ultra-low-latency-rx/](../36-ultra-low-latency-rx/)** - DPDK receiver

---

**Created:** January 2026
**Last Updated:** February 13, 2026
**Target Latency:** < 500 ns FPGA processing
**Hardware Status:** Tested on AX7325B, WNS +0.640ns, 0 critical warnings
