# AXI4 Slave RAM — UVM Verification Environment

A complete **UVM 1.2** black-box verification environment for an AXI4-compliant single-port slave RAM. Features constrained-random and directed stimulus, a byte-accurate scoreboard reference model, 14 SVA protocol assertions, and 100% functional coverage closure across 5 parameterized configurations.

---

## DUT

The design under test is **`axi_ram.v`** by Alex Forencich, sourced from [alexforencich/verilog-axi](https://github.com/alexforencich/verilog-axi/blob/master/rtl/axi_ram.v). No modifications were made to the RTL. The verification environment was built independently against the **ARM AMBA AXI4 specification (IHI0022E/H)**.

| Property | Details |
|---|---|
| Interface | Single AXI4 slave (AW, W, B, AR, R) |
| Burst types | FIXED, INCR (WRAP not supported) |
| Narrow bursts | Supported |
| Memory | 2^ADDR_WIDTH bytes, configurable |
| Pipeline option | `PIPELINE_OUTPUT` register stage on read path |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                       axi_env                            │
│                                                          │
│   ┌──────────────────────────────┐   ┌────────────────┐  │
│   │          axi_agent           │   │  axi_scoreboard│  │
│   │  ┌─────┐  ┌──────┐  ┌─────┐  │   │  (byte-level   │  │
│   │  │ sqr │→ │ drv  │→ │ DUT │  │   │   ref model)   │  │
│   │  └─────┘  └──────┘  └─────┘  │   └───────┬────────┘  │
│   │             ┌──────┐         │           │           │
│   │             │ mon  │─────────┼───────────┘           │
│   │             └──────┘         │   ┌────────────────┐  │
│   └──────────────────────────────┘   │  axi_coverage  │  │
│                                      └────────────────┘  │
│   ┌──────────────────────────────┐                       │
│   │    axi_protocol_sva (14)     │                       │
│   └──────────────────────────────┘                       │
└──────────────────────────────────────────────────────────┘
```

| Component | Role |
|---|---|
| **axi_seq_item** | Transaction object with AXI4 fields, backpressure knobs, WVALID gap control, W-before-AW flag, and 4KB boundary constraint |
| **axi_driver** | Drives all 5 channels with concurrent AW+W, W-before-AW ordering, configurable delays, and reset-safe `item_done` handling |
| **axi_monitor** | Parallel AW+W capture (handles W-before-AW), separate write/read analysis ports |
| **axi_scoreboard** | Byte-addressable associative-array reference model with INCR/FIXED address calculation, WSTRB masking, and narrow-burst lane checking |
| **axi_coverage** | 5 covergroups: transactions (with crosses), address regions, write strobes, backpressure, concurrency |
| **axi_protocol_sva** | 14 assertions: handshake/payload stability, WLAST/RLAST, ID matching, response codes, reset |

---

## Verification Scope

**22 tests** covering 56 features across 10 categories:

| Category | Features | Key Tests |
|---|---|---|
| Data Integrity | 5 | Single R/W, overwrite, uninit read, address boundaries |
| Burst Types | 7 | INCR (1–256 beats), FIXED, 4KB boundary, addr overflow |
| Narrow Bursts | 8 | Byte/halfword, lane steering, mixed-width access |
| Write Strobes | 5 | Partial, all-off, single-byte, per-beat, narrow interaction |
| Ordering & Concurrency | 6 | W-before-AW, simultaneous AR+AW, RAW hazard, outstanding |
| ID Correctness | 4 | BID/RID echo, full range sweep |
| Response Codes | 3 | BRESP/RRESP=OKAY, RLAST correctness |
| Protocol Compliance | 11 | Handshakes, signal stability, reset mid-write/read, recovery |
| Backpressure | 6 | BREADY/RREADY/WVALID delays, back-to-back, stress |
| Pipeline Output | 4 | All key scenarios with PIPELINE_OUTPUT=1 |

Full feature-by-feature traceability is in the [Verification Plan](verification%20plan/verification%20plan%20%26%20report/) and [Regression Report](verification%20plan/verification%20plan%20%26%20report/).

---

## Results

| Metric | Result |
|---|---|
| Tests | **22/22 pass** (all configs) |
| UVM_ERROR / UVM_FATAL | **0** |
| Scoreboard mismatches | **0** |
| SVA failures | **0** |
| Functional coverage | **97.2%** (all 5 covergroups) |

### Regression Configurations

| Config | Key Parameter | Define |
|---|---|---|
| Default | 32-bit data, 16-bit addr, 8-bit ID | *(none)* |
| Pipeline | PIPELINE_OUTPUT=1 | `+define+CFG_PIPELINE` |
| Wide Bus | DATA_WIDTH=64 | `+define+CFG_WIDE_BUS` |
| Narrow ID | ID_WIDTH=4 | `+define+CFG_NARROW_ID` |
| Small Memory | ADDR_WIDTH=12 | `+define+CFG_SMALL_MEM` |

Detailed per-test results and coverage breakdown are in the [Regression Report](verification%20plan/verification%20plan%20%26%20report/).

---

## Design Decisions & Challenges

### Why Black-Box?

The environment accesses the DUT only through its AXI4 interface — no internal signals are probed. This makes the testbench portable to any AXI4 slave RAM implementation and ensures verification is specification-driven, catching protocol bugs that white-box approaches might overlook.

### Byte-Addressable Reference Model

The scoreboard uses `bit [7:0] ref_mem[bit [ADDR_WIDTH-1:0]]` rather than a word-addressable array. AXI4 write strobes operate at byte granularity, so a byte-level model naturally handles partial strobes, narrow bursts with rotating active lanes, and mixed-width access patterns without complex masking logic. Uninitialized addresses return 0x00 via `ref_mem.exists()`.

### Narrow Burst Byte-Lane Calculation

The trickiest part of the scoreboard. For INCR bursts with AXSIZE < bus width, the active byte lane rotates through the bus on each beat. The scoreboard computes `lo_lane = beat_addr % STRB_WIDTH` and only checks bytes in `[lo_lane : lo_lane + num_bytes - 1]`, ignoring undefined lanes per AXI4 spec. Getting this wrong initially caused false mismatches on narrow read-back — the fix required careful alignment of the address calculation with the spec's Section A3.4 rules.

### W-Before-AW Monitor Design

AXI4 allows write data (W channel) to arrive before the write address (AW channel). The monitor uses a `fork-join` that captures AW and W beats in parallel — whichever arrives first is captured without blocking the other. This required careful design to avoid race conditions between the two threads.

### Reset-Safe Driver (`item_in_progress` Flag)

When reset kills the driver mid-transaction, `item_done()` never gets called, causing the sequencer to error on the next `get_next_item()`. The solution: an `item_in_progress` flag tracks whether the driver owes `item_done()` to the sequencer. After `disable fork` kills the transaction, the driver checks this flag and completes the handshake before re-entering idle.

### 4KB Boundary Constraint

Rather than runtime checking, the 4KB boundary rule is enforced at the constraint level: `((addr & 12'hFFF) + (len+1) * 2^size) <= 4096`. The solver guarantees every generated INCR burst is protocol-legal. Separate directed tests exercise near-boundary addresses.

### Coverage Closure Strategy

Initial random stimulus left bins unhit: long burst lengths, unaligned addresses, near-4KB regions, and medium backpressure delays. A dedicated `axi_cov_fill_seq` targets these specific bins first, then random stress follows. This hybrid approach achieved 100% efficiently. Concurrency coverage (AW+AR simultaneous, W-before-AW) required explicit sampling after scenario execution due to simulator timing limitations with bus-level detection.

---

## Repository Structure

```
AXI_RAM_Verification/
├── README.md
├── design/                                  # DUT source (from alexforencich/verilog-axi)
│   └── axi_ram.v
├── verification/                            # UVM testbench files
│   ├── axi_if.sv                            #   AXI4 interface
│   ├── axi_ram_pkg.sv                       #   UVM package (env, agent, seqs, tests)
│   ├── axi_protocol_sva.sv                  #   14 SVA protocol assertions
│   └── tb_top.sv                            #   Top-level testbench
└── verification plan & report/
    └── verification plan/                   # Vplan
    └── verification report/                 # Vreport
```

---

## How to Run

**Platform:** [EDA Playground](https://www.edaplayground.com) → Aldec Riviera-PRO, UVM 1.2

1. Add all source files from `design/` and `verification/`
2. Set **Compile Options** for desired config (e.g., `+define+CFG_PIPELINE`)
3. Use this `run.do`:

```tcl
vsim +access+r +UVM_TESTNAME=axi_stress_test work.tb_top
run -all
exit
```

Change `+UVM_TESTNAME=` to run any of the 22 tests.

**With coverage:**

```tcl
vsim +access+r +UVM_TESTNAME=axi_stress_test work.tb_top
run -all
acdb save
acdb report -db fcover.acdb -txt -o cov.txt -verbose
exec cat cov.txt
exit
```

---

## Technologies

**SystemVerilog** · **UVM 1.2** · **SVA** · **Aldec Riviera-PRO** · **AXI4 (ARM IHI0022E/H)**

---

## Author

**Jaishyam Reddy Reddivari**
