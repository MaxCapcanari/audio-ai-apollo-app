import 'dart:async';
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
  // JSON service
  static final Guid helloServiceUuid = Guid("12341234-5678-1234-1234-1234567890AB");
  static final Guid helloValueUuid   = Guid("12341234-5678-1234-1234-1234567890AC");

  // Opus audio stream service
  static final Guid opusServiceUuid = Guid("12341234-5678-1234-1234-1234567890BB");
  static final Guid opusCharUuid    = Guid("12341234-5678-1234-1234-1234567890BC");

  static final Guid helloServiceUuid = Guid("12341234-5678-1234-1234-1234567890AB");
  static final Guid helloValueUuid   = Guid("12341234-5678-1234-1234-1234567890AC");

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
  static const int _windowSize = 20;    // packets per window; tune up if loss improves
  static const int _maxRetries = 3;     // max NACK retries per window before skipping
  static const int _flagWindowEnd = 0x04; // new flag bit: EVB finished sending current window
  int _windowStart = 0;                 // first packet index of the current window
  int _windowRetries = 0;
  final Set<int> _receivedIndices = {}; // all packet indices received so far

  BluetoothCharacteristic? _helloChar;
  List<BluetoothService> _discoveredServices = [];
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _opusNotifySub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  Timer? _keepAliveTimer;

  final TextEditingController _jsonController = TextEditingController();
  final List<String> _messages = [];
  List<FileSystemEntity> _recordings = [];

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    _connectToDevice();

    _connectionSub = widget.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        if (mounted && !_isConnecting) {
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && !_isConnecting) _connectToDevice();
          });
        }
      }
    });
  }

  void _addMessage(String text) {
    final msg = text.trim();
    if (msg.isEmpty || !mounted) return;
    setState(() => _messages.insert(0, msg));
  }

  Future<void> _connectToDevice() async {
    setState(() => _isConnecting = true);
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
      setState(() { _isConnecting = false; _isConnected = true; });

      await _setupCharacteristics();

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
      setState(() { _isConnecting = false; _isConnected = false; });
      _addMessage("Connection failed: $e");
    }
  }

  Future<void> _setupCharacteristics() async {
    try {
      var services = await widget.device.discoverServices();
      BluetoothCharacteristic? found = _findChar(services, helloServiceUuid, helloValueUuid);
      if (found == null) {
        debugPrint("Custom service not found, retrying discovery once (Android cache common)...");
        await Future.delayed(const Duration(milliseconds: 600));
        services = await widget.device.discoverServices();
        found = _findChar(services, helloServiceUuid, helloValueUuid);
      }
      if (found == null) { _addMessage("Characteristic not found."); return; }

      _helloChar = found;
      _discoveredServices = services;
      await _enableNotifyAndListen(_helloChar!);
      await _readHelloOnce();
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

    if (flags & 0x01 != 0) { // START — reset all flow-control state
      _streamPreAllocBuffer = totalLen > 0 ? Uint8List(totalLen) : null;
      _streamPacketsTotal = totalPackets;
      _streamPacketsReceived = 0;
      _windowStart = 0;
      _windowRetries = 0;
      _receivedIndices.clear();
      if (mounted) setState(() => _isReceivingStream = true);
      _addMessage("Stream start: $totalPackets pkts, $totalLen bytes");
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
    if (!_receivedIndices.contains(packetIndex)) {
      _receivedIndices.add(packetIndex);
      _streamPacketsReceived++;
    }

    debugPrint("OPUS PKT $packetIndex/$totalPackets flags=0x${flags.toRadixString(16)}");

    // Throttle UI redraws
    if (_streamPacketsReceived % 10 == 0 && mounted) setState(() {});

    // WINDOW_END: EVB finished sending this window — send ACK or NACK
    if (flags & _flagWindowEnd != 0) {
      _handleWindowEnd();
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

  void _handleWindowEnd() {
    final windowEnd = (_windowStart + _windowSize).clamp(0, _streamPacketsTotal);

    // Find any missing indices in this window
    final missing = <int>[];
    for (int i = _windowStart; i < windowEnd; i++) {
      if (!_receivedIndices.contains(i)) missing.add(i);
    }

    if (missing.isNotEmpty && _windowRetries < _maxRetries) {
      // NACK — ask EVB to resend missing packets
      _windowRetries++;
      debugPrint("NACK window $_windowStart–$windowEnd missing=${missing.length} retry=$_windowRetries");
      _sendJson({"cmd": "nack", "window_start": _windowStart, "missing": missing});
    } else {
      // ACK — advance to next window
      if (missing.isNotEmpty) {
        _addMessage("Window $_windowStart: gave up on ${missing.length} missing after $_maxRetries retries");
      }
      _windowStart = windowEnd;
      _windowRetries = 0;

      if (_windowStart >= _streamPacketsTotal) {
        // All windows done — ACK the EVB first so it stops retrying, then save
        debugPrint("ACK final (stream complete)");
        _sendJson({"cmd": "ack", "next": _windowStart});
        _isReceivingStream = false; // guard against re-entry before async save completes
        _saveStreamToFile();
      } else {
        debugPrint("ACK next window $_windowStart");
        _sendJson({"cmd": "ack", "next": _windowStart});
      }
    }
  }

  void _sendJson(Map<String, dynamic> payload) {
    final c = _helloChar;
    if (c == null) return;
    final bytes = utf8.encode(jsonEncode(payload));
    if (c.properties.write) {
      c.write(bytes, withoutResponse: false).catchError((e) {
        debugPrint("JSON write failed: $e");
      });
    } else if (c.properties.writeWithoutResponse) {
      c.write(bytes, withoutResponse: true).catchError((e) {
        debugPrint("JSON write (wwr) failed: $e");
      });
    }
  }

  Future<void> _saveStreamToFile() async {
    try {
      final raw = _streamPreAllocBuffer ?? Uint8List(0);
      final oggBytes = _wrapInOggOpus(raw);
      final folder = await getApplicationDocumentsDirectory();
      final path = '${folder.path}/ble_stream_${DateTime.now().millisecondsSinceEpoch ~/ 100}.opus';
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

  Future<void> _readOnce() async {
    final c = _helloChar;
    if (c == null || !c.properties.read) return;
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
    _notifySub?.cancel();
    _opusNotifySub?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _connectionSub?.cancel();
    _jsonController.dispose();
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

  Widget _buildConnectedUI() {
    final deviceName = widget.device.platformName.isNotEmpty
        ? widget.device.platformName
        : 'Unknown device';
    final deviceId = widget.device.remoteId.str;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.blue.shade600,
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
                      const Icon(Icons.bluetooth, size: 60, color: Colors.blue),
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
                        const Icon(Icons.sensors, size: 16, color: Colors.blue),
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
                      onPressed: _isReceivingStream ? null : _startAudioDownload,
                      icon: const Icon(Icons.download),
                      label: const Text('Download Audio from Device'),
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
                            itemCount: _recordings.length,
                            itemBuilder: (context, index) {
                              final file     = _recordings[index];
                              final fileName = file.path.split('/').last;
                              final isBle    = fileName.endsWith('.opus');

                              return Card(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                child: ListTile(
                                  dense: true,
                                  title: Text(fileName, style: const TextStyle(fontSize: 13)),
                                  subtitle: Text(
                                    "${isBle ? 'BLE • ' : ''}"
                                    "${(file.statSync().size / 1024).toStringAsFixed(1)} KB",
                                  ),
                                  leading: Icon(
                                    isBle ? Icons.sensors : Icons.audiotrack,
                                    size: 20,
                                    color: isBle ? Colors.blue : null,
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                    onPressed: () => _deleteRecording(file),
                                  ),
                                  onTap: () async {
                                    await _audioPlayer.stop();
                                    _addMessage("Playing: $fileName");
                                    await _audioPlayer.play(DeviceFileSource(file.path));
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteRecording(FileSystemEntity file) async {
    try {
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
        final String path =
            '${folder.path}/recording_${DateTime.now().millisecondsSinceEpoch ~/ 100}.m4a';
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

  Future<void> _startAudioDownload() async {
    if (_discoveredServices.isEmpty) {
      _addMessage("Not ready: services not discovered yet.");
      return;
    }
    await _setupOpusCharacteristic(_discoveredServices);
    // Tell EVB to start streaming with our window size
    _sendJson({"cmd": "stream_start", "window": _windowSize});
    _addMessage("Requested stream (window=$_windowSize)");
  }

  Widget _buildDisconnectedUI() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("disconnected"),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}