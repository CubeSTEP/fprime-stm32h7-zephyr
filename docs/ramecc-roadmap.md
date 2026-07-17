# STM32H7 RAM ECC Protection Design and Roadmap

## 1. Purpose

This document defines the intended RAM error correction code (ECC) protection
architecture for F Prime applications running on Zephyr on the STM32H723 and
STM32H753. It covers:

- startup initialization of ECC-protected memories;
- STM32 RAMECC monitor and interrupt handling;
- correctable and uncorrectable fault policy;
- background memory scrubbing;
- fault injection and verification;
- reset-cause and fault-record persistence;
- the boundary between the low-level Zephyr service and F Prime;
- the proposed F Prime `RamEccMonitor` component;
- the implementation and verification roadmap.

This is a design and planning document. A file or interface described as
"proposed" is not necessarily implemented yet.

## 2. Goals and non-goals

### 2.1 Goals

The completed system shall:

1. Initialize ECC-protected RAM before unsafe reads can occur.
2. Enable the applicable RAMECC monitors for each supported MCU.
3. Detect and record corrected single-bit errors.
4. Detect uncorrectable double-bit errors and transition to a controlled reset
   or safe-state policy.
5. Periodically scrub approved RAM regions so a corrected single-bit error is
   written back before a second bit can fail in the same ECC word.
6. Preserve enough information to diagnose an ECC-triggered reset on the next
   boot.
7. Report health, counts, last-fault information, and scrubber progress through
   F Prime telemetry and events.
8. Provide repeatable test-only fault injection for both supported boards.

### 2.2 Non-goals

- RAMECC is not a replacement for the Zephyr generic fault handler.
- `CONFIG_FAULT_DUMP` does not enable or service RAMECC.
- The interrupt handler will not directly call F Prime APIs.
- The first implementation will not scrub every byte of live application RAM
  without an ownership and synchronization policy.
- MCUboot is not required for initial RAMECC development. Supporting ECC while
  MCUboot itself executes is a separate image-integration task.
- External memories are outside the initial scope.

## 3. Configuration ownership

The reusable module defines one public option in
[`zephyr/Kconfig`](../zephyr/Kconfig):

```kconfig
config FPRIME_STM32H7_RAMECC
    bool "Enable STM32H7 RAM ECC protection"
    depends on SOC_STM32H723XX || SOC_STM32H753XX
    select USE_STM32_HAL_RAMECC
    select REBOOT
```

If the scrubber uses the STM32 HAL MDMA implementation, the same option also
selects `USE_STM32_HAL_MDMA`. A separate user-facing switch is not required.

The consuming application's `prj.conf` enables the module:

```conf
CONFIG_FPRIME_STM32H7_RAMECC=y
```

Development builds may additionally keep:

```conf
CONFIG_FAULT_DUMP=2
```

The application shall not directly assign the hidden
`CONFIG_USE_STM32_HAL_RAMECC` symbol. The deprecated
`CONFIG_PLATFORM_SPECIFIC_INIT` symbol is not part of this design.

After a pristine configuration, the generated Zephyr `.config` should contain:

```text
CONFIG_FPRIME_STM32H7_RAMECC=y
CONFIG_USE_STM32_HAL_RAMECC=y
CONFIG_REBOOT=y
```

It should also contain `CONFIG_USE_STM32_HAL_MDMA=y` when the implementation
uses HAL MDMA.

## 4. Intended project structure

```text
fprime-stm32h7-zephyr/
├── zephyr/
│   ├── module.yml                  # Zephyr module registration
│   ├── Kconfig                     # Public feature option and HAL selections
│   └── CMakeLists.txt              # Adds low-level sources to the Zephyr image
├── ramecc/
│   ├── include/
│   │   └── ramecc.h                # C API shared with the F Prime adapter
│   └── src/
│       ├── ramecc.c                # Monitor init, IRQ, records, recovery policy
│       └── mem_scrubber.c          # Low-priority background scrub service
├── fprime-stm32h7-zephyr/
│   ├── config/
│   │   ├── CMakeLists.txt
│   │   └── Stm32h7Cfg.hpp
│   └── Svc/
│       └── RamEccMonitor/           # Proposed F Prime component
│           ├── CMakeLists.txt
│           ├── RamEccMonitor.fpp
│           ├── RamEccMonitor.hpp
│           ├── RamEccMonitor.cpp
│           └── docs/
│               └── sdd.md
├── docs/
│   └── ramecc-roadmap.md
└── library.cmake                   # Registers F Prime config/component folders
```

The low-level service is compiled by Zephyr through
[`zephyr/CMakeLists.txt`](../zephyr/CMakeLists.txt). The proposed F Prime
component is compiled later through the F Prime library build. These are two
integration paths with a deliberately small C API between them.

## 5. Runtime architecture

```text
CPU reset
   |
   v
Zephyr STM32H7 soc_reset_hook()
   |  Initializes selected ITCM/DTCM ECC words
   v
Zephyr kernel initialization
   |
   v
RAMECC SYS_INIT function
   |  Configures monitors, latching, notifications, and ECC_IRQn
   v
Background scrubber becomes available
   |
   v
Application main() -> Os::init() -> F Prime topology setup
   |
   v
RamEccMonitor component polls the low-level snapshot
   |  Emits telemetry/events and accepts non-blocking commands
   v
Normal application operation
```

Zephyr already supplies the STM32H7 `soc_reset_hook()` used to initialize
selected TCM regions. This module shall not provide another function with the
same symbol. RAMECC configuration belongs in a Zephyr `SYS_INIT()` function in
`ramecc.c`.

## 6. Low-level RAMECC service

### 6.1 Responsibilities of `ramecc.c`

[`ramecc/src/ramecc.c`](../ramecc/src/ramecc.c) shall own:

- the MCU-specific RAMECC monitor table;
- a `RAMECC_HandleTypeDef` for every enabled monitor;
- initialization and validation of each monitor;
- global and per-monitor notification enablement;
- `ECC_IRQn` connection and enablement;
- dispatch from the global ECC ISR to the monitor that raised a flag;
- capture of the failing address, data, Hamming code, monitor, and error type;
- cumulative correctable and uncorrectable error counts;
- a small reboot-surviving fault record where supported;
- the immediate policy for an uncorrectable error;
- a thread-safe snapshot API for the F Prime component.

It shall not own F Prime telemetry, events, commands, or topology objects.

### 6.2 Monitor table

STM32H723 and STM32H753 do not have identical monitor layouts. The source shall
use separate compile-time tables:

```c
#if defined(CONFIG_SOC_STM32H723XX)
/* H723 monitor-to-memory mapping validated against RM0468. */
#elif defined(CONFIG_SOC_STM32H753XX)
/* H753 monitor-to-memory mapping validated against RM0433. */
#else
#error "Unsupported STM32H7 RAMECC layout"
#endif
```

Each table entry should contain at least:

```text
HAL monitor instance
parent RAMECC controller
logical monitor identifier
protected memory name
protected address range
ECC word size
whether the region is eligible for background scrubbing
```

The table must be derived from the reference manual rather than inferred from
monitor numbering.

### 6.3 Initialization sequence

The intended initialization sequence is:

1. Construct each `RAMECC_HandleTypeDef` and assign its monitor instance.
2. Call `HAL_RAMECC_Init()` and verify `HAL_OK`.
3. Clear or account for stale status flags.
4. Enable monitor error latching with `HAL_RAMECC_StartMonitor()`.
5. Enable the required single-read, double-read, and double-byte-write
   notifications.
6. Enable the appropriate parent/global notification bits.
7. Connect the Zephyr handler to `ECC_IRQn`.
8. Enable `ECC_IRQn` only after every handle is ready.
9. Publish initialization success or failure through the low-level snapshot.

Conceptually:

```c
static int ramecc_init(void)
{
    /* Initialize monitor table and handles. */
    /* Connect and enable ECC_IRQn after successful setup. */
    return 0;
}

SYS_INIT(ramecc_init, POST_KERNEL, CONFIG_KERNEL_INIT_PRIORITY_DEVICE);
```

Initialization shall fail closed: if the configuration says RAM ECC protection
is enabled but a required monitor cannot be initialized, the application must
not silently continue as if protection were active. The final policy may be a
controlled reboot, fatal error, or a latched degraded-health state, but it must
be explicit and testable.

### 6.4 Interrupt behavior

The global ISR shall remain short and bounded:

1. Identify monitors with an active status flag.
2. Call `HAL_RAMECC_IRQHandler()` for those handles or perform the equivalent
   register capture and clearing sequence.
3. Capture diagnostic information before it can be overwritten.
4. Update only ISR-safe state.
5. Request deferred processing or reboot according to the error class.

The ISR shall not log through F Prime, allocate memory, take a blocking mutex,
write flash, or wait for the scrubber.

### 6.5 Correctable error policy

For a corrected single-bit error:

1. Capture the monitor, failing address, failing data, and Hamming code.
2. Increment the correctable error count.
3. Mark the affected address or region for prioritized scrubbing.
4. Allow execution to continue unless the configured rate or recurrence policy
   has been exceeded.
5. Let the F Prime component report the event from thread context.

A hardware-corrected read does not by itself guarantee that the physical ECC
word has been repaired. The corrected value must be written back using a safe,
full-width operation.

### 6.6 Uncorrectable error policy

For a detected double-bit error:

1. Capture the diagnostic record immediately.
2. Mark it valid using a final commit field, magic value, and integrity check.
3. Prevent continued use of the affected memory when practical.
4. Request `sys_reboot(SYS_REBOOT_COLD)` or invoke the approved platform
   safe-state policy.

Continuing arbitrary execution after an uncorrectable error is not the default
policy because the returned data cannot be trusted.

### 6.7 Fault-record persistence

The minimum proposed retained record is:

```c
struct ramecc_fault_record {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t sequence;
    uint32_t monitor_id;
    uint32_t failing_address;
    uint32_t failing_data_low;
    uint32_t failing_data_high;
    uint32_t hamming_code;
    uint32_t error_type;
    uint32_t crc;
};
```

Potential storage strategies, in increasing durability, are:

1. a `.noinit` region that survives a processor reset;
2. backup SRAM, with the relevant clock and retention requirements handled;
3. copying the retained record to normal persistent storage early on the next
   boot.

Writing flash from the ECC ISR is not part of this design. Power loss and reset
semantics for `.noinit` and backup SRAM must be verified on both boards.

## 7. Background memory scrubber

### 7.1 Responsibilities of `mem_scrubber.c`

[`ramecc/src/mem_scrubber.c`](../ramecc/src/mem_scrubber.c) shall own:

- the approved scrub-region list;
- the current region and address cursor;
- periodic, bounded scrub work;
- complete-pass and byte counters;
- cache maintenance required by the selected access method;
- prioritization of an address reported by the RAMECC ISR;
- timeout, transfer, and verification failure counters;
- pause/resume/request state exposed through the C API.

“Idle scrubbing” means a low-priority, rate-limited background activity. It does
not mean modifying Zephyr's idle thread. A dedicated low-priority thread or a
carefully bounded delayable work item is preferred.

### 7.2 Scrub operation

At the conceptual level, a scrub operation performs:

```text
read a complete, aligned ECC word
        |
        v
hardware returns corrected data for a single-bit error
        |
        v
write the corrected complete word back
        |
        v
memory regenerates the ECC bits
```

The actual word width is memory-dependent. AN5342 and the relevant MCU
reference manual are authoritative.

### 7.3 Concurrency and ownership

Blindly reading and rewriting live application memory is unsafe. Another thread
or DMA controller could modify a word between the scrubber's read and write,
causing the scrubber to restore stale data.

The initial scrub region set shall therefore be limited to memory with a proven
ownership policy, for example:

- reserved scrub-test memory;
- static pools protected by a lock or quiescence protocol;
- inactive partitions or buffers;
- application regions for which the write-back race is otherwise prevented.

Stack memory, active DMA buffers, heap metadata, shared lock-free structures,
memory-mapped peripherals, and flash shall not be added merely because they
fall between broad linker addresses.

### 7.4 CPU-first and MDMA phases

The reference implementation should first prove the algorithm with aligned CPU
read/write operations on a reserved test region. This minimizes variables while
validating RAMECC detection and correction.

MDMA may then be introduced to reduce CPU load. The MDMA implementation must
define:

- channel ownership;
- source and destination transfer widths;
- whether a scratch buffer is required;
- completion and timeout handling;
- cache-line alignment;
- cache flush/invalidate operations;
- behavior when the target is concurrently accessed;
- whether self-copy is supported and safe on the selected memory bus.

MDMA does not remove the concurrency problem, and Zephyr's DMA layer does not
automatically solve Cortex-M7 cache coherency.

### 7.5 Scheduling policy

A scrub pass should be divided into small chunks. After each chunk, the
scrubber sleeps or yields so it cannot starve F Prime rate groups or device
drivers. The following values must be measured and then selected:

```text
chunk size
delay between chunks
thread priority
maximum bus utilization
maximum time for a complete pass
timeout per MDMA operation
```

The scrub period should be justified from the expected upset rate and mission
reliability requirement, not chosen only for convenience.

## 8. Low-level public C API

[`ramecc/include/ramecc.h`](../ramecc/include/ramecc.h) is the only interface
the F Prime component should require. The proposed API is intentionally
snapshot- and request-based:

```c
enum ramecc_error_type {
    RAMECC_ERROR_NONE = 0,
    RAMECC_ERROR_CORRECTABLE,
    RAMECC_ERROR_UNCORRECTABLE,
    RAMECC_ERROR_BYTE_WRITE_DOUBLE
};

struct ramecc_status {
    bool initialized;
    bool scrubber_running;
    uint32_t correctable_count;
    uint32_t uncorrectable_count;
    uint32_t scrub_pass_count;
    uint32_t scrub_error_count;
    uint32_t scrub_region;
    uintptr_t scrub_address;
    struct ramecc_fault_record last_fault;
};

bool ramecc_get_status(struct ramecc_status *status);
bool ramecc_get_retained_fault(struct ramecc_fault_record *record);
int ramecc_request_scrub(void);
int ramecc_prioritize_address(uintptr_t address);
void ramecc_clear_counts(void);
void ramecc_clear_retained_fault(void);
```

Exact names may change during implementation, but the properties shall remain:

- no F Prime type appears in the C API;
- status reads return a consistent snapshot;
- commands submit requests rather than performing long operations inline;
- ISR-owned fields use atomics, a short spin lock, or another ISR-safe snapshot
  strategy;
- APIs document whether they are callable from ISR or thread context.

## 9. Proposed F Prime `RamEccMonitor` component

### 9.1 Purpose

`RamEccMonitor` converts the low-level RAMECC service state into F Prime
telemetry, events, command responses, and health reporting. It does not
initialize hardware and is not on the immediate fault-response path.

The component should initially be passive and invoked by a rate group. A
passive component avoids another thread and stack because the actual scrubber
already runs in Zephyr context. All component handlers must remain non-blocking.

### 9.2 Component responsibilities

The component shall:

1. Poll `ramecc_get_status()` at a configured rate.
2. Emit an event when a new correctable error is observed.
3. Report any retained uncorrectable record from the previous boot.
4. Publish current counters and scrubber progress as telemetry.
5. Respond to status, clear, and scrub-request commands.
6. Report initialization or scrubber failures.
7. Participate in F Prime health pinging if required by the deployment.

The component shall not:

- access STM32 RAMECC registers directly;
- own `ECC_IRQn`;
- perform an MDMA transfer in a command handler;
- call HAL RAMECC functions;
- decide the immediate ISR reboot policy;
- expose production fault injection without a test-only build guard.

### 9.3 Proposed ports

| Port | Direction | Purpose |
| --- | --- | --- |
| `schedIn` | input | Periodic call from a rate group to sample status and emit telemetry. |
| `cmdIn` | input | Receive F Prime commands. |
| `cmdRegOut` | output | Register component commands. |
| `cmdResponseOut` | output | Return command completion status. |
| `eventOut` | output | Emit diagnostic and health events. |
| `textEventOut` | output | Optional text event support used by the project. |
| `tlmOut` | output | Publish ECC and scrubber telemetry. |
| `timeCaller` | output | Timestamp events and telemetry. |
| `pingIn` / `pingOut` | input/output | Optional integration with the deployment health component. |

The final port set should follow the conventions already used by the Cerberus
topology and the selected F Prime version.

### 9.4 Proposed commands

| Command | Intended behavior |
| --- | --- |
| `RAM_ECC_STATUS` | Emit a status event and refresh telemetry immediately. |
| `RAM_ECC_SCRUB_NOW` | Submit a non-blocking request for a scrub pass. |
| `RAM_ECC_CLEAR_COUNTS` | Clear software counters after recording the action. |
| `RAM_ECC_CLEAR_RETAINED` | Clear the previously consumed retained fault record. |

Fault injection should use a dedicated development/test build. If an F Prime
test command is added, it must be compiled out of production and require an
explicit test address inside a reserved injection region.

### 9.5 Proposed telemetry channels

| Channel | Meaning |
| --- | --- |
| `Initialized` | Whether required RAMECC monitors initialized successfully. |
| `CorrectableCount` | Total corrected single-bit errors observed. |
| `UncorrectableCount` | Total detected double-bit errors observed in the retained/runtime record. |
| `LastErrorType` | Classification of the last error. |
| `LastMonitor` | Logical monitor that reported the last error. |
| `LastFailingAddress` | Reconstructed failing memory address. |
| `LastHammingCode` | Captured failing ECC/Hamming code. |
| `ScrubberRunning` | Whether background scrub work is enabled and healthy. |
| `ScrubPassCount` | Number of completed scrub passes. |
| `ScrubRegion` | Current logical scrub region. |
| `ScrubAddress` | Current or most recently completed scrub address. |
| `ScrubErrorCount` | MDMA, timeout, validation, or other scrub failures. |
| `PreviousBootEccReset` | Whether a valid retained ECC fault was recovered at boot. |

Address telemetry may need to use a 64-bit F Prime type even though the current
STM32 targets use 32-bit addresses, so the dictionary remains portable.

### 9.6 Proposed events

| Event | Severity intent | Meaning |
| --- | --- | --- |
| `RAMECC_INIT_OK` | activity/high | All required monitors initialized. |
| `RAMECC_INIT_FAILED` | fatal/warning-high | A required monitor could not be configured. |
| `RAMECC_CORRECTED` | warning-low | A new single-bit error was corrected and recorded. |
| `RAMECC_UNCORRECTABLE_RECORDED` | warning-high | The previous boot ended after an uncorrectable error. |
| `RAMECC_RATE_EXCEEDED` | warning-high | Correctable errors exceeded the approved threshold. |
| `SCRUB_PASS_COMPLETE` | activity/low | A complete approved-region scrub pass finished. |
| `SCRUB_FAILED` | warning-high | A scrub transfer, cache operation, timeout, or validation failed. |
| `RETAINED_RECORD_INVALID` | warning-low | A retained record failed magic/version/CRC validation. |

Event throttling is required for repeated correctable errors so a failing
memory location cannot saturate event storage or downlink.

### 9.7 Component lifecycle

During component initialization:

1. Read the low-level status snapshot.
2. Validate and consume any retained previous-boot record.
3. Emit an initialization or degraded-health event.
4. Publish an initial telemetry set.

On each `schedIn` call:

1. Read a fresh consistent snapshot.
2. Compare sequence numbers and counters with the prior snapshot.
3. Emit only newly observed events.
4. Update telemetry at the configured cadence.
5. Check correctable-error recurrence and rate thresholds.

Command handlers submit a request through the C API and return promptly. The
component observes completion during a later scheduled call.

### 9.8 F Prime build integration

When the component exists,
[`library.cmake`](../library.cmake) should add its directory alongside the
existing configuration directory:

```cmake
add_fprime_subdirectory(
    "${CMAKE_CURRENT_LIST_DIR}/fprime-stm32h7-zephyr/Svc/RamEccMonitor"
)
```

The component must then be instantiated and connected in the Cerberus topology.
The topology should connect `schedIn` to an appropriate low-rate group rather
than a high-rate control loop.

## 10. Fault flows

### 10.1 Correctable error

```text
RAM read detects one bad bit
   -> hardware returns corrected data
   -> ECC_IRQn fires
   -> ramecc.c captures and counts the error
   -> address is queued for prioritized scrub
   -> scrubber safely writes back the corrected ECC word
   -> RamEccMonitor observes a new sequence/count
   -> F Prime event and telemetry are emitted
```

### 10.2 Uncorrectable error

```text
RAM access detects two bad bits
   -> ECC_IRQn fires
   -> ramecc.c captures the minimal retained record
   -> record commit/magic/CRC is finalized
   -> system performs controlled reset
   -> Zephyr and F Prime initialize on the next boot
   -> RamEccMonitor validates and reports the retained record
   -> record is copied to durable storage or cleared by policy
```

## 11. Verification strategy

### 11.1 Unit and host tests

The low-level policy should be separated enough to test monitor-table lookup,
fault classification, counters, retained-record validation, CRC handling, and
snapshot sequencing without real RAMECC hardware.

The F Prime component unit tests should mock the C API and verify:

- startup with no retained fault;
- startup with a valid retained uncorrectable fault;
- invalid retained record handling;
- one and repeated correctable errors;
- event throttling;
- status and clear commands;
- scrub request acceptance and failure;
- telemetry contents and cadence.

### 11.2 Hardware tests

Each test must be executed independently on STM32H723 and STM32H753:

1. Boot with RAMECC enabled and verify no false error.
2. Confirm every intended monitor is active.
3. Inject one correctable error into a reserved test word.
4. Verify interrupt, monitor identity, address, data, Hamming code, and count.
5. Verify the corrected word is rewritten by the scrubber.
6. Inject a double-bit error into the reserved test word.
7. Verify the retained record and controlled reset.
8. Verify the next boot reports the previous fault once.
9. Run repeated scrub passes while normal F Prime workloads execute.
10. Measure CPU load, bus utilization, rate-group jitter, and complete-pass time.
11. Test cache-enabled and cache-maintenance paths.
12. Test reset, power-cycle, watchdog, and debugger-reset effects on the retained
    record.

Fault injection shall never target application code, the current stack, heap
metadata, topology objects, or an active DMA buffer. A linker-reserved test
region is preferred.

### 11.3 Acceptance criteria

Before production enablement:

- all expected memory banks have a reviewed monitor mapping;
- initialization failures are observable and handled;
- a correctable injection is detected and scrubbed without data loss;
- an uncorrectable injection produces the expected reset and next-boot record;
- no test-only injection path exists in the production image;
- scrubber concurrency and cache behavior have been reviewed;
- the scrubber does not violate F Prime timing budgets;
- telemetry/event behavior is bounded under repeated faults;
- both MCU variants pass the hardware campaign.

## 12. Implementation roadmap

### Phase 0: module integration and design

Deliverables:

- one consistent `CONFIG_FPRIME_STM32H7_RAMECC` symbol;
- Zephyr module Kconfig and CMake integration;
- public header skeleton;
- this architecture and roadmap document.

Exit condition: a pristine build proves that enabling the public symbol compiles
the intended source files and selects the required STM32 HAL module.

### Phase 1: RAMECC detection only

Deliverables:

- reviewed H723 and H753 monitor tables;
- `SYS_INIT()` initialization;
- `ECC_IRQn` handler;
- single/double error classification;
- in-RAM snapshot and counters;
- no background scrubber yet.

Exit condition: synthetic or debugger-assisted flags reach the correct handler
without false interrupts during a normal boot.

### Phase 2: controlled fault injection

Deliverables:

- linker-reserved injection region;
- development-only injection procedure;
- correct access-width and cache-control sequence;
- automated evidence for correctable and uncorrectable cases.

Exit condition: both error classes can be reproduced safely on both boards.

### Phase 3: CPU reference scrubber

Deliverables:

- low-priority scrub thread or bounded delayable work;
- reserved/owned initial scrub region;
- aligned full-ECC-word read/write implementation;
- pass, byte, and error counters;
- prioritized scrub request from a correctable error.

Exit condition: a correctable injected error is rewritten and does not recur on
the next access.

### Phase 4: MDMA scrubber and cache validation

Deliverables:

- documented MDMA channel ownership;
- bounded memory-to-memory transfer implementation;
- completion and timeout handling;
- cache maintenance and alignment;
- performance comparison against CPU scrubbing.

Exit condition: MDMA reduces CPU cost without data corruption, timing
regression, or cache incoherency.

### Phase 5: retained fault and reboot policy

Deliverables:

- versioned retained record with magic and CRC;
- atomic/ordered record commit;
- double-error reset path;
- next-boot validation and consume/clear policy;
- reset and power-cycle behavior characterization.

Exit condition: an uncorrectable injection reboots and reports a valid record on
the next boot.

### Phase 6: F Prime `RamEccMonitor`

Deliverables:

- FPP component model;
- C++ component implementation;
- commands, telemetry, and events described above;
- rate-group and health connections;
- component unit tests;
- topology integration.

Exit condition: low-level faults and scrub status are observable through F Prime
without F Prime participation in the ISR path.

### Phase 7: MCUboot integration, if required

Deliverables:

- separate MCUboot image configuration;
- decision on which RAM must be initialized/monitored during bootloader
  execution;
- handoff/reset-record compatibility between MCUboot and the application;
- sysbuild verification.

Exit condition: bootloader operation does not clear required retained data or
access uninitialized ECC RAM unsafely.

### Phase 8: endurance and fault campaign

Deliverables:

- long-duration scrub testing;
- repeated injection testing;
- timing and bus-load measurements;
- watchdog/reset interaction tests;
- reviewed production configuration;
- operational thresholds for error rate and escalation.

Exit condition: the behavior is repeatable, bounded, and accepted for the
mission's reliability requirements.

## 13. Required reading and implementation resources

### STM32 ECC and device behavior

1. [AN5342: Error correction code management for internal memories](https://www.st.com/resource/en/application_note/an5342--error-correction-code-ecc-management-for-internal-memories-protection-on-stm32-microcontrollers-stmicroelectronics.pdf)
   - Read the RAM ECC overview, initialization, ISR, failing-address, cache, and
     fault-injection sections.
2. [RM0468: STM32H723/733 and STM32H725/727 reference manual](https://www.st.com/resource/en/reference_manual/dm00603761.pdf)
   - Use for the H723 memory map, RAMECC monitor mapping, registers, and
     `ECC_IRQn` behavior.
3. [RM0433: STM32H742/743/753 and STM32H750 reference manual](https://www.st.com/resource/en/reference_manual/dm00314099-stm32h742-stm32h743753-and-stm32h750-value-line-advanced-armbased-32bit-mcus-stmicroelectronics.pdf)
   - Use for the H753 memory map, RAMECC monitor mapping, registers, and
     `ECC_IRQn` behavior.
4. [STM32H7 HAL RAMECC source](https://github.com/STMicroelectronics/stm32h7xx-hal-driver/blob/master/Src/stm32h7xx_hal_ramecc.c)
   and [header](https://github.com/STMicroelectronics/stm32h7xx-hal-driver/blob/master/Inc/stm32h7xx_hal_ramecc.h)
   - Study initialization, notification constants, IRQ processing, callbacks,
     and diagnostic getters.
5. [ST guide: injecting and handling ECC errors in STM32H7 RAM and flash](https://community.st.com/stm32-mcus-products-25/guide-injecting-and-handling-ecc-errors-in-ram-and-flash-on-stm32h7-140271)
   - Use as a lab aid. Validate every address and access sequence against AN5342
     and the exact device reference manual.

### Zephyr integration

1. [Zephyr modules](https://docs.zephyrproject.org/latest/develop/modules.html)
2. [Zephyr system initialization API](https://docs.zephyrproject.org/latest/doxygen/html/group__sys__init.html)
3. [Zephyr interrupt documentation](https://docs.zephyrproject.org/latest/kernel/services/interrupts.html)
4. [Zephyr thread documentation](https://docs.zephyrproject.org/latest/kernel/services/threads/index.html)
5. [Zephyr workqueue documentation](https://docs.zephyrproject.org/latest/kernel/services/threads/workqueue.html)
6. [Zephyr DMA documentation](https://docs.zephyrproject.org/latest/hardware/peripherals/dma.html)
7. [Zephyr cache-management guide](https://docs.zephyrproject.org/latest/hardware/cache/guide.html)
8. [Zephyr reboot API](https://docs.zephyrproject.org/latest/doxygen/html/reboot_8h.html)
9. [Zephyr PR #94419: STM32H7 TCM ECC startup initialization](https://github.com/zephyrproject-rtos/zephyr/pull/94419)

### F Prime component development

1. [F Prime ports, components, and topologies](https://fprime.jpl.nasa.gov/latest/docs/user-manual/overview/03-port-comp-top/)
2. [FPP user's guide](https://nasa.github.io/fpp/fpp-users-guide.html)
3. [F Prime commands, events, channels, and parameters](https://fprime.jpl.nasa.gov/latest/docs/user-manual/overview/04-cmd-evt-chn-prm/)
4. [F Prime unit testing](https://fprime.jpl.nasa.gov/latest/docs/user-manual/overview/unit-testing/)
5. Existing components in the consuming application for topology, rate-group,
   event-severity, and naming conventions.

## 14. Open decisions

The following decisions require measurement or review before production:

- exact H723 and H753 monitor tables;
- approved scrub regions and ownership mechanism;
- CPU versus MDMA as the production scrub method;
- scrub chunk size, period, priority, and complete-pass target;
- cache policy for each scrub region;
- storage location and lifetime of the retained record;
- immediate uncorrectable policy: cold reboot, watchdog reset, or safe state;
- correctable-error rate and recurrence escalation thresholds;
- event throttling and telemetry cadence;
- whether the F Prime component participates in health pinging;
- whether MCUboot must monitor ECC or only preserve the application record.

Each decision should be recorded with the supporting hardware test result or
mission requirement.
