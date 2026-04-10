import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  static const darkGreen   = Color(0xFF3B4A2F);
  static const cream       = Color(0xFFF5F0DC);
  static const buttonGreen = Color(0xFF4A5E35);

  final AudioPlayer _audioPlayer = AudioPlayer();
  late AudioRecorder _audioRecorder;

  List<FileSystemEntity> _recordings = [];
  String? _playingPath;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isRecording = false;

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    _loadRecordings();

    _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() {
        _playingPath = null;
        _position = Duration.zero;
      });
    });
  }

  Future<void> _loadRecordings() async {
    final folder = await getApplicationDocumentsDirectory();
    final files = Directory(folder.path)
        .listSync()
        .where((f) => f.path.endsWith('.opus'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    setState(() => _recordings = files);
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _audioRecorder.stop();
      setState(() => _isRecording = false);
      await _loadRecordings();
    } else {
      await Permission.microphone.request();
      if (await _audioRecorder.hasPermission()) {
        final folder = await getApplicationDocumentsDirectory();
        final path = '${folder.path}/recording_${DateTime.now().millisecondsSinceEpoch ~/ 100}.opus';
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.opus),
          path: path,
        );
        setState(() => _isRecording = true);
      }
    }
  }

  Future<void> _delete(FileSystemEntity file) async {
    if (_playingPath == file.path) {
      await _audioPlayer.stop();
      setState(() { _playingPath = null; _position = Duration.zero; });
    }
    if (await file.exists()) await file.delete();
    _loadRecordings();
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

  Future<void> _seek(String path, double value) async {
    if (_playingPath == path) {
      await _audioPlayer.seek(Duration(milliseconds: value.toInt()));
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: cream,
      appBar: AppBar(
        backgroundColor: darkGreen,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
        title: const Text(
          'AUDIO FILES',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, letterSpacing: 1.2),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: _toggleRecording,
              child: Icon(
                _isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
                color: _isRecording ? Colors.redAccent : Colors.white,
                size: 30,
              ),
            ),
          ),
        ],
      ),
      body: _recordings.isEmpty
          ? Center(
              child: Text(
                _isRecording ? 'Recording...' : 'No recordings yet.',
                style: const TextStyle(color: Colors.black54),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              itemCount: _recordings.length,
              itemBuilder: (context, index) {
                final file = _recordings[index];
                final path = file.path;
                final name = path.split('/').last.replaceAll('.opus', '');
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
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Name + trash
                        Row(
                          children: [
                            Expanded(
                              child: Center(
                                child: Text(
                                  name.toUpperCase(),
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
                              onTap: () => _delete(file),
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
                            onChanged: (v) => _seek(path, v),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}