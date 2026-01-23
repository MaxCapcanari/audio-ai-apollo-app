import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Available BLE devices',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const BleDeviceListPage(),
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

    _latestByDevice.clear();
    setState(() {});

    await FlutterBluePlus.stopScan();
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    _loadSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.blue.shade600,
        foregroundColor: Colors.white,
        title: const Text('Available BLE devices'),
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
              color: Colors.blue.shade50,
              child: Text(
                'Name: $_savedName   |   ID: $_savedId',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
          Expanded(
            child: StreamBuilder<List<ScanResult>>(
              stream: FlutterBluePlus.scanResults,
              initialData: const [],
              builder: (context, snapshot) {
                final results = snapshot.data ?? const [];

                for (final r in results) {
                  _latestByDevice[r.device.remoteId] = r;
                }

                final devices = _latestByDevice.values.toList()
                  ..sort((a, b) => b.rssi.compareTo(a.rssi));

                if (devices.isEmpty) {
                  return Center(
                    child: Text(
                      kIsWeb
                          ? 'BLE scanning is not supported on Flutter Web.'
                          : 'No devices found. Tap refresh to scan.',
                    ),
                  );
                }

                return ListView.separated(
                  itemCount: devices.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final r = devices[index];
                    final name =
                        r.advertisementData.advName.trim().isNotEmpty
                            ? r.advertisementData.advName.trim()
                            : (r.device.platformName.trim().isNotEmpty
                                ? r.device.platformName.trim()
                                : 'Unknown device');

                    return ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(name),
                      subtitle: Text(r.device.remoteId.str),
                      trailing: Text('${r.rssi} dBm'),
                      onTap: () {},
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

/* ============================
   SETTINGS PAGE (PERSISTENT)
   ============================ */

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
