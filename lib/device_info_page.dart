import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

class DeviceInfoPage extends StatefulWidget {
  final BluetoothDevice device;

  const DeviceInfoPage({super.key, required this.device});

  @override
  State<DeviceInfoPage> createState() => _DeviceInfoPageState();
}

class _DeviceInfoPageState extends State<DeviceInfoPage> {
  // Colors for UI
  static const darkGreen = Color(0xFF3B4A2F);
  static const cream = Color(0xFFF5F0DC);
  static const buttonGreen = Color(0xFF4A5E35);
  static const textBoxColor = Color(0xFFDDDDC3);

  // JSON service
  static final Guid helloServiceUuid = Guid("12341234-5678-1234-1234-1234567890AB");
  static final Guid helloValueUuid   = Guid("12341234-5678-1234-1234-1234567890AC");

  // Opus audio stream service
  static final Guid opusServiceUuid = Guid("12341234-5678-1234-1234-1234567890BB");
  static final Guid opusCharUuid    = Guid("12341234-5678-1234-1234-1234567890BC");

  late AudioRecorder _audioRecorder;
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _isRecording = false;
  bool _isConnecting = true;
  bool _isConnected = false;
  Timer? _keepAliveTimer;

  // BLE Opus stream state
  bool _isReceivingStream = false;
  int _streamPacketsReceived = 0;
  int _streamPacketsTotal = 0;
  // Pre-allocated buffer written by packet_index offset — deduplicates and handles gaps.
  // Each BLE packet carries up to _blePayloadSize bytes at offset: packetIndex * _blePayloadSize.
  static const int _blePayloadSize = 200;
  Uint8List? _streamPreAllocBuffer;

  // ACK/window flow control — mirrors TCP-style stop-and-wait
  static const int _windowSize = 20;    // packets per window (used for manual replay cmd)
  static const int _maxRetries = 3;     // NACK retries per window before giving up and ACKing
  static const int _flagWindowEnd = 0x04; // EVB finished sending current window, must ACK/NACK
  int _windowStart = 0;                 // first packet index of the current window
  int _windowRetries = 0;               // NACK retry count for the current window
  int _windowEnd = 0;                   // true end of the current window, locked in on first WINDOW_END
  int _lastHandledWindowEnd = -1;       // guards against duplicate WINDOW_END for the same boundary
  final Set<int> _receivedIndices = {}; // all packet indices received so far
  Timer? _windowAckTimer;               // fires if WINDOW_END is dropped — app-side ACK trigger

  BluetoothCharacteristic? _helloChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _opusNotifySub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  final List<String> _messages = [];
  List<FileSystemEntity> _recordings = [];
  String? _playingPath;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  // Prevents the slider from jumping while you are dragging it
  bool _isDragging = false; 

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    
    // Checks duration change for audio playback
    _audioPlayer.onDurationChanged.listen((newDuration) {
      if (mounted) setState(() => _duration = newDuration);
    });

    // Changes position of slider  
    _audioPlayer.onPositionChanged.listen((newPosition) {
      if (mounted && !_isDragging) {
        setState(() => _position = newPosition);
      }
    });

    // Set to default after
    _audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) {
        setState(() {
          _playingPath = null;
          _position = Duration.zero;
        });
      }
    });

    _connectionSub = widget.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        if (mounted && !_isConnecting) {
          // auto reconnect if connection is still there
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && !_isConnecting) {
              _connectToDevice();
            }
          });
        }
      }
    });

    _connectToDevice();
    _recordingList().then((files) => setState(() => _recordings = files));
  }

  void _addMessage(String text) {
    final msg = text.trim();
    if (msg.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _messages.insert(0, msg);
    });
  }

  Future<void> _connectToDevice() async {
    try {
      debugPrint("Connecting to: ${widget.device.remoteId.str} name=${widget.device.platformName}");

      try {
        await widget.device.disconnect();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));

      await widget.device.connect(timeout: const Duration(seconds: 6));
      await Future.delayed(const Duration(milliseconds: 600));

      try {
        await widget.device.requestMtu(247);
      } catch (e) {
        debugPrint("MTU req failed: $e");
      }

      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _isConnected = true;
      });

      await _setupHelloCharacteristicReadAndNotify();
      _keepAliveTimer?.cancel();

      // silent read every 15 seconds to prevent disconnect — skipped during Opus stream
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
        if (_isReceivingStream) return;
        final c = _helloChar;
        if (_isConnected && c != null && c.properties.read) {
          try { await c.read(); } catch (_) {}
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _isConnected = false;
      });
      _addMessage("Connection failed: $e");
    }
  }

  Future<void> _setupHelloCharacteristicReadAndNotify() async {
    try {
      var services = await widget.device.discoverServices();
      _printGattToTerminal(services);

      BluetoothCharacteristic? found = _findHelloCharacteristic(services);

      if (found == null) {
        debugPrint("Custom service not found, retrying discovery once (Android cache common)...");
        await Future.delayed(const Duration(milliseconds: 600));
        services = await widget.device.discoverServices();
        _printGattToTerminal(services);
        found = _findHelloCharacteristic(services);
      }

      if (found == null) {
        _addMessage(
          "Error: hello characteristic not found.\n"
          "Expected Service: ${helloServiceUuid.str}\n"
          "Expected Char:    ${helloValueUuid.str}",
        );
        return;
      }

      _helloChar = found;
      await _enableNotifyAndListen(_helloChar!);
      await _readHelloOnce();
      // Subscribe to Opus immediately — device may already have a pending recording
      await _setupOpusCharacteristic(services);
    } catch (e) {
      _addMessage("Setup failed: $e");
    }
  }

  Future<void> _setupOpusCharacteristic(List<BluetoothService> services) async {
    BluetoothCharacteristic? char;
    for (final s in services) {
      if (s.uuid == opusServiceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid == opusCharUuid) {
            char = c;
            break;
          }
        }
      }
    }

    if (char == null) {
      _addMessage("Opus stream characteristic not found.");
      return;
    }

    if (!char.properties.notify) {
      _addMessage("Opus characteristic does not support notify.");
      return;
    }

    await _opusNotifySub?.cancel();
    _opusNotifySub = null;

    try {
      await char.setNotifyValue(true);
    } catch (e) {
      _addMessage("Opus notify enable failed: $e");
      return;
    }

    _opusNotifySub = char.onValueReceived.listen(
      _onOpusNotification,
      onError: (e) => _addMessage("Opus stream error: $e"),
    );

    _addMessage("Opus stream ready ✅");
  }

  void _onOpusNotification(List<int> value) {
    if (value.length < 10) return;

    final flags        = value[0];

    // Ignore packets arriving after stream is complete (EVB retrying after final ACK)
    final isStart = (flags & 0x01 != 0);
    if (!_isReceivingStream && !isStart) return;
    final packetIndex  = value[2] | (value[3] << 8);
    final totalPackets = value[4] | (value[5] << 8);
    final totalLen     = value[6] | (value[7] << 8) | (value[8] << 16) | (value[9] << 24);
    final payload      = value.sublist(10);

    if (flags & 0x01 != 0) { // START
      final isSameStream = _streamPreAllocBuffer != null &&
          _streamPreAllocBuffer!.length == totalLen &&
          _streamPacketsTotal == totalPackets;

      if (!isSameStream) {
        // Genuinely new recording — reset everything including flow control.
        _streamPreAllocBuffer = totalLen > 0 ? Uint8List(totalLen) : null;
        _receivedIndices.clear();
        _streamPacketsReceived = 0;
        _streamPacketsTotal = totalPackets;
        _windowStart = 0;
        _windowRetries = 0;
        _windowEnd = 0;
        _lastHandledWindowEnd = -1;
        if (mounted) setState(() => _isReceivingStream = true);
        _addMessage("Stream start: $totalPackets pkts, $totalLen bytes");
      } else if (_windowStart == 0) {
        // Same stream, still working window 0 — preserve buffer & indices,
        // keep _windowRetries and _windowEnd intact (don't reset retry count).
        _streamPacketsReceived = _receivedIndices.length;
        debugPrint("Stream resend (window 0) — keeping ${_receivedIndices.length} received packets");
        _addMessage("Stream resend: keeping ${_receivedIndices.length} packets");
      } else {
        // Same stream, already past window 0 — this is a delayed pkt-0 resend
        // that crossed our ACK in flight.  Just collect pkt 0's data, do NOT
        // touch _windowStart, _windowEnd, _windowRetries, or _lastHandledWindowEnd.
        _streamPacketsReceived = _receivedIndices.length;
        debugPrint("Delayed pkt 0 resend (window $_windowStart active) — ignoring flow reset");
      }
    }

    // Write payload at its correct byte offset — deduplicates re-delivered packets
    final buf = _streamPreAllocBuffer;
    if (buf != null && payload.isNotEmpty) {
      final offset = packetIndex * _blePayloadSize;
      final end = (offset + payload.length).clamp(0, buf.length);
      if (offset < buf.length) {
        buf.setRange(offset, end, payload);
      }
    }

    // Track which indices we have
    final isNewPacket = !_receivedIndices.contains(packetIndex);
    if (isNewPacket) {
      _receivedIndices.add(packetIndex);
      _streamPacketsReceived++;
      // Only reset the idle timer on genuinely new packets.
      // If the EVB keeps resending duplicates we've already received, the timer
      // runs down and fires — triggering ACK/NACK without waiting for the EVB's
      // 5 s ACK timeout.
      _windowAckTimer?.cancel();
      _windowAckTimer = Timer(const Duration(seconds: 2), _onWindowAckTimeout);
    }

    debugPrint("OPUS PKT $packetIndex/$totalPackets flags=0x${flags.toRadixString(16)}");

    // Throttle UI redraws
    if (_streamPacketsReceived % 10 == 0 && mounted) setState(() {});

    // WINDOW_END: EVB finished sending this window — send ACK or NACK
    if (flags & _flagWindowEnd != 0) {
      _handleWindowEnd(packetIndex);
      return;
    }

    // Fallback: full stream done
    final isEnd = (flags & 0x02 != 0);
    final isComplete = _streamPacketsTotal > 0 && _streamPacketsReceived >= _streamPacketsTotal;
    if ((isEnd || isComplete) && _isReceivingStream) {
      if (!isEnd) _addMessage("END flag not received — saving on packet count");
      _saveStreamToFile();
    }
  }

  void _onWindowAckTimeout() {
    if (!_isReceivingStream) return;
    // WINDOW_END was dropped — infer it from the expected window boundary.
    final expectedLast = (_windowStart + _windowSize).clamp(1, _streamPacketsTotal) - 1;
    debugPrint("App-side window timeout — inferring WINDOW_END at pkt $expectedLast");
    _handleWindowEnd(expectedLast);
  }

  void _handleWindowEnd(int lastPacketIndex) {
    _windowAckTimer?.cancel();
    // On the first WINDOW_END for a window (normal send), lock in the true window
    // boundary. On retransmit WINDOW_END, lastPacketIndex is the last MISSING packet
    // (not the last of the window), so we must reuse the locked-in _windowEnd.
    if (_windowRetries == 0) {
      _windowEnd = (lastPacketIndex + 1).clamp(0, _streamPacketsTotal);
    }
    final end = _windowEnd;

    // Guard: ignore duplicate WINDOW_END for the same boundary.
    // Reset to -1 after sending NACK so the retransmit's WINDOW_END is not blocked.
    if (end == _lastHandledWindowEnd) return;
    _lastHandledWindowEnd = end;

    // Find gaps across the full window (always 0.._windowEnd, not just 0..lastPacket)
    final missing = <int>[];
    for (int i = _windowStart; i < end; i++) {
      if (!_receivedIndices.contains(i)) missing.add(i);
    }

    if (missing.isNotEmpty && _windowRetries < _maxRetries) {
      // NACK — selective retransmit. Reset guard so retransmit WINDOW_END gets through.
      _windowRetries++;
      _lastHandledWindowEnd = -1;
      debugPrint("NACK window $_windowStart–$end missing=${missing.length} retry=$_windowRetries");
      _sendJson({"cmd": "nack", "window_start": _windowStart, "missing": missing});
    } else {
      // ACK — advance to next window
      if (missing.isNotEmpty) {
        debugPrint("Window $_windowStart–$end: gave up on ${missing.length} gap(s) after $_windowRetries retries");
      }
      _windowStart = end;
      _windowRetries = 0;

      if (_windowStart >= _streamPacketsTotal) {
        debugPrint("ACK final (stream complete)");
        _sendJson({"cmd": "ack", "next": _windowStart});
        _isReceivingStream = false;
        _saveStreamToFile();
      } else {
        debugPrint("ACK next window $_windowStart");
        _sendJson({"cmd": "ack", "next": _windowStart});
      }
    }
  }

  Future<void> _sendJson(Map<String, dynamic> payload) async {
    final c = _helloChar;
    if (c == null) {
      debugPrint("sendJson: helloChar is null — write dropped");
      return;
    }
    final json = jsonEncode(payload);
    final bytes = utf8.encode(json);
    debugPrint("sendJson → $json  (write=${c.properties.write} wwr=${c.properties.writeWithoutResponse})");
    try {
      if (c.properties.write) {
        await c.write(bytes, withoutResponse: false);
        debugPrint("sendJson: write-with-response OK");
      } else if (c.properties.writeWithoutResponse) {
        // unreliable path — device may not receive this
        debugPrint("sendJson: WARNING — falling back to write-without-response");
        await c.write(bytes, withoutResponse: true);
      } else {
        debugPrint("sendJson: ERROR — characteristic has no write property");
        _addMessage("JSON write failed: no write property on characteristic");
      }
    } catch (e) {
      debugPrint("sendJson failed: $e");
      _addMessage("JSON write failed: $e");
    }
  }

  Future<void> _saveStreamToFile() async {
    try {
      final raw = _streamPreAllocBuffer ?? Uint8List(0);
      final oggBytes = _wrapInOggOpus(raw);
      final folder = await getApplicationDocumentsDirectory();
      //final path = '${folder.path}/ble_stream_${DateTime.now().millisecondsSinceEpoch ~/ 100}.opus';
      final path = '${folder.path}/BLE_STREAM ${_getFormattedDate()}.opus';
      await File(path).writeAsBytes(oggBytes);

      final files = await _recordingList();
      if (mounted) {
        setState(() {
          _recordings = files;
          _isReceivingStream = false;
          _streamPacketsReceived = 0;
          _streamPacketsTotal = 0;
          _streamPreAllocBuffer = null;
          _windowStart = 0;
          _windowRetries = 0;
          _windowEnd = 0;
          _lastHandledWindowEnd = -1;
          _receivedIndices.clear();
        });
      }
      final dropped = _streamPacketsTotal - _streamPacketsReceived;
      final lossPercent = _streamPacketsTotal > 0
          ? (dropped * 100 ~/ _streamPacketsTotal)
          : 0;
      _addMessage(
        "Stream saved: ${path.split('/').last}\n"
        "Received $_streamPacketsReceived / $_streamPacketsTotal pkts "
        "($lossPercent% loss${lossPercent > 20 ? ' — audio quality degraded' : ''})",
      );
    } catch (e) {
      _addMessage("Stream save failed: $e");
      if (mounted) setState(() => _isReceivingStream = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Ogg Opus container writer
  // Wraps raw CBR Opus frames (80 bytes each, 16 kHz mono, 32 kbit/s) into a
  // valid Ogg Opus file that audioplayers can play back.
  // ---------------------------------------------------------------------------

  static final List<int> _crcTable = () {
    final t = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int crc = i << 24;
      for (int j = 0; j < 8; j++) {
        crc = (crc & 0x80000000) != 0
            ? ((crc << 1) ^ 0x04c11db7) & 0xFFFFFFFF
            : (crc << 1) & 0xFFFFFFFF;
      }
      t[i] = crc;
    }
    return t;
  }();

  static int _oggCrc(List<int> data) {
    int crc = 0;
    for (final b in data) {
      crc = ((crc << 8) ^ _crcTable[((crc >> 24) ^ b) & 0xFF]) & 0xFFFFFFFF;
    }
    return crc;
  }

  static Uint8List _buildOggPage({
    required List<int> packetData,
    required int serialNumber,
    required int pageSequenceNumber,
    required int granulePosition,
    required int headerType,
    List<int>? segmentSizes,
  }) {
    // Build lacing values from packet sizes
    final lacing = <int>[];
    for (final size in segmentSizes ?? [packetData.length]) {
      int rem = size;
      while (rem >= 255) {
        lacing.add(255);
        rem -= 255;
      }
      lacing.add(rem);
    }

    final numSegs   = lacing.length;
    final headerLen = 27 + numSegs;
    final page      = Uint8List(headerLen + packetData.length);
    final bd        = ByteData.view(page.buffer);

    page[0] = 0x4F; page[1] = 0x67; page[2] = 0x67; page[3] = 0x53; // OggS
    page[4] = 0x00; // stream structure version
    page[5] = headerType;
    bd.setInt64(6, granulePosition, Endian.little);
    bd.setUint32(14, serialNumber, Endian.little);
    bd.setUint32(18, pageSequenceNumber, Endian.little);
    bd.setUint32(22, 0, Endian.little); // CRC placeholder
    page[26] = numSegs;
    for (int i = 0; i < numSegs; i++) { page[27 + i] = lacing[i]; }
    page.setRange(headerLen, page.length, packetData);

    final crc = _oggCrc(page.toList());
    bd.setUint32(22, crc, Endian.little);
    return page;
  }

  static Uint8List _wrapInOggOpus(Uint8List rawOpusBytes) {
    const frameSize      = 80;   // bytes per CBR frame at 32 kbit/s, 20 ms
    const samplesPerFrame = 320;  // 20 ms × 16 kHz
    const sampleRate     = 16000;
    const preSkip        = 312;   // standard pre-skip for 16 kHz Opus
    const framesPerPage  = 50;
    const serial         = 0x12345678;

    // TOC byte for SILK WB 20ms mono 1 frame (config 13 = 0x68).
    // Used to replace all-zero frame slots (dropped BLE packets) with a valid
    // Opus frame header so the decoder can apply PLC instead of decoding garbage.
    const opusTocByte = 0x68;

    // Split raw bytes into 80-byte Opus frames, patching dropped regions.
    final frames = <List<int>>[];
    for (int i = 0; i + frameSize <= rawOpusBytes.length; i += frameSize) {
      final frame = rawOpusBytes.sublist(i, i + frameSize);
      // Detect a fully-zero frame (dropped BLE packet region).
      final isDropped = frame.every((b) => b == 0);
      if (isDropped) {
        // Write a valid TOC byte so the decoder can apply its own PLC.
        final patched = Uint8List(frameSize);
        patched[0] = opusTocByte;
        frames.add(patched);
      } else {
        frames.add(frame);
      }
    }

    final out = BytesBuilder();

    // Page 0: OpusHead (BOS)
    final head = Uint8List(19);
    final hbd  = ByteData.view(head.buffer);
    head.setRange(0, 8, utf8.encode('OpusHead'));
    head[8] = 1;      // version
    head[9] = 1;      // channels (mono)
    hbd.setUint16(10, preSkip, Endian.little);
    hbd.setUint32(12, sampleRate, Endian.little);
    hbd.setInt16(16, 0, Endian.little); // output gain
    head[18] = 0;     // channel mapping family
    out.add(_buildOggPage(
      packetData: head, serialNumber: serial,
      pageSequenceNumber: 0, granulePosition: 0, headerType: 0x02,
    ));

    // Page 1: OpusTags
    final vendor = utf8.encode('BLE Apollo');
    final tags   = Uint8List(8 + 4 + vendor.length + 4);
    final tbd    = ByteData.view(tags.buffer);
    tags.setRange(0, 8, utf8.encode('OpusTags'));
    tbd.setUint32(8, vendor.length, Endian.little);
    tags.setRange(12, 12 + vendor.length, vendor);
    tbd.setUint32(12 + vendor.length, 0, Endian.little); // 0 user comments
    out.add(_buildOggPage(
      packetData: tags, serialNumber: serial,
      pageSequenceNumber: 1, granulePosition: 0, headerType: 0x00,
    ));

    // Audio pages
    int pageSeq = 2;
    int granule  = 0;
    for (int i = 0; i < frames.length; i += framesPerPage) {
      final end   = (i + framesPerPage < frames.length) ? i + framesPerPage : frames.length;
      final slice = frames.sublist(i, end);
      granule    += slice.length * samplesPerFrame;
      final data  = slice.expand((f) => f).toList();
      out.add(_buildOggPage(
        packetData: data,
        serialNumber: serial,
        pageSequenceNumber: pageSeq++,
        granulePosition: granule,
        headerType: end >= frames.length ? 0x04 : 0x00, // EOS on last page
        segmentSizes: slice.map((f) => f.length).toList(),
      ));
    }

    return out.toBytes();
  }

  // ---------------------------------------------------------------------------

  BluetoothCharacteristic? _findHelloCharacteristic(List<BluetoothService> services) {
    for (final s in services) {
      if (s.uuid == helloServiceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid == helloValueUuid) return c;
        }
      }
    }
    return null;
  }

  void _printGattToTerminal(List<BluetoothService> services) {
    debugPrint("===== GATT DISCOVERY START =====");
    for (final s in services) {
      debugPrint("Service: ${s.uuid.str}");
      for (final c in s.characteristics) {
        debugPrint(
          "  Char: ${c.uuid.str} (props: "
          "r=${c.properties.read} "
          "w=${c.properties.write} "
          "wnr=${c.properties.writeWithoutResponse} "
          "n=${c.properties.notify} "
          "i=${c.properties.indicate})",
        );
        for (final d in c.descriptors) {
          debugPrint("    Desc: ${d.uuid.str}");
        }
      }
    }
    debugPrint("===== GATT DISCOVERY END =====");
  }

  Future<void> _readHelloOnce() async {
    final c = _helloChar;
    if (c == null) return;

    if (!c.properties.read) {
      debugPrint("Hello characteristic is not readable.");
      _addMessage("Read not supported on characteristic.");
      return;
    }

    final bytes = await c.read();
    final text  = utf8.decode(bytes, allowMalformed: true).trim();
    debugPrint("READ RX: $text");
    _addMessage(text);
  }

  Future<void> _enableNotifyAndListen(BluetoothCharacteristic c) async {
    await _notifySub?.cancel();
    _notifySub = null;

    if (!c.properties.notify) {
      _addMessage("Characteristic does not support notify");
      return;
    }

    try {
      await c.setNotifyValue(true);
      debugPrint("Notify enabled via setNotifyValue(true)");
    } catch (e) {
      debugPrint("setNotifyValue failed: $e");
      _addMessage("Notify enable failed: $e");
      return;
    }

    _notifySub = c.onValueReceived.listen(
      (value) {
        final text = utf8.decode(value, allowMalformed: true).trim();
        debugPrint("NOTIFY RX: $text");
        _addMessage(text);
      },
      onError: (err) {
        debugPrint("NOTIFY ERROR: $err");
        _addMessage("Notify error: $err");
      },
    );

    _addMessage("Notify enabled ✅");
  }

  @override
  void dispose() {
    _keepAliveTimer?.cancel();
    _windowAckTimer?.cancel();
    _notifySub?.cancel();
    _opusNotifySub?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _connectionSub?.cancel();
    super.dispose();
  }

  Widget _messagesBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: _messages.isEmpty
          ? const Text(
              "(no messages yet)",
              style: TextStyle(fontFamily: 'monospace', fontSize: 13),
            )
          : ListView.separated(
              itemCount: _messages.length,
              separatorBuilder: (_, _) => const Divider(height: 10),
              itemBuilder: (context, i) => Text(
                _messages[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
    );
  }

  Future<List<FileSystemEntity>> _recordingList() async {
    final folder = await getApplicationDocumentsDirectory();
    final files  = Directory(folder.path).listSync();
    return files.where((f) =>
      f.path.endsWith('.opus') || f.path.endsWith('.m4a')
    ).toList();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BluetoothConnectionState>(
      stream: widget.device.connectionState,
      builder: (context, snapshot) {
        if (_isConnecting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return _isConnected ? _buildConnectedUI() : _buildDisconnectedUI();
        }

        final state = snapshot.data;
        return state == BluetoothConnectionState.connected
            ? _buildConnectedUI()
            : _buildDisconnectedUI();
      },
    );
  }

    Future<void> _seek(String path, double value) async {
    if (_playingPath == path) {
      await _audioPlayer.seek(Duration(milliseconds: value.toInt()));
    }
  }

  Widget _buildConnectedUI() {
    final deviceName = widget.device.platformName.isNotEmpty
        ? widget.device.platformName
        : 'Unknown device';
    final deviceId = widget.device.remoteId.str;

    return Scaffold(
      backgroundColor: cream,
      appBar: AppBar(
        backgroundColor: darkGreen,
        foregroundColor: Colors.white,
        title: const Text('Device Info'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: !_isConnected
            ? const Center(child: Text('Connection failed'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Device header
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.bluetooth, size: 60, color: darkGreen),
                      const SizedBox(height: 8),
                      const Text('Connected', textAlign: TextAlign.center),
                      const SizedBox(height: 4),
                      Text('Name: $deviceName'),
                      Text('ID: $deviceId'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // JSON messages from device
                  Row(
                    children: [
                      const Expanded(
                        child: Text("Incoming JSON from Apollo:", style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      TextButton(onPressed: _readHelloOnce, child: const Text("Read")),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(flex: 1, child: _messagesBox()),
                  // BLE stream progress
                  if (_isReceivingStream) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.sensors, size: 16, color: darkGreen),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text("Downloading audio...", style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                        Text(
                          "$_streamPacketsReceived / $_streamPacketsTotal",
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: _streamPacketsTotal > 0
                          ? _streamPacketsReceived / _streamPacketsTotal
                          : null,
                    ),
                  ],
                  const SizedBox(height: 8),
                  // Download audio button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isReceivingStream ? null : _replayLastRecording,
                      icon: const Icon(Icons.replay),
                      label: const Text('Replay Last Recording'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Recordings list
                  Row(
                    children: [
                      const Expanded(
                        child: Text("Voice Recordings", style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      TextButton(
                        onPressed: _recordAudio,
                        child: Text(_isRecording ? "Stop" : "Record Audio"),
                      ),
                    ],
                  ),
                  Expanded(
                    flex: 2,
                    child: _recordings.isEmpty
                        ? const Text("No recordings.")
                        : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      itemCount: _recordings.length,
                      itemBuilder: (context, index) {
                        final file = _recordings[index];
                        final path = file.path;
                        final rawName = path.split('/').last.replaceAll('.opus', '');
                        final displayName = rawName.replaceAll('.', ':');
                        final isPlaying = _playingPath == path;
                        final sliderMax = isPlaying && _duration.inMilliseconds > 0
                            ? _duration.inMilliseconds.toDouble()
                            : 1.0;
                        final sliderVal = isPlaying
                            ? _position.inMilliseconds.toDouble().clamp(0.0, sliderMax)
                            : 0.0;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Container(
                            decoration: BoxDecoration(
                              color: buttonGreen,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.fromLTRB(5, 10, 8, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // Name + trash
                                Row(
                                  children: [
                                    Expanded(
                                      child: Center(
                                        child: Text(
                                          displayName,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () => _deleteRecording(file),
                                      child: const Padding(
                                        padding: EdgeInsets.only(top: 2),
                                        child: Icon(Icons.delete_outline, color: Colors.white70, size: 22),
                                      ),
                                    ),
                                  ],
                                ),

                                // Play/pause button
                                GestureDetector(
                                  onTap: () => _togglePlay(path),
                                  child: Icon(
                                    isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                                    color: Colors.white,
                                    size: 36,
                                  ),
                                ),

                                // Scrub slider
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 2,
                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Colors.white30,
                                    thumbColor: Colors.white,
                                    overlayColor: Colors.white24,
                                  ),
                                  child: Slider(
                                    value: sliderVal,
                                    min: 0,
                                    max: sliderMax,
                                    onChangeStart: (v) {
                                      setState(() => _isDragging = true);
                                    },
                                    onChanged: (v) {
                                      setState(() => _position = Duration(milliseconds: v.toInt()));
                                    },
                                    onChangeEnd: (v) async {
                                      await _seek(path, v);
                                      setState(() => _isDragging = false);
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _deleteRecording(FileSystemEntity file) async {
    try {
      if (_playingPath == file.path) {
        await _audioPlayer.stop();
        setState(() { _playingPath = null; _position = Duration.zero; });
      }
      if (await file.exists()) {
        await file.delete();
        _addMessage("Deleted: ${file.path.split('/').last}");
        final updatedList = await _recordingList();
        setState(() => _recordings = updatedList);
      }
    } catch (e) {
      _addMessage("Delete failed: $e");
    }
  }

  
  Future<void> _togglePlay(String path) async {
    if (_playingPath == path) {
      await _audioPlayer.pause();
      setState(() => _playingPath = null);
    } else {
      await _audioPlayer.stop();
      setState(() { _playingPath = path; _position = Duration.zero; });
      await _audioPlayer.play(DeviceFileSource(path));
    }
  }

  Future<void> _recordAudio() async {
    if (_isRecording) {
      final path = await _audioRecorder.stop();
      _recordingList().then((files) => setState(() {
            _isRecording = false;
            _recordings = files;
          }));
      _addMessage("Audio saved to $path");
    } else {
      await Permission.microphone.request();
      if (await _audioRecorder.hasPermission()) {
        final folder = await getApplicationDocumentsDirectory();
        final path = '${folder.path}/Rec ${_getFormattedDate()}.opus';
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path,
        );
        setState(() => _isRecording = true);
        _addMessage("Recording started");
      } else {
        _addMessage("No Microphone permissions");
      }
    }
  }

    // Return a formatted date by year-month-day hour.minute.seconds
    String _getFormattedDate() {
    final now = DateTime.now();
    final y = now.year;
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h.$min.$s';
  }

  Future<void> _replayLastRecording() async {
    // Asks the EVB to re-transmit the last encoded recording from packet 0.
    // Normal flow does not need this — the device auto-sends as soon as encoding completes.
    _sendJson({"cmd": "stream_start", "window": _windowSize});
    _addMessage("Requested replay (window=$_windowSize)");
  }

  Widget _buildDisconnectedUI() {
    return Scaffold(
      backgroundColor: cream,
      appBar: AppBar(
        backgroundColor: darkGreen,
        foregroundColor: Colors.white,
        title: const Text('Device Disconnected'),
      ),
      body: Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 80, color: darkGreen),
            const SizedBox(height: 16),
            const Text(
              "Device Disconnected",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: darkGreen,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "The connection to Apollo was lost.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity, 
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: buttonGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back to Scan'),
              ),
            ),
          ],
        ),
      ),
    )
    );
  }
}
