import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

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

class BleDeviceListPage extends StatefulWidget {
  const BleDeviceListPage({super.key});

  @override
  State<BleDeviceListPage> createState() => _BleDeviceListPageState();
}

class _BleDeviceListPageState extends State<BleDeviceListPage> {
  final Map<DeviceIdentifier, ScanResult> _latestByDevice = {};

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    _latestByDevice.clear();
    setState(() {});

    // Request permissions
  final statuses = await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location,
  ].request();

  // Check if scan permission granted
  if (!statuses[Permission.bluetoothScan]!.isGranted) {
    print("Bluetooth scan permission denied");
    return;
  }

    await FlutterBluePlus.stopScan();
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.blue.shade600,
        foregroundColor: Colors.white,
        title: const Text('Available BLE devices'),
        actions: [
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
      body: StreamBuilder<List<ScanResult>>(
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
            return const Center(
              child: Text('No devices found. Tap refresh to scan.'),
            );
          }

          return ListView.separated(
            itemCount: devices.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final r = devices[index];
              final name = r.advertisementData.advName.trim().isNotEmpty
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
    );
  }
}
