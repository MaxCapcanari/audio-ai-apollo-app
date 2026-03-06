import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
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

  late AudioRecorder _audioRecorder;
  late AudioRecorder _audioRecorder;
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _isRecording = false;
  bool _isConnecting = true;
  bool _isConnected = false;

  final TextEditingController _settingsController = TextEditingController();

  BluetoothCharacteristic? _helloChar;
  BluetoothCharacteristic? _helloWriteChar;
  StreamSubscription<List<int>>? _notifySub;

  final List<String> _messages = [];

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
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
    _settingsController.text = pretty;
    setState(() {});
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
      var services = await widget.device.discoverServices();
      _printGattToTerminal(services);

      BluetoothCharacteristic? found = _findHelloCharacteristic(services);

      if (found == null) {
        debugPrint(
          "Custom service not found, retrying discovery once (Android cache common)...",
        );
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
      _helloWriteChar = _findWriteCharacteristic(services) ?? found;
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

  BluetoothCharacteristic? _findWriteCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final s in services) {
      if (s.uuid != helloServiceUuid) continue;

      for (final c in s.characteristics) {
        if (c.uuid == helloValueUuid &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          return c;
        }
      }

      for (final c in s.characteristics) {
        if (c.properties.write || c.properties.writeWithoutResponse) {
          return c;
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


  Future<void> _sendSettingsJson() async {
    final candidates = <BluetoothCharacteristic?>[_helloWriteChar, _helloChar]
        .whereType<BluetoothCharacteristic>()
        .toSet()
        .toList();

    if (candidates.isEmpty) {
      _addMessage("Send failed: characteristic not ready.");
      return;
    }

    final raw = _settingsController.text.trim();
    if (raw.isEmpty) {
      _addMessage("Send failed: JSON is empty.");
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _addMessage("Send failed: JSON must be an object.");
        return;
      }

      final payloadMap = Map<String, dynamic>.from(decoded);
      payloadMap['timestamp'] = DateTime.now().toIso8601String();

      final payload = jsonEncode(payloadMap);
      final pretty = const JsonEncoder.withIndent('  ').convert(payloadMap);
      _settingsController.text = pretty;

      final bytes = utf8.encode(payload);
      Object? lastError;
      var sent = false;

      for (final c in candidates) {
        try {
          if (c.properties.write) {
            await c.write(bytes, withoutResponse: false);
            sent = true;
            break;
          }

          if (c.properties.writeWithoutResponse) {
            await c.write(bytes, withoutResponse: true);
            sent = true;
            break;
          }

          // Fallback for stacks that misreport characteristic properties.
          try {
            await c.write(bytes, withoutResponse: false);
            sent = true;
            break;
          } catch (_) {
            await c.write(bytes, withoutResponse: true);
            sent = true;
            break;
          }
        } catch (e) {
          lastError = e;
        }
      }

      if (!sent) {
        _addMessage("Send failed: write rejected ($lastError).");
        return;
      }

      debugPrint("WRITE TX: $payload");
      _addMessage("TX: $payload");
    } catch (e) {
      _addMessage("Send failed: invalid JSON or write error ($e).");
    }
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _settingsController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    widget.device.disconnect();
    super.dispose();
  }

  Widget _jsonEditor() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
      ),
      child: TextField(
        controller: _settingsController,
        maxLines: 8,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.all(12),
          hintText: '{}',
          hintStyle: TextStyle(fontFamily: 'monospace'),
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

  Future<List<FileSystemEntity>> _recordingList() async {
    final folder = await getApplicationDocumentsDirectory();
    final List<FileSystemEntity> files = Directory(folder.path).listSync();
    return files.where((file) => file.path.endsWith('.m4a')).toList();
  }

  @override
  Widget build(BuildContext context) {
    // If the bluetooth connection state changes, run code to change UI
    return StreamBuilder<BluetoothConnectionState>(
      stream: widget.device.connectionState,
      builder: (context, snapshot) {
        final state = snapshot.data;

        // blank screen if data not received yet
        if (_isConnecting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          ); 
        }


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
                  _jsonEditor(),
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
                  _jsonEditor(),
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
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          "Voice Recordings",
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton(
                        onPressed: _recordAudio,
                        child:Text( _isRecording ? "Stop" : "Record Audio"),
                      ),
                    ],
                  ),
                  SizedBox (
                    height: 100,
                    child:  FutureBuilder<List<FileSystemEntity>>(
                    future: _recordingList(),
                    builder: (context, snapshot) {
                      final files = snapshot.data ?? []; // if no data, use an empty array
                      
                      // no list returned
                      if (files.isEmpty) {
                        return Text("No recordings.");
                      }
                      
                      // else return a listview of all items in files
                      return ListView.builder(
                        itemCount: files.length,
                        itemBuilder: (context, index) {
                        final file = files[index];
                        return ListTile(
                          title: Text(file.path.split('/').last),
                          onTap: () async {
                            await _audioPlayer.play(DeviceFileSource(file.path));
                            _addMessage("Playing: ${file.path.split('/').last}");
                          },
                      );
                    }
                  );
                }
              )
            )
          ],
        ),
      ),
    );
  }

  // toggle recording audio
  Future<void> _recordAudio() async {
    if (_isRecording) {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);
      _addMessage("Audio saved to $path");
    } else {
      if (await _audioRecorder.hasPermission()) {
        final folder = await getApplicationDocumentsDirectory();
        final String path = '${folder.path}/Recording_file_${DateTime.now()}.m4a';
        await _audioRecorder.start(const RecordConfig(), path: path);
        setState(() => _isRecording = true);
        _addMessage("Recording started");
      } else {
        _addMessage("No Microphone permissions");
      }
    }
  }

  // sends you to screen with disconnected text
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
              child: ElevatedButton( // back button
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
