import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'device_info_page.dart';
import 'files_page.dart';

void main() {
  runApp(const MyApp());
}

// Replace your MyApp and add HomePage class

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Eating Analytics',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green.shade800),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    const darkGreen = Color(0xFF3B4A2F);
    const cream = Color(0xFFF5F0DC);
    const buttonGreen = Color(0xFF4A5E35);
    const bottomOrange = Color(0xFFCC7A3A);

    return Scaffold(
      backgroundColor: cream,
      appBar: AppBar(
        backgroundColor: darkGreen,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
        title: const Text(
          'AI EATING ANALYTICS',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            letterSpacing: 1.2,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: buttonGreen,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 2,
                        ),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const BleDeviceListPage(),
                            ),
                          );
                        },
                        child: const Text(
                          'PAIR DEVICE',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: buttonGreen,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 2,
                        ),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const FilesPage()),
                          );
                        },
                        child: const Text(
                          'FILES',
                          style: TextStyle(
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
          ),
          Container(
            height: 48,
            color: bottomOrange,
          ),
        ],
      ),
    );
  }
}

/*
============================
  BLE DEVICE LIST PAGE
============================
*/

class BleDeviceListPage extends StatefulWidget {
  const BleDeviceListPage({super.key});

  @override
  State<BleDeviceListPage> createState() => _BleDeviceListPageState();
}

class _BleDeviceListPageState extends State<BleDeviceListPage> {
  final Map<DeviceIdentifier, ScanResult> _latestByDevice = {};

  String _savedName = '';
  String _savedId = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    if (!kIsWeb) {
      _startScan();
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _savedName = prefs.getString('user_name') ?? '';
      _savedId = prefs.getString('user_id') ?? '';
    });
  }

  Future<void> _startScan() async {
    if (kIsWeb) return;

    final permissions = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    if (!permissions[Permission.bluetoothScan]!.isGranted) {
      return;
    }

    _latestByDevice.clear();
    setState(() {});

    await FlutterBluePlus.stopScan();
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 6),
      androidUsesFineLocation: true,
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    _loadSettings();
  }

  @override
  Widget build(BuildContext context) {
    const darkGreen = Color(0xFF3B4A2F);
    const cream = Color(0xFFF5F0DC);
    const buttonGreen = Color(0xFF4A5E35);

    return Scaffold(
      backgroundColor: cream,
      appBar: AppBar(
        backgroundColor: darkGreen,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
        title: const Text(
          'PAIR DEVICE',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            letterSpacing: 1.2,
          ),
        ),
        actions: [
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
          ),
          StreamBuilder<bool>(
            stream: FlutterBluePlus.isScanning,
            initialData: false,
            builder: (context, snapshot) {
              final isScanning = snapshot.data ?? false;
              return IconButton(
                onPressed: isScanning ? null : _startScan,
                icon: const Icon(Icons.refresh),
                tooltip: 'Scan',
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_savedName.isNotEmpty || _savedId.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: cream,
              child: Text(
                'Name: $_savedName   |   ID: $_savedId',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: darkGreen
                ),
                textAlign: TextAlign.center,
              ),
            ),
            
          Expanded(
            child: StreamBuilder<List<ScanResult>>(
              stream: FlutterBluePlus.scanResults,
              initialData: const [],
              builder: (context, snapshot) {
                final results = snapshot.data ?? const [];

                for (final r in results) {
                  if (r.rssi > -60 || r.device.isConnected) {
                    _latestByDevice[r.device.remoteId] = r;
                  }
                }

                final devices = _latestByDevice.values.toList()
                  ..sort((a, b) => b.rssi.compareTo(a.rssi));

                if (devices.isEmpty) {
                  return Center(
                    child: Text(
                      kIsWeb
                          ? 'BLE scanning is not supported on Flutter Web.'
                          : 'No devices found. Tap refresh to scan.',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final r = devices[index];
                    final name = r.advertisementData.advName.trim().isNotEmpty
                        ? r.advertisementData.advName.trim()
                        : (r.device.platformName.trim().isNotEmpty
                            ? r.device.platformName.trim()
                            : 'Unknown device');

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Material(
                        color: buttonGreen,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DeviceInfoPage(device: r.device),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 18,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  name.toUpperCase(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                Text(
                                  '${r.rssi} DBM',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/*
============================
  SETTINGS PAGE
============================
*/

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _nameController = TextEditingController();
  final _idController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _nameController.text = prefs.getString('user_name') ?? '';
    _idController.text = prefs.getString('user_id') ?? '';
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', _nameController.text.trim());
    await prefs.setString('user_id', _idController.text.trim());
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.blue.shade600,
        foregroundColor: Colors.white,
        title: const Text('Settings'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _idController,
              decoration: const InputDecoration(
                labelText: 'ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saveSettings,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
