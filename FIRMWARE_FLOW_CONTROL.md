# BLE Audio Stream Flow Control — Firmware Implementation Guide

## Problem Being Solved

The current firmware blasts all 600 Opus notifications as fast as possible. The phone's BLE stack cannot queue them fast enough and drops ~75% of packets, producing noise and clicks in the received audio.

## Solution: Application-Layer Window/ACK Protocol

Add a stop-and-wait window protocol on top of BLE notifications. The phone and EVB exchange JSON messages on the existing **JSON characteristic** to coordinate transfer. The EVB sends a fixed window of packets, pauses, and waits for the phone to ACK or NACK before continuing.

---

## Protocol Flow

```
Phone                                     EVB
  |                                         |
  |-- {"cmd":"stream_start","window":20} -->|   Phone requests stream, declares window size
  |                                         |   EVB sends packets 0–19 (notifications)
  |<-- Opus pkts 0..19 (flags=0x00) --------|
  |<-- Opus pkt 19    (flags=0x04) ---------|   EVB sets WINDOW_END flag on last pkt of window
  |                                         |
  |-- {"cmd":"ack","next":20} ------------->|   Phone: all 20 received, advance
  |                                         |   EVB sends packets 20–39
  |<-- Opus pkts 20..39 --------------------|
  |<-- Opus pkt 39    (flags=0x04) ---------|
  |                                         |
  |-- {"cmd":"nack","window_start":20,      |   Phone: missed pkts 22 and 27
  |    "missing":[22,27]} ---------------->|
  |                                         |   EVB resends only pkts 22 and 27
  |<-- Opus pkt 22    (flags=0x04) ---------|   EVB sets WINDOW_END on last resent pkt
  |<-- Opus pkt 27    (flags=0x04) ---------|
  |                                         |
  |-- {"cmd":"ack","next":40} ------------->|   All good now, advance
  |                                         |
  ... (continues until all windows done) ...
  |                                         |
  |<-- Opus pkt 599   (flags=0x02) ---------|   END flag on final packet of entire stream
```

---

## New Flag Bit

Add `OPUS_FLAG_WINDOW_END = 0x04` to the flags byte (byte 0) of the Opus notification header.

| Bit | Existing name        | Value | Meaning                          |
|-----|----------------------|-------|----------------------------------|
| 0   | `OPUS_FLAG_START`    | 0x01  | First packet of entire stream    |
| 1   | `OPUS_FLAG_END`      | 0x02  | Last packet of entire stream     |
| 2   | `OPUS_FLAG_WINDOW_END` | 0x04 | **NEW** Last packet of current window — phone must ACK/NACK before more are sent |

These bits are independent and can be OR'd. The last packet of the entire stream will have `flags = 0x02 | 0x04 = 0x06`.

---

## JSON Commands the Phone Sends (on JSON characteristic write)

All messages are JSON objects written to the **JSON characteristic** (`12341234-5678-1234-1234-1234567890AC`).

### `stream_start`
```json
{"cmd": "stream_start", "window": 20}
```
- Phone sends this after enabling Opus notifications.
- `window` is the number of packets per window (always 20 from the current app, but treat it as variable for future-proofing).
- EVB should: load the encoded buffer, reset its packet cursor, and begin sending packets 0 through `window-1`, then pause.

### `ack`
```json
{"cmd": "ack", "next": 20}
```
- Phone received the full window cleanly (or accepted the retransmitted packets).
- `next` is the first packet index of the next window.
- EVB should: send packets `next` through `next + window - 1`, then pause again.

### `nack`
```json
{"cmd": "nack", "window_start": 20, "missing": [22, 27]}
```
- Phone detected gaps in this window.
- `window_start` identifies which window we're talking about.
- `missing` is the list of specific packet indices the phone needs resent.
- EVB should: resend only the listed packet indices (from its retained encoded buffer), setting `OPUS_FLAG_WINDOW_END` on the **last** packet in the resend list.
- The phone will retry up to 3 times before giving up on a window and sending `ack` anyway.

---

## EVB Implementation Requirements

### 1. Retain the encoded buffer until transfer completes

The EVB must **not** free or overwrite `g_opusBuf[]` until it receives `ack` with `next >= total_packets`. Currently the buffer may be overwritten — it must persist for the full transfer duration.

### 2. Parse JSON writes on the JSON characteristic

In `src/ble_json_svc.c` (or wherever write callbacks are handled), parse incoming JSON for the `cmd` field:

```c
// Pseudocode
if (strcmp(cmd, "stream_start") == 0) {
    window_size = json_get_int(payload, "window");
    opus_stream_reset();           // reset packet cursor to 0
    opus_stream_send_window(0, window_size);
}
else if (strcmp(cmd, "ack") == 0) {
    int next = json_get_int(payload, "next");
    if (next >= total_packets) {
        opus_stream_complete();    // transfer done, can free buffer
    } else {
        opus_stream_send_window(next, window_size);
    }
}
else if (strcmp(cmd, "nack") == 0) {
    int* missing = json_get_array(payload, "missing", &count);
    opus_stream_resend(missing, count);
}
```

### 3. `opus_stream_send_window(start, count)`

Send `count` notifications starting at packet index `start`:
- All intermediate packets: `flags = 0x00` (or `0x01` if start==0 for the very first window)
- Last packet in window: `flags |= OPUS_FLAG_WINDOW_END (0x04)`
- Last packet of entire stream: `flags |= OPUS_FLAG_END (0x02)`
- Then **stop** — do not send more until the next `ack`/`nack` arrives

Add a small inter-packet delay (e.g. 5–10 ms) between notifications within a window to avoid overflowing the phone's connection-interval queue. Even 5 ms spacing on 20 packets = 100 ms per window, well within BLE keep-alive timeouts.

### 4. `opus_stream_resend(indices[], count)`

Iterate the `missing` array and send only those specific packet indices from the retained buffer. Set `OPUS_FLAG_WINDOW_END` on the last one.

### 5. Timeout / fallback

If no `ack`/`nack` arrives within 5 seconds of sending `WINDOW_END`, resend the window automatically (treat as implicit NACK). This handles the case where the phone's JSON write was dropped.

---

## Packet Format (unchanged)

```
byte  field                description
----  -------------------  ---------------------------------------------
 0    flags                0x01=START, 0x02=END, 0x04=WINDOW_END (new)
 1    metadata_version     Always 0x01
 2-3  packet_index (u16)   0-based index, little-endian
 4-5  total_packets (u16)  Total packets in stream, little-endian
 6-9  total_len (u32)      Total Opus byte length, little-endian
10..  payload              Raw Opus bytes, up to 200 per notification
```

---

## Constants (add to `src/ble_opus_stream_svc.h` or equivalent)

```c
#define OPUS_FLAG_START       0x01
#define OPUS_FLAG_END         0x02
#define OPUS_FLAG_WINDOW_END  0x04   // NEW
#define OPUS_DEFAULT_WINDOW   20     // packets per window
#define OPUS_INTER_PKT_DELAY_MS  8   // ms between notifications within a window
```

---

## App-Side Constants (already implemented, for reference)

```dart
static const int _windowSize   = 20;   // packets per window
static const int _maxRetries   = 3;    // NACK retries before skipping
static const int _flagWindowEnd = 0x04;
static const int _blePayloadSize = 200; // bytes per BLE payload
```

The app sends `stream_start` immediately after subscribing to the Opus characteristic. It expects `WINDOW_END` on the last packet of each window, then sends `ack` or `nack` accordingly.
