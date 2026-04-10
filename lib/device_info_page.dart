import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeviceInfoPage extends StatefulWidget {
  final BluetoothDevice device;
  const DeviceInfoPage({super.key, required this.device});

  @override
  State<DeviceInfoPage> createState() => _DeviceInfoPageState();
}

class _DeviceInfoPageState extends State<DeviceInfoPage> {
  static const darkGreen = Color(0xFF3B4A2F);
  static const cream = Color(0xFFF5F0DC);
  static const buttonGreen = Color(0xFF4A5E35);
  static const textBoxColor = Color(0xFFDDDDC3);

  static final Guid helloServiceUuid = Guid("12341234-5678-1234-1234-1234567890AB");
  static final Guid helloValueUuid   = Guid("12341234-5678-1234-1234-1234567890AC");

  bool _isConnecting = true;
  bool _isConnected  = false;

  BluetoothCharacteristic? _helloChar;
  BluetoothCharacteristic? _helloWriteChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  Timer? _keepAliveTimer;

  final TextEditingController _jsonController = TextEditingController();
  final List<String> _messages = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
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

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('user_name') ?? '';
    final id   = prefs.getString('user_id') ?? '';
    final pretty = const JsonEncoder.withIndent('  ').convert({"name": name, "id": id});
    if (!mounted) return;
    setState(() => _jsonController.text = pretty);
  }

  void _addMessage(String text) {
    final msg = text.trim();
    if (msg.isEmpty || !mounted) return;
    setState(() => _messages.insert(0, msg));
  }

  Future<void> _connectToDevice() async {
    setState(() => _isConnecting = true);
    try {
      try { await widget.device.disconnect(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
      await widget.device.connect(timeout: const Duration(seconds: 6));
      await Future.delayed(const Duration(milliseconds: 600));
      try { await widget.device.requestMtu(247); } catch (_) {}

      if (!mounted) return;
      setState(() { _isConnecting = false; _isConnected = true; });

      await _setupCharacteristics();

      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
        if (_isConnected && _helloChar != null) await _readOnce();
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
        await Future.delayed(const Duration(milliseconds: 600));
        services = await widget.device.discoverServices();
        found = _findChar(services, helloServiceUuid, helloValueUuid);
      }
      if (found == null) { _addMessage("Characteristic not found."); return; }

      _helloChar = found;
      _helloWriteChar = _findWritable(services) ?? found;
      await _enableNotify(_helloChar!);
      await _readOnce();
    } catch (e) {
      _addMessage("Setup failed: $e");
    }
  }

  BluetoothCharacteristic? _findChar(List<BluetoothService> services, Guid sUuid, Guid cUuid) {
    for (final s in services) {
      if (s.uuid == sUuid) {
        for (final c in s.characteristics) {
          if (c.uuid == cUuid) return c;
        }
      }
    }
    return null;
  }

  BluetoothCharacteristic? _findWritable(List<BluetoothService> services) {
    for (final s in services) {
      if (s.uuid != helloServiceUuid) continue;
      for (final c in s.characteristics) {
        if (c.uuid == helloValueUuid && (c.properties.write || c.properties.writeWithoutResponse)) return c;
      }
      for (final c in s.characteristics) {
        if (c.properties.write || c.properties.writeWithoutResponse) return c;
      }
    }
    return null;
  }

  Future<void> _readOnce() async {
    final c = _helloChar;
    if (c == null || !c.properties.read) return;
    final bytes = await c.read();
    _addMessage(utf8.decode(bytes, allowMalformed: true).trim());
  }

  Future<void> _enableNotify(BluetoothCharacteristic c) async {
    await _notifySub?.cancel();
    if (!c.properties.notify) return;
    try {
      await c.setNotifyValue(true);
    } catch (e) {
      _addMessage("Notify enable failed: $e");
      return;
    }
    _notifySub = c.onValueReceived.listen(
      (value) => _addMessage(utf8.decode(value, allowMalformed: true).trim()),
      onError: (err) => _addMessage("Notify error: $err"),
    );
    _addMessage("Notify enabled ✅");
  }

  Future<void> _sendJson() async {
    final candidates = <BluetoothCharacteristic?>[_helloWriteChar, _helloChar]
        .whereType<BluetoothCharacteristic>().toSet().toList();
    if (candidates.isEmpty) { _addMessage("Not ready."); return; }

    final raw = _jsonController.text.trim();
    if (raw.isEmpty) { _addMessage("JSON is empty."); return; }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) { _addMessage("Must be a JSON object."); return; }
      final map = Map<String, dynamic>.from(decoded);
      map['timestamp'] = DateTime.now().toIso8601String();
      final payload = jsonEncode(map);
      _jsonController.text = const JsonEncoder.withIndent('  ').convert(map);
      final bytes = utf8.encode(payload);

      for (final c in candidates) {
        try {
          if (c.properties.write) { await c.write(bytes, withoutResponse: false, allowLongWrite: true); break; }
          if (c.properties.writeWithoutResponse) { await c.write(bytes, withoutResponse: true); break; }
        } catch (_) {}
      }
      _addMessage("TX: $payload");
    } catch (e) {
      _addMessage("Send failed: $e");
    }
  }

  @override
  void dispose() {
    _keepAliveTimer?.cancel();
    _notifySub?.cancel();
    _connectionSub?.cancel();
    _jsonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deviceName = widget.device.platformName.isNotEmpty
        ? widget.device.platformName.toUpperCase()
        : 'UNKNOWN DEVICE';

    return Scaffold(
      backgroundColor: cream,
      appBar: AppBar(
        backgroundColor: darkGreen,
        foregroundColor: Colors.white,
        centerTitle: false,
        elevation: 0,
        title: Text(
          '$deviceName ${_isConnecting ? "CONNECTING" : _isConnected ? "" : "DISCONNECTED"}',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1.1),
        ),
      ),
      body: _isConnecting
          ? const Center(child: CircularProgressIndicator())
          : !_isConnected
              ? _buildDisconnected()
              : _buildConnected(),
    );
  }

  Widget _buildConnected() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),

          // Connected badge
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: buttonGreen,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: const Text(
              'CONNECTED!',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
                letterSpacing: 1.5,
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Debug text box + send button
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: textBoxColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: darkGreen.withOpacity(0.4)),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _jsonController,
                      maxLines: null,
                      expands: true,
                      readOnly: true,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(12),
                        hintText: 'DEBUG TEXT',
                      ),
                    ),
                  ),

                  // Incoming messages
                  if (_messages.isNotEmpty)
                    Container(
                      height: 100,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: darkGreen.withOpacity(0.2))),
                      ),
                      child: ListView.builder(
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => Text(
                          _messages[i],
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),

                  // Send bar
                  GestureDetector(
                    onTap: _sendJson,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: const BoxDecoration(
                        color: darkGreen,
                        borderRadius: BorderRadius.only(
                          bottomLeft: Radius.circular(14),
                          bottomRight: Radius.circular(14),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'SEND',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          letterSpacing: 1.5,
                        ),
                      ),
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

  Widget _buildDisconnected() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('DISCONNECTED', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }
}