# Verification Plan: `axi_ram` Module

- **Author:** Jaishyam Reddy Reddivari
- **Date:** February 2026
- **DUT Source:** [alexforencich/verilog-axi](https://github.com/alexforencich/verilog-axi) — `rtl/axi_ram.v`
- **Methodology:** UVM 1.2, SystemVerilog, constrained-random + directed
- **Spec Reference:** ARM IHI0022E/H — AMBA AXI Protocol Specification, Part A (AXI4)

---

## 1. DUT Overview

`axi_ram` is a single-port AXI4 slave RAM with the following characteristics:

| Property | Detail |
|---|---|
| Interface | Single AXI4 slave (5 channels: AW, W, B, AR, R) |
| Burst types | FIXED (0) and INCR (1). WRAP (2) is **not supported**. |
| Narrow bursts | Supported (AXSIZE < log2(DATA_WIDTH/8)) |
| Memory size | 2^ADDR_WIDTH bytes |
| Ordering | In-order (single-port, no reordering) |
| Pipeline option | PIPELINE_OUTPUT adds one register stage on the read data path |

### 1.1 Parameters

| Parameter | Default | Description |
|---|---|---|
| `DATA_WIDTH` | 32 | Data bus width in bits |
| `ADDR_WIDTH` | 16 | Address bus width in bits (64 KB memory) |
| `STRB_WIDTH` | DATA_WIDTH/8 | Byte strobe width (derived) |
| `ID_WIDTH` | 8 | Transaction ID width |
| `PIPELINE_OUTPUT` | 0 | Extra pipeline register on read output |

### 1.2 Interface Signals

All standard AXI4 slave signals prefixed `s_axi_*`:

- **AW channel:** awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid, awready
- **W channel:** wdata, wstrb, wlast, wvalid, wready
- **B channel:** bid, bresp, bvalid, bready
- **AR channel:** arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid, arready
- **R channel:** rid, rdata, rresp, rlast, rvalid, rready

---

## 2. Verification Architecture

```
┌─────────────────────────────────────────────────────┐
│                    axi_env                          │
│  ┌──────────────────────────────┐  ┌─────────────┐  │
│  │         axi_agent            │  │  scoreboard │  │
│  │  ┌─────┐ ┌──────┐ ┌───────┐  │  │  (ref model │  │
│  │  │ sqr │→│ drv  │→│  DUT  │  │  │   + checker)│  │
│  │  └─────┘ └──────┘ └───────┘  │  └──────┬──────┘  │
│  │              ┌───────┐       │         │         │
│  │              │  mon  │───────┼─────────┘         │
│  │              └───────┘       │  ┌─────────────┐  │
│  └──────────────────────────────┘  │  coverage   │  │
│                                    └─────────────┘  │
└─────────────────────────────────────────────────────┘
```

### 2.1 Components

| Component | Role |
|---|---|
| **axi_seq_item** | Transaction object: addr, id, len, size, burst, wdata[], wstrb[], rdata[], rresp[], bresp |
| **axi_driver** | Drives AW/W/B (writes) and AR/R (reads) on the DUT slave port. Supports concurrent AW+W, backpressure injection via configurable ready delays |
| **axi_monitor** | Passively observes all 5 channels. Emits complete write and read transactions via analysis ports |
| **axi_scoreboard** | Byte-addressable reference memory (associative array). Updates on monitored writes, checks on monitored reads. Implements INCR/FIXED address calculation and strobe masking |
| **axi_coverage** | Functional covergroups for burst parameters, address alignment, backpressure, ID usage |
| **axi_agent** | Contains driver, monitor, sequencer. Configurable active/passive |
| **axi_env** | Top-level environment. Instantiates agent, scoreboard, coverage. Connects analysis ports |

### 2.2 Reference Model

The scoreboard implements a black-box reference model:

**Write path:** For each observed write beat, calculate the target byte addresses based on burst type and AXSIZE, apply WSTRB byte masking, and update `ref_mem[addr]`.

**Read path:** For each observed read beat, reconstruct expected data from `ref_mem` using the same address calculation, then compare with actual RDATA.

**Address calculation (per AXI4 spec Section A3.4):**

```
INCR:  beat_addr[i] = aligned_addr + (i × number_bytes)
FIXED: beat_addr[i] = start_addr  (all beats same address)

where:
  number_bytes = 2^AXSIZE
  aligned_addr = (start_addr / number_bytes) × number_bytes
```

---

## 3. Feature Verification Matrix

### 3.1 Data Integrity (F-DI)

| ID | Feature | Stimulus | Check | Priority |
|---|---|---|---|---|
| F-DI-01 | Single write → readback | Write 1 beat to addr X, read back from X | RDATA == WDATA | P0 |
| F-DI-02 | Overwrite | Write A to addr X, write B to addr X, read X | RDATA == B | P0 |
| F-DI-03 | Distinct addresses | Write to N different addresses, read all back | Each matches | P0 |
| F-DI-04 | Full address space | Write/read at addr 0x0000 and 0xFFFC | Correct data | P1 |
| F-DI-05 | Uninitialized read | Read from never-written address | Returns 0x00 (expected default) | P1 |

### 3.2 Burst Types (F-BT)

| ID | Feature | Stimulus | Check | Priority |
|---|---|---|---|---|
| F-BT-01 | INCR burst write+read | INCR burst len=1..15, full-width | Data integrity across all beats | P0 |
| F-BT-02 | INCR burst max length | INCR burst len=255 (256 beats) | All 256 beats correct | P1 |
| F-BT-03 | FIXED burst write+read | FIXED burst len=1..15, verify only last beat's data persists at the address | Only final beat data at target addr | P0 |
| F-BT-04 | FIXED burst single-addr semantics | FIXED write 4 beats, then single read | Read returns last-written value | P0 |
| F-BT-05 | WRAP burst (unsupported) | Send WRAP burst | Document behavior (undefined — DUT may treat as INCR or corrupt) | P2 |
| F-BT-06 | FIXED burst len limit | FIXED burst with len=15 (max per AXI4 spec) | Correct data, no protocol error | P1 |
| F-BT-07 | 4KB boundary compliance | INCR burst that would cross a 4KB boundary is never generated | Seq item constraint prevents illegal burst; optional check that DUT does not corrupt if violated | P0 |
| F-BT-08 | Address space overflow | INCR burst starting near 0xFFFC that wraps the address space | Document behavior; scoreboard handles addr truncation or skips check | P1 |

### 3.3 Narrow Bursts (F-NB)

| ID | Feature | Stimulus | Check | Priority |
|---|---|---|---|---|
| F-NB-01 | 1-byte narrow write (AXSIZE=0) | Write single bytes to consecutive addresses on 32-bit bus | Each byte independently correct | P0 |
| F-NB-02 | 2-byte narrow write (AXSIZE=1) | Write halfwords | Correct halfword at correct byte lanes | P0 |
| F-NB-03 | Narrow INCR burst | AXSIZE=0, len=7, INCR burst | 8 individual bytes written to sequential addresses | P0 |
| F-NB-04 | Narrow FIXED burst | AXSIZE=0, len=3, FIXED burst | All 4 bytes write to same address, last wins | P1 |
| F-NB-05 | Mixed-width access | Wide write (AXSIZE=2), narrow read (AXSIZE=0) of same region | Byte-level data matches | P1 |
| F-NB-06 | Byte-lane steering | Narrow burst starting at unaligned address | Correct byte lanes active per beat per AXI spec | P0 |
| F-NB-07 | Narrow read — ignore undefined lanes | AXSIZE=0 read on 32-bit bus | Scoreboard only checks the active byte lane; ignores undefined lanes | P0 |
| F-NB-08 | Narrow burst lane wrap-around | AXSIZE=0, INCR, start_addr=0x03 on 4-byte bus → lanes cycle 3,0,1,2 | Byte written to correct address per lane rotation | P0 |

### 3.4 Write Strobes (F-WS)

| ID | Feature | Stimulus | Check | Priority |
|---|---|---|---|---|
| F-WS-01 | Partial strobe | Write with WSTRB = 4'b0110 | Only bytes 1-2 updated; bytes 0,3 unchanged | P0 |
| F-WS-02 | All strobes off | Write with WSTRB = 4'b0000 | No memory update | P1 |
| F-WS-03 | Single byte strobe | Write with WSTRB = 4'b0001, 4'b0010, etc. | Only targeted byte changes | P0 |
| F-WS-04 | Strobe in burst | Different WSTRB per beat in a burst | Each beat applies its own strobe correctly | P0 |
| F-WS-05 | Strobe + narrow interaction | AXSIZE=0, WSTRB must be consistent with active byte lane | Only legal strobe patterns; scoreboard validates | P0 |

### 3.5 Transaction Ordering and Concurrency (F-OC)

| ID | Feature | Stimulus | Check | Priority |
|---|---|---|---|---|
| F-OC-01 | W before AW | Drive all W beats (including WLAST) before asserting AWVALID | Write completes correctly; data integrity on readback | P0 |
| F-OC-02 | Simultaneous AR + AW | Assert ARVALID and AWVALID on the same cycle to different addresses | Both transactions complete; neither dropped | P0 |
| F-OC-03 | Read-after-write (zero gap) | Write to addr X, issue read to addr X on the very next cycle | Read returns freshly written data | P0 |
| F-OC-04 | Write-write same addr (zero gap) | Write A to addr X, immediately write B to addr X, then read | Read returns B | P0 |
| F-OC-05 | Outstanding writes | Issue second AW while BREADY held low on first txn's B channel | Both writes complete, data correct for both | P1 |
| F-OC-06 | Outstanding reads | Issue second AR while first read burst still returning data (RREADY toggling) | Both reads return correct data | P1 |

### 3.6 ID Signal Correctness (F-ID)

| ID | Feature | Stimulus | Check | Priority |
|---|---|---|---|---|
| F-ID-01 | BID echo | Write with AWID=N | BID == N | P0 |
| F-ID-02 | RID echo | Read with ARID=M | RID == M on all R beats | P0 |
| F-ID-03 | Varying IDs | Sequential transactions with different IDs | Each response has correct ID | P0 |
| F-ID-04 | ID range | Use IDs 0, 1, 127, 255 (full ID_WIDTH range) | All echo correctly | P1 |

### 3.7 Response Codes (F-RC)

| ID | Feature | Stimulus | Check | Priority |
|---|---|---|---|---|
| F-RC-01 | BRESP = OKAY | Normal writes | BRESP == 2'b00 | P0 |
| F-RC-02 | RRESP = OKAY | Normal reads | RRESP == 2'b00 on all beats | P0 |
| F-RC-03 | RLAST correctness | Any read burst | RLAST asserted on exactly the (ARLEN+1)th beat | P0 |

### 3.8 Protocol Compliance (F-PC)

| ID | Feature | Stimulus | Check Method | Priority |
|---|---|---|---|---|
| F-PC-01 | AWREADY behavior | Drive AWVALID, observe AWREADY | Assertion: handshake completes | P0 |
| F-PC-02 | WREADY behavior | Drive WVALID, observe WREADY | Assertion: handshake completes | P0 |
| F-PC-03 | ARREADY behavior | Drive ARVALID, observe ARREADY | Assertion: handshake completes | P0 |
| F-PC-04 | RVALID stable | Once RVALID asserted, it stays high until RREADY | SVA assertion | P0 |
| F-PC-05 | BVALID stable | Once BVALID asserted, it stays high until BREADY | SVA assertion | P0 |
| F-PC-06 | RDATA stable | RDATA must not change while RVALID=1 and RREADY=0 | SVA assertion | P0 |
| F-PC-07 | BRESP stable | BRESP must not change while BVALID=1 and BREADY=0 | SVA assertion | P0 |
| F-PC-08 | Reset behavior (idle) | Assert rst while DUT is idle, observe all outputs | All VALID signals deasserted after reset | P0 |
| F-PC-09 | Reset mid-write-burst | Assert rst between beat 2 and 3 of a write burst | All outputs deassert cleanly; DUT accepts new transactions after rst release | P0 |
| F-PC-10 | Reset mid-read-burst | Assert rst during an active read response burst | All outputs deassert cleanly; DUT recovers | P0 |
| F-PC-11 | Post-reset functional recovery | After mid-transaction reset, run full write+readback sequence | Data integrity passes on post-reset transactions | P0 |

### 3.9 Backpressure and Timing (F-BP)

| ID | Feature | Stimulus | Check | Priority |
|---|---|---|---|---|
| F-BP-01 | Slow BREADY | Deassert BREADY for 0-10 random cycles after BVALID | Transaction still completes correctly | P0 |
| F-BP-02 | Slow RREADY | Deassert RREADY for 0-10 random cycles during read burst | All beats received correctly | P0 |
| F-BP-03 | WVALID gaps | Insert random idle cycles between W beats | Write completes, data correct | P1 |
| F-BP-04 | Back-to-back writes | No idle between consecutive write transactions | All data correct | P0 |
| F-BP-05 | Back-to-back reads | No idle between consecutive read transactions | All data correct | P0 |
| F-BP-06 | Sustained stress | 100+ random transactions with random backpressure | Zero scoreboard errors | P1 |

### 3.10 Pipeline Output (F-PO)

| ID | Feature | Stimulus | Check | Priority |
|---|---|---|---|---|
| F-PO-01 | Basic read with PIPELINE_OUTPUT=1 | Single write+read | Data correct (latency may differ) | P0 |
| F-PO-02 | Burst read with PIPELINE_OUTPUT=1 | INCR burst read | All beats correct | P0 |
| F-PO-03 | Backpressure with pipeline | Random RREADY toggling, PIPELINE_OUTPUT=1 | No data corruption or protocol violation | P1 |
| F-PO-04 | RAW hazard with pipeline | PIPELINE_OUTPUT=1, write then immediate read to same addr | Read returns written data, not stale | P0 |

---

## 4. Functional Coverage Plan

### 4.1 Transaction Coverage

```systemverilog
covergroup axi_txn_cg;
  cp_txn_type:  coverpoint txn_type { bins wr = {WRITE}; bins rd = {READ}; }
  cp_burst:     coverpoint burst    { bins fixed = {0}; bins incr = {1}; }
  cp_size:      coverpoint size     { bins b1 = {0}; bins b2 = {1}; bins b4 = {2}; }
  cp_len:       coverpoint len      {
    bins single = {0};
    bins short  = {[1:3]};
    bins medium = {[4:15]};
    bins long   = {[16:63]};
    bins max    = {[64:255]};
  }
  cp_id:        coverpoint id       {
    bins low    = {[0:3]};
    bins mid    = {[4:127]};
    bins high   = {[128:255]};
  }

  // Key crosses
  cx_burst_x_size: cross cp_burst, cp_size;
  cx_burst_x_len:  cross cp_burst, cp_len;
  cx_type_x_burst: cross cp_txn_type, cp_burst;
endgroup
```

### 4.2 Address Coverage

```systemverilog
covergroup axi_addr_cg;
  cp_alignment: coverpoint addr[1:0] {
    bins aligned   = {0};
    bins unaligned = {[1:3]};
  }
  cp_addr_region: coverpoint addr[ADDR_WIDTH-1:ADDR_WIDTH-2] {
    bins bottom  = {0};
    bins mid_lo  = {1};
    bins mid_hi  = {2};
    bins top     = {3};
  }
  cp_near_4kb: coverpoint (addr[11:0]) {
    bins near_boundary = {[12'hFF0:12'hFFF]};
    bins normal        = default;
  }
  cp_addr_top_of_mem: coverpoint (addr >= 16'hFFF0) {
    bins near_top = {1};
    bins normal   = {0};
  }
endgroup
```

### 4.3 Write Strobe Coverage

```systemverilog
covergroup axi_wstrb_cg;
  cp_strb: coverpoint wstrb {
    bins all_on    = {4'b1111};
    bins all_off   = {4'b0000};
    bins single[4] = {4'b0001, 4'b0010, 4'b0100, 4'b1000};
    bins partial   = default;
  }
endgroup
```

### 4.4 Backpressure Coverage

```systemverilog
covergroup axi_bp_cg;
  cp_rready_delay: coverpoint rready_delay {
    bins none     = {0};
    bins short    = {[1:3]};
    bins medium   = {[4:10]};
  }
  cp_bready_delay: coverpoint bready_delay {
    bins none     = {0};
    bins short    = {[1:3]};
    bins medium   = {[4:10]};
  }
endgroup
```

### 4.5 Concurrency and Ordering Coverage

```systemverilog
covergroup axi_concurrency_cg;
  cp_aw_ar_simultaneous: coverpoint (awvalid_seen && arvalid_seen_same_clk) {
    bins simultaneous = {1};
    bins sequential   = {0};
  }
  cp_w_before_aw: coverpoint w_before_aw_seen {
    bins yes = {1};
    bins no  = {0};
  }
  cp_raw_zero_gap: coverpoint raw_zero_gap_seen {
    bins yes = {1};
    bins no  = {0};
  }
endgroup
```

### 4.6 Coverage Targets

| Covergroup | Target |
|---|---|
| axi_txn_cg (including crosses) | 100% |
| axi_addr_cg | 100% |
| axi_wstrb_cg | 95%+ |
| axi_bp_cg | 100% |

---

## 5. Assertion Plan (SVA)

These are interface-level protocol assertions, placed in the `axi_if` interface or a bind module.

| ID | Assertion | Property |
|---|---|---|
| SVA-01 | VALID-before-READY stability | Once xVALID is asserted, it must stay high until xREADY (per AXI spec A3.2.1) |
| SVA-02 | Data stable while waiting | When xVALID=1 and xREADY=0, all payload signals on that channel must remain stable |
| SVA-03 | WLAST correctness | WLAST must be asserted on exactly the beat that corresponds to AWLEN+1 |
| SVA-04 | RLAST correctness | RLAST must be asserted on exactly the beat that corresponds to ARLEN+1 |
| SVA-05 | BID matches AWID | BID in write response must equal the AWID of the corresponding write |
| SVA-06 | RID matches ARID | RID on all R beats must equal ARID of the corresponding read |
| SVA-07 | No B without W | BVALID must not assert before WLAST is accepted |
| SVA-08 | Reset clears outputs | On rst assertion, AWREADY, WREADY, BVALID, ARREADY, RVALID must all deassert within 1 cycle of rst deassertion |
| SVA-09 | BRESP valid range | BRESP must be 2'b00 (OKAY) for all normal accesses |
| SVA-10 | RRESP valid range | RRESP must be 2'b00 (OKAY) for all normal accesses |
| SVA-11 | BID stable | BID must not change while BVALID=1 and BREADY=0 |
| SVA-12 | RID stable | RID must not change while RVALID=1 and RREADY=0 |
| SVA-13 | RLAST stable | RLAST must not change while RVALID=1 and RREADY=0 |
| SVA-14 | No RVALID before ARREADY | RVALID must not assert for a transaction before the corresponding AR handshake completes |

---

## 6. Test Plan

### 6.1 Test List

| Test Name | Description | Features Covered | Type |
|---|---|---|---|
| `axi_base_test` | Reset-only smoke test, confirms compile and reset behavior | F-PC-08 | Directed |
| `axi_single_rw_test` | N single write-readback pairs to sequential addresses | F-DI-01, F-DI-03, F-ID-01, F-ID-02, F-RC-01, F-RC-02 | Directed |
| `axi_burst_test` | Randomized INCR bursts (len 1-15), write+readback | F-BT-01, F-BT-07, F-RC-03 | Constrained-random |
| `axi_fixed_burst_test` | FIXED burst writes, verify last-beat semantics | F-BT-03, F-BT-04, F-BT-06 | Directed |
| `axi_narrow_burst_test` | AXSIZE=0 and AXSIZE=1 on 32-bit bus, including unaligned starts | F-NB-01 through F-NB-08 | Constrained-random |
| `axi_strobe_test` | Partial WSTRB patterns, verify byte-level masking | F-WS-01 through F-WS-05 | Directed + random |
| `axi_backpressure_test` | Random BREADY/RREADY delays during all transaction types | F-BP-01 through F-BP-06 | Constrained-random |
| `axi_w_before_aw_test` | Drive all W beats before AW on multiple transactions | F-OC-01 | Directed |
| `axi_concurrent_ar_aw_test` | Drive AR and AW simultaneously, verify both complete | F-OC-02, F-OC-05, F-OC-06 | Directed |
| `axi_raw_hazard_test` | Write then immediate read to same addr, zero idle cycles | F-OC-03, F-OC-04 | Directed |
| `axi_reset_mid_txn_test` | Assert reset during active write and read bursts, then verify recovery | F-PC-09, F-PC-10, F-PC-11 | Directed |
| `axi_stress_test` | 500+ random transactions, all burst types, random backpressure, random ordering | All F-DI, F-BT, F-NB, F-BP, F-OC | Constrained-random |
| `axi_id_test` | Sweep ID values across full range | F-ID-03, F-ID-04 | Directed |
| `axi_max_burst_test` | len=255 INCR burst | F-BT-02 | Directed |
| `axi_addr_boundary_test` | Access addr 0x0000, 0xFFFC, near 4KB boundaries, near top of memory | F-DI-04, F-BT-07, F-BT-08 | Directed |
| `axi_pipeline_test` | Repeat key tests with PIPELINE_OUTPUT=1 including RAW hazard | F-PO-01 through F-PO-04 | Regression |

### 6.2 Regression Configurations

| Config | DATA_WIDTH | ADDR_WIDTH | ID_WIDTH | PIPELINE_OUTPUT |
|---|---|---|---|---|
| default | 32 | 16 | 8 | 0 |
| pipeline | 32 | 16 | 8 | 1 |
| wide_bus | 64 | 16 | 8 | 0 |
| narrow_id | 32 | 16 | 4 | 0 |
| small_mem | 32 | 12 | 8 | 0 |

---

## 7. Pass/Fail Criteria

A regression run passes when **all** of the following are true:

1. **Zero UVM_ERROR or UVM_FATAL** across all tests in all configurations
2. **Scoreboard:** 0 data mismatches (write-readback integrity)
3. **Assertions:** 0 SVA failures
4. **Coverage:**
   - All functional covergroups hit targets per Section 4.5
   - All crosses in `axi_txn_cg` at 100%
5. **All tests in Section 6.1** pass in all configurations in Section 6.2

---

## 8. Assumptions and Exclusions

### Assumptions
- Memory initializes to all zeros
- DUT processes transactions in-order (single-port, no write-read interleaving)
- AWLOCK, AWCACHE, AWPROT, ARCACHE, ARLOCK, ARPROT are tied to default values and have no functional impact on data storage/retrieval
- Stimulus respects the 4KB boundary rule (enforced via seq_item constraints); no burst crosses a 4KB boundary
- For narrow reads, byte lanes outside the active transfer are undefined per AXI spec; scoreboard must mask these bytes and not compare them
- FIXED bursts are constrained to AXLEN ≤ 15 per AXI4 spec requirement

### Exclusions (Not in Scope)
- **WRAP burst type:** Not supported by DUT, not verified (F-BT-05 is informational only)
- **Exclusive access (AWLOCK=1):** Not supported by this simple RAM
- **Quality of Service:** No QOS signals on this DUT
- **Formal verification:** Out of scope for this project (but SVA assertions provide lightweight formal-adjacent checking)
- **Performance/latency measurement:** Not a verification goal; focus is functional correctness

---

## 9. Schedule

| Day | Milestone |
|---|---|
| 1 | Env skeleton compiles. `axi_base_test` runs. Interface + driver + monitor functional. |
| 2 | Driver handles all burst types. `axi_single_rw_test` and `axi_burst_test` pass with scoreboard. |
| 3 | Scoreboard handles FIXED + narrow bursts. `axi_fixed_burst_test` and `axi_narrow_burst_test` pass. |
| 4 | Strobe tests, ID tests, SVA assertions added. `axi_strobe_test` and `axi_id_test` pass. |
| 5 | Backpressure sequence, coverage collectors, `axi_stress_test`. Coverage analysis begins. |
| 6 | PIPELINE_OUTPUT=1 config, wide-bus config. Full regression across all 5 configs. Coverage hole filling. |
| 7 | Documentation, coverage report, code cleanup, README. Dry-run interview walkthrough. |└─────────────────────────────────────────────────────┘
