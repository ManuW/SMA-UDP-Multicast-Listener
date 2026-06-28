# SMA Speedwire Protocol Documentation

This document explains how to listen for and parse data from SMA Energy Meters and Home Managers using the Speedwire protocol.

## 1. Connection Details

SMA devices broadcast their measurements using **UDP Multicast**.

- **Multicast Group:** `239.12.255.254`
- **Port:** `9522`

To receive the data stream, an application must join this multicast group.

## 2. UDP Payload Structure

A Speedwire message consists of a start sequence followed by one or more tag frames.

### Start Sequence

Every message begins with a fixed sequence: `534d4100`. In ASCII, this represents `"SMA\0"`.

| Offset | Length | Description |
| ------ | ------ | ----------- |
| 0      | 4      | "SMA\0"     |

### Tag Frame

The next bytes are separated in frames. Each frame starts with a length field and is followed by the tag and data for this tag.

| Offset | Length      | Description |
| ------ | ----------- | ----------- |
| 0      | 2           | Data length |
| 2      | 2           | Tag         |
| 4      | Data length | Data        |

#### Tag: Tag0

SMA-Format

- Length: `0004`
- Tag: `02a0`, Tag: "Tag0" (42), version 0
- Payload: `00000001`, Group1 (default group)

```HEX
000402a000000001
```

#### Tag: "SMA Net 2"

SMA Net 2

- Length: `024c` // 588 bytes
- Tag: `0010`, Tag: "SMA Net 2", version 0
- Data:
  - SubTag: `6069`
  - ...

##### Data description for Sunny Home Manager

Data fields for Protocol ID `6069`!
Energy meter identifier is a combination of Susy-ID and serial number.
| Offset | Length | Description                                 |
| ------ | ------ | ------------------------------------------- |
| 0      | 2      | SubTag / Protocol ID                        |
| 2      | 6      | Energy meter identifier                     |
| 2      | 2      | Engergy meter identifier -> Susy-ID         |
| 4      | 4      | Energy meter identifier -> Serial Number    |
| 8      | 4      | Ticker measuring time in ms (with overflow) |
| 12     | 570    | OBIS data                                   |

###### Ticker measurement

The Ticker is a 32-bit unsigned integer (uint32_t) timestamp that counts elapsed time in milliseconds. Because it is a 32-bit value, it automatically overflows and rolls over to 0 roughly every 49.71 days. To handle this overflow seamlessly when parsing Speedwire data telegrams, you must use unsigned delta arithmetic rather than direct greater-than/less-than comparisons.

Example

```Python
previous_ticker = 4294967290
current_ticker = 5

# Force 32-bit unsigned wrapping
elapsed_ms = (current_ticker - previous_ticker) & 0xFFFFFFFF

print(f"Elapsed time: {elapsed_ms} ms")  # Output: 11 ms
```

```C/C++
#include <stdint.h>
#include <stdio.h>

uint32_t previous_ticker = 4294967290U;
uint32_t current_ticker = 5U;

// Standard C unsigned behavior handles the modulo 2^32 math
uint32_t elapsed_ms = current_ticker - previous_ticker;

printf("Elapsed time: %u ms\n", elapsed_ms); // Output: 11 ms
```

###### OBIS Data

The frist 4 bytes is the OBIS code followed by n-bytes data. Data length depends on the used OBIS iden code

| Offset | Description                                             |
| ------ | ------------------------------------------------------- |
| 0      | Measuring Channel                                       |
| 1      | Measurement Value Index                                 |
| 2      | Measurement Type                                        |
| 3      | Tariff                                                  |
| 4      | Data, length depends on Measurement Channel and or Type |

Measuring Channel 0 - 127:

- Current Average, Measurement Type 4, 32-bit unsigned integer
- Energy Meter Reading, Measurement Type 8, 64-bit unsigned integer

Measuring Channel 128 - 255:

- Custom Value: 32-bit unsigned integer (vendor specific).

For example `0:1.4.0` where:

- 0: Measuring Channel
- 1: Measurement Value Index, Total: Active Power Import (+P)
- 4: Measurement Type 4, Current Average
- 0: Tariff 0

Measurement Value Index Blocks:
- Total: 1 - 20
- Phase L1: 21 - 40
- Phase L2: 41 - 60
- Phase L3: 61 - 80

**OBIS Code Mapping Table**

| OBIS Code     | Description (en)                     | Unit (Target) | Conversion (Formula / Logic)                      |
| ------------- | ------------------------------------ | ------------- | ------------------------------------------------- |
| 0:1.4.0       | Total: Active Power Import (+P)      | W             | Value / 10                                        |
| 0:1.8.0       | Total: Active Energy Import          | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:2.4.0       | Total: Active Power Export (-P)      | W             | Value / 10                                        |
| 0:2.8.0       | Total: Active Energy Export          | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:3.4.0       | Total Reactive Power Import (+Q)     | var           | Value / 10                                        |
| 0:3.8.0       | Total Reactive Energy Import (+R)    | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:4.4.0       | Total Reactive Power Export (-Q)     | var           | Value / 10                                        |
| 0:4.8.0       | Total Reactive Energy Export (-R)    | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:9.4.0       | Total Apparent Power Import (+S)     | VA            | Value / 10                                        |
| 0:9.8.0       | Total Apparent Energy Import         | kVAh          | Value / 3,600,000 (Ws to kVAh)                    |
| 0:10.4.0      | Total Apparent Power Export (-S)     | VA            | Value / 10                                        |
| 0:10.8.0      | Total Apparent Energy Export         | kVAh          | Value / 3,600,000 (Ws to kVAh)                    |
| 0:13.4.0      | Total Power Factor (\cos \phi)       | -             | Value / 1000 (e.g., 1000 = 1.000)                 |
| 0:14.4.0      | Grid Frequency                       | Hz            | Value / 1000 (e.g., 49992 = 49.992 Hz)            |
| **---**       | **PHASE L1**                         | **---**       | **---**                                           |
| 0:21.4.0      | Phase L1: Active Power Import (+P)   | W             | Value / 10                                        |
| 0:21.8.0      | Phase L1: Active Energy Import       | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:22.4.0      | Phase L1: Active Power Export (-P)   | W             | Value / 10                                        |
| 0:22.8.0      | Phase L1: Active Energy Export       | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:23.4.0      | Phase L1: Reactive Power Import (+Q) | var           | Value / 10                                        |
| 0:23.8.0      | Phase L1: Reactive Energy Import     | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:24.4.0      | Phase L1: Reactive Power Export (-Q) | var           | Value / 10                                        |
| 0:24.8.0      | Phase L1: Reactive Energy Export     | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:29.4.0      | Phase L1: Apparent Power Import (+S) | VA            | Value / 10                                        |
| 0:29.8.0      | Phase L1: Apparent Energy Import     | kVAh          | Value / 3,600,000 (Ws to kVAh)                    |
| 0:30.4.0      | Phase L1: Apparent Power Export (-S) | VA            | Value / 10                                        |
| 0:30.8.0      | Phase L1: Apparent Energy Export     | kVAh          | Value / 3,600,000 (Ws to kVAh)                    |
| 0:33.4.0      | Phase L1: Power Factor               | -             | Value / 1000                                      |
| **---**       | **PHASE L2**                         | **---**       | **---**                                           |
| 0:41.4.0      | Phase L2: Active Power Import (+P)   | W             | Value / 10                                        |
| 0:41.8.0      | Phase L2: Active Energy Import       | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:42.4.0      | Phase L2: Active Power Export (-P)   | W             | Value / 10                                        |
| 0:42.8.0      | Phase L2: Active Energy Export       | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:43.4.0      | Phase L2: Reactive Power Import (+Q) | var           | Value / 10                                        |
| 0:43.8.0      | Phase L2: Reactive Energy Import     | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:44.4.0      | Phase L2: Reactive Power Export (-Q) | var           | Value / 10                                        |
| 0:44.8.0      | Phase L2: Reactive Energy Export     | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:49.4.0      | Phase L2: Apparent Power Import (+S) | VA            | Value / 10                                        |
| 0:49.8.0      | Phase L2: Apparent Energy Import     | kVAh          | Value / 3,600,000 (Ws to kVAh)                    |
| 0:50.4.0      | Phase L2: Apparent Power Export (-S) | VA            | Value / 10                                        |
| 0:50.8.0      | Phase L2: Apparent Energy Export     | kVAh          | Value / 3,600,000 (Ws to kVAh)                    |
| 0:53.4.0      | Phase L2: Power Factor               | -             | Value / 1000                                      |
| **---**       | **PHASE L3**                         | **---**       | **---**                                           |
| 0:61.4.0      | Phase L3: Active Power Import (+P)   | W             | Value / 10                                        |
| 0:61.8.0      | Phase L3: Active Energy Import       | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:62.4.0      | Phase L3: Active Power Export (-P)   | W             | Value / 10                                        |
| 0:62.8.0      | Phase L3: Active Energy Export       | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:63.4.0      | Phase L3: Reactive Power Import (+Q) | var           | Value / 10                                        |
| 0:63.8.0      | Phase L3: Reactive Energy Import     | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:64.4.0      | Phase L3: Reactive Power Export (-Q) | var           | Value / 10                                        |
| 0:64.8.0      | Phase L3: Reactive Energy Export     | kWh           | Value / 3,600,000 (Ws to kWh)                     |
| 0:69.4.0      | Phase L3: Apparent Power Import (+S) | VA            | Value / 10                                        |
| 0:69.8.0      | Phase L3: Apparent Energy Import     | kVAh          | Value / 3,600,000 (Ws to kVAh)                    |
| 0:70.4.0      | Phase L3: Apparent Power Export (-S) | VA            | Value / 10                                        |
| 0:70.8.0      | Phase L3: Apparent Energy Export     | kVAh          | Value / 3,600,000 (Ws to kVAh)                    |
| 0:73.4.0      | Phase L3: Power Factor               | -             | Value / 1000                                      |
| **---**       | **DEVICE INFO**                      | **---**       | **---**                                           |
| **144:0.0.0** | Device Software Version              | -             | Raw Hex/String interpretation (e.g., `1.02.04.R`) |

Example

```
Offset: Bytes // Description
000: 00 // Channel 0
001: 01 04 // Total: Active Power Import
003: 00 // Tariff 0
004: 00 00 00 00 // 0 W

008: 00 // Channel 0
009: 01 08 // Total: Active Energy Import
011: 00 // Tariff 0
012: 00 00 00 00 5f 81 59 20 // 1.602.312.480 Ws = 445.0868 1602.312 kWh

...+0: 90 // Vendor Device Software Version
...+1: 00 00
...+3: 00
...+4: 02 12 0e 52 // 2.18.14 R
```

#### Tag: End-of-Data

The message concludes with an end tag:

- Length: `0000`
- Tag: `0000`
- Payload: None

Example:

```HEX
00000000
```

## Example

A complete message

```HEX
534d4100000402a000000001024c001060690174b3a60ace9dc60339000104000000000000010800000000005f8159200002040000001b55000208000000001c32ebc488000304000000000000030800000000006e02b04800040400000007da000408000000000187d324700009040000000000000908000000000103fcf8d8000a040000001c70000a08000000001cdc0775a8000d0400000003c1000e04000000c3430015040000000000001508000000000098f21d480016040000000b2c0016080000000009e86a140800170400000000000017080000000000975292b000180400000001800018080000000000528f4038001d040000000000001d080000000000de49c4b8001e040000000b45001e08000000000a08446508001f0400000004f2002004000003899600210400000003df002904000000000000290800000000004f8b59f8002a040000000b82002a08000000000990df6cb0002b040000000000002b0800000000002e897578002c040000000307002c080000000000d3542558003104000000000000310800000000006b4326d00032040000000be60032080000000009f080a648003304000000054100340400000389e200350400000003c7003d040000000000003d0800000000007cfda468003e0400000004a7003e080000000009bf9bfde8003f040000000000003f0800000000000485bbd800400400000003520040080000000000be4ed13000450400000000000045080000000000ae1a2d2800460400000005b80046080000000009e9426d300047040000000348004804000003882e004904000000032e9000000002120e5200000000
```

## Translation
| en              | de                                |
| --------------- | --------------------------------- |
| Active Power    | Wirkleistung                      |
| Active Energy   | Wirkenergie (oder Wirkarbeit)     |
| Reactive Power  | Blindleistung                     |
| Reactive Energy | Blindenergie (oder Blindarbeit)   |
| Apparent Power  | Scheinleistung                    |
| Apparent Energy | Scheinenergie (oder Scheinarbeit) |
| Power Factor    | Leistungsfaktor                   |
| Grid Frequency  | Netzfrequenz                      |
