# IIO Clock Frequency Measurement Results

## Summary

The IIO programmable PMU events (COMP_BUF_OCCUPANCY, COMP_BUF_INSERTS, etc.) use the
**uncore/mesh clock**, NOT the `ioclk` free-running counter.

- Uncore frequency idle: ~1.6 GHz
- Uncore frequency under PCIe load: **~2.4 GHz** (measured via PCM UncFREQ)
- `ioclk` free-running counter: ~45 MHz (low-frequency reference, NOT the event clock)

## Validation

COMP_BUF residence of 2,479 cycles (ib_read_bw 16KB cross-IIO) at 2.4 GHz = **1.03 us**,
which matches the ~1.0 us mesh crossing overhead from ib_read_bw --outstanding sweep
(cross-IIO RTT 10.71 us - same-IIO RTT 9.71 us = 1.0 us).

## Updated Residence Times

| Workload        | Residence (cycles) | Residence (us) @ 2.4 GHz |
| --------------- | ------------------ | ------------------------ |
| ib_read_bw 2MB  | 1,631              | 0.68                     |
| ib_read_bw 16KB | 2,479              | 1.03                     |
| NIXL ISL=4096   | 2,369              | 0.99                     |
| NIXL ISL=8192   | 2,618              | 1.09                     |

## Raw Data

### Free-running ioclk on all IIO units (node7/10.0.74.185, 45s, idle + 30s ib_read_bw 2MB)

| Unit | ioclk (total) | Rate (MHz) | bw_out_port0 (MiB) | Notes |
|------|---------------|------------|---------------------|-------|
| 0    | 2,012,935,182 | 44.7       | 0.00                | Idle PCIe IIO |
| 1    | 2,013,357,281 | 44.7       | 0.00                | Idle PCIe IIO |
| 2    | 31,405,530,149| 698        | 1.08                | NIC IIO? (minimal BW) |
| 3    | 2,013,050,774 | 44.7       | 0.00                | Idle PCIe IIO |
| 4    | 31,355,531,628| 697        | 444,775             | NIC IIO (heavy traffic) |
| 5    | 2,013,018,524 | 44.7       | 0.00                | Idle PCIe IIO |
| 6    | 31,356,115,309| 697        | 1.03                | NIC IIO? (minimal BW) |
| 7    | 3,378,230,785 | 75         | 6.37                | Different subsystem? |
| 8    | 2,012,992,128 | 44.7       | 0.00                | Idle PCIe IIO |
| 9    | 31,387,446,924| 698        | 444,127             | NIC IIO (heavy traffic) |
| 10   | 0             | 0          | 0.00                | Not present |
| 11   | 0             | 0          | 0.00                | Not present |

### Uncore frequency under load (PCM, node7)

| Condition | SKT 0 UncFREQ | SKT 1 UncFREQ |
|-----------|---------------|----------------|
| Idle      | 1.57 GHz      | 1.58 GHz       |
| ib_read_bw active (sample 1) | 2.38 GHz | 2.46 GHz |
| ib_read_bw active (sample 2) | 2.41 GHz | 2.49 GHz |

### Key insight: free-running ioclk != programmable event clock

The `uncore_iio_free_running_N/ioclk/` counter runs at a fixed reference frequency
(~45 MHz for standard IIO stacks, ~697 MHz for DSA/IAA accelerator stacks).
The IIO programmable PMU events (COMP_BUF_OCCUPANCY, COMP_BUF_INSERTS) use the
dynamic uncore/mesh clock, which is ~2.4 GHz under PCIe workloads on this SKU
(Xeon Platinum 8480+).
