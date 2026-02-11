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
  static final Guid helloServiceUuid = Guid(
    "12341234-5678-1234-1234-1234567890AB",
  );
  static final Guid helloValueUuid = Guid(
    "12341234-5678-1234-1234-1234567890AC",
  );

  bool _isConnecting = true;
  bool _isConnected = false;

  String _settingsJsonPretty = '';

  BluetoothCharacteristic? _helloChar;
  StreamSubscription<List<int>>? _notifySub;

  final List<String> _messages = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _connectToDevice();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('user_name') ?? '';
    final id = prefs.getString('user_id') ?? '';
    final pretty = const JsonEncoder.withIndent(
      '  ',
    ).convert({"name": name, "id": id});

    if (!mounted) return;
    setState(() {
      _settingsJsonPretty = pretty;
    });
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
      debugPrint(
        "Connecting to: ${widget.device.remoteId.str} name=${widget.device.platformName}",
      );

      try {
        await widget.device.disconnect();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));

      await widget.device.connect(timeout: const Duration(seconds: 6));
      await Future.delayed(const Duration(milliseconds: 600));

      try {
        await widget.device.requestMtu(247);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _isConnected = true;
      });

      await _setupHelloCharacteristicReadAndNotify();
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
      final services = await widget.device.discoverServices();
      _printGattToTerminal(services);

      BluetoothCharacteristic? found = _findHelloCharacteristic(services);

      if (found == null) {
        debugPrint(
          "Custom service not found, retrying discovery once (Android cache common)...",
        );
        await Future.delayed(const Duration(milliseconds: 600));
        final services2 = await widget.device.discoverServices();
        _printGattToTerminal(services2);
        found = _findHelloCharacteristic(services2);
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

    } catch (e) {
      _addMessage("Setup failed: $e");
    }
  }

  BluetoothCharacteristic? _findHelloCharacteristic(
    List<BluetoothService> services,
  ) {
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
    final text = utf8.decode(bytes, allowMalformed: true).trim();

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


  void _sendSettingsJson() {
    // later
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    widget.device.disconnect();
    super.dispose();
  }

  Widget _codeBlock(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          text.isEmpty ? '{}' : text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      ),
    );
  }

  Widget _messagesBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
      ),
      child: _messages.isEmpty
          ? const Text(
              "(no messages yet)",
              style: TextStyle(fontFamily: 'monospace', fontSize: 13),
            )
          : ListView.separated(
              itemCount: _messages.length,
              separatorBuilder: (_, __) => const Divider(height: 10),
              itemBuilder: (context, i) {
                return Text(
                  _messages[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                );
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // If the bluetooth connection state changes, run code to change UI
    return StreamBuilder<BluetoothConnectionState>(
      stream: widget.device.connectionState,
      initialData: BluetoothConnectionState.disconnected,
      builder: (context, snapshot) {
        final state = snapshot.data;

      // display right page depending of if the device is connected
        if (state == BluetoothConnectionState.connected) { 
          return _buildConnectedUI();
        } else {
          return _buildDisconnectedUI();
        }
      }
    );
  }

  // if the device is connected, share device info
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
        child: _isConnecting
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    "Connecting in progress....",
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "Settings (JSON):",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  _codeBlock(_settingsJsonPretty),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _sendSettingsJson,
                      child: const Text('Send'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "Incoming JSON from Apollo:",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(height: 220, child: _messagesBox()),
                ],
              )
            : !_isConnected
            ? const Center(child: Text('Connection failed'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.bluetooth, size: 60, color: Colors.blue),
                      const SizedBox(height: 16),
                      const Text('Connected', textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Text('Name: $deviceName'),
                      const SizedBox(height: 8),
                      Text('ID: $deviceId'),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "Settings (JSON):",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  _codeBlock(_settingsJsonPretty),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _sendSettingsJson,
                      child: const Text('Send'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          "Incoming JSON from Apollo:",
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton(
                        onPressed: _readHelloOnce,
                        child: const Text("Read"),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: _messagesBox()),
                ],
              ),
      ),
    );
  }

  // sends you to screen with disconnected text
  Widget _buildDisconnectedUI() {
    return Scaffold(
      body: Center(
        child: Text("disconnected"))
    );
  }
}