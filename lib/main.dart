import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ==========================================
// 1. BLUETOOTH BLE SERVICE (NORDIC UART)
// ==========================================
class DspBleService extends ChangeNotifier {
  // Nordic UART Service (NUS) Standard UUIDs
  static final Guid serviceUuid = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid rxUuid = Guid("6E400002-B5A3-F393-E0A9-E50E24DCCA9E"); // App to ESP32 Write
  static final Guid txUuid = Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E"); // ESP32 to App Notify

  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? _rxChar;
  BluetoothCharacteristic? _txChar;
  StreamSubscription? _notifySubscription;
  StreamSubscription? _connectionSubscription;

  bool isConnected = false;
  bool isScanning = false;
  String connectedDeviceName = "NOT CONNECTED";
  List scanResults = [];

  // Dynamic Theme Colors (ST7789 Display Sync)
  Color colorCore = const Color(0xFF0B2B26);   
  Color colorTip = const Color(0xFF8EB69B);    
  Color colorAccent = const Color(0xFFDAF1DE); 
  Color colorRail = const Color(0xFF235347);   

  bool isNightModeManual = false;
  bool isNightScheduleEnabled = false;
  int nightStartHour = 22;
  int nightStartMinute = 0;
  int nightEndHour = 6;
  int nightEndMinute = 0;
  Timer? _scheduleCheckerTimer;

  bool get isNightModeActive {
    if (isNightScheduleEnabled) {
      final now = DateTime.now();
      final currentMinutes = now.hour * 60 + now.minute;
      final startMinutes = nightStartHour * 60 + nightStartMinute;
      final endMinutes = nightEndHour * 60 + nightEndMinute;

      if (startMinutes <= endMinutes) {
        return currentMinutes >= startMinutes && currentMinutes < endMinutes;
      } else {
        return currentMinutes >= startMinutes || currentMinutes < endMinutes;
      }
    }
    return isNightModeManual;
  }

  Color get activeAccent => isNightModeActive ? const Color(0xFF7A6843) : colorAccent;
  Color get activeBackground => isNightModeActive ? const Color(0xFF000000) : const Color(0xFF04070B);
  Color get activeCardBg => isNightModeActive 
      ? const Color(0xFF080808) 
      : Color.alphaBlend(colorCore.withOpacity(0.35), const Color(0xFF0C111A));
  Color get activeRail => isNightModeActive ? const Color(0xFF2B2418) : colorRail;

  // Audio Core States
  int volume = 4;
  int subVolume = 12;
  int bass = 0;
  int mid = 0;
  int treble = 4;
  int balance = 0;
  int fader = 0;
  bool isSubPhaseInverted = false;
  String hpfCutoff = "Flat";
  bool isBeepEnabled = true;
  bool isRtaPreTone = true;

  String currentSource = "BT"; 
  String sleepTimer = "OFF";
  int sleepRemainingSec = 0;
  bool isSystemSleeping = false;
  Timer? _localCountDownTimer;

  // Filter & Hardware States
  int gain = 0;
  int loudness = 0;
  String loudnessFreq = "400 Hz";
  bool isLoudnessHighBoost = false;

  String subCutoff = "80 Hz";
  String bassCenter = "60 Hz";
  String bassQ = "1.25";
  bool isBassDcMode = false;

  String midCenter = "1.0 kHz";
  String midQ = "1.0";
  String trebleCut = "12.5 kHz";

  // MTU Incoming String Buffer
  String _rxBuffer = "";

  void setVolume(int val) {
    final target = val.clamp(0, 29);
    volume = target;
    notifyListeners();
    sendDspValue("VOL", volume);
  }

  void setSubVolume(int val) {
    final target = val.clamp(0, 29);
    subVolume = target;
    notifyListeners();
    sendDspValue("SUB", subVolume);
  }

  void adjustSubVolume(int delta) {
    final target = (subVolume + delta).clamp(0, 29);
    if (target != subVolume) {
      setSubVolume(target);
    }
  }

  void setBass(int val) {
    final target = val.clamp(-15, 15);
    bass = target;
    notifyListeners();
    sendDspValue("BAS", bass);
  }

  void setMid(int val) {
    final target = val.clamp(-15, 15);
    mid = target;
    notifyListeners();
    sendDspValue("MID", mid);
  }

  void setTreble(int val) {
    final target = val.clamp(-15, 15);
    treble = target;
    notifyListeners();
    sendDspValue("TRE", treble);
  }

  void setSleepTimerOption(String opt) {
    if (opt == "OFF") {
      _localCountDownTimer?.cancel();
      sleepRemainingSec = 0;
      sleepTimer = "OFF";
      isSystemSleeping = false;
      notifyListeners();
      sendDspValue("SLP", "OFF");
    } else {
      sleepTimer = opt;
      isSystemSleeping = false;
      notifyListeners();
      sendDspValue("SLP", opt);
    }
  }

  void wakeSystem() {
    isSystemSleeping = false;
    sleepTimer = "OFF";
    sleepRemainingSec = 0;
    notifyListeners();
    sendDspValue("SLP", "WAKE");
  }

  static Color _hexToColor(String hex) {
    hex = hex.replaceAll("#", "").trim();
    if (hex.length == 6) hex = "FF$hex";
    return Color(int.tryParse(hex, radix: 16) ?? 0xFF00F2FE);
  }

  static String _colorToHex(Color c) {
    return c.value.toRadixString(16).substring(2).toUpperCase();
  }

  Future<void> initBleAndAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();

    final cCoreVal = prefs.getInt('saved_clr_core');
    final cTipVal = prefs.getInt('saved_clr_tip');
    final cAccVal = prefs.getInt('saved_clr_acc');
    final cRailVal = prefs.getInt('saved_clr_rail');

    if (cCoreVal != null) colorCore = Color(cCoreVal);
    if (cTipVal != null) colorTip = Color(cTipVal);
    if (cAccVal != null) colorAccent = Color(cAccVal);
    if (cRailVal != null) colorRail = Color(cRailVal);

    isNightModeManual = prefs.getBool('night_manual') ?? false;
    isNightScheduleEnabled = prefs.getBool('night_sched_enabled') ?? false;
    nightStartHour = prefs.getInt('night_start_h') ?? 22;
    nightStartMinute = prefs.getInt('night_start_m') ?? 0;
    nightEndHour = prefs.getInt('night_end_h') ?? 6;
    nightEndMinute = prefs.getInt('night_end_m') ?? 0;

    _startScheduleChecker();

    final savedRemoteId = prefs.getString('saved_ble_remote_id');
    if (savedRemoteId != null && savedRemoteId.isNotEmpty) {
      try {
        final d = BluetoothDevice.fromId(savedRemoteId);
        connectToDevice(d);
      } catch (_) {
        startScan();
      }
    } else {
      startScan();
    }
  }

  void _startScheduleChecker() {
    _scheduleCheckerTimer?.cancel();
    _scheduleCheckerTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (isNightScheduleEnabled) notifyListeners();
    });
  }

  void startScan() async {
    if (isScanning) return;
    scanResults.clear();
    isScanning = true;
    notifyListeners();

    FlutterBluePlus.scanResults.listen((results) {
      scanResults = results;
      notifyListeners();

      for (var r in results) {
        final devName = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
        if (devName == "Naveen_Audio_System" && !isConnected) {
          stopScan();
          connectToDevice(r.device);
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    isScanning = false;
    notifyListeners();
  }

  void stopScan() async {
    await FlutterBluePlus.stopScan();
    isScanning = false;
    notifyListeners();
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      stopScan();
      await device.connect(autoConnect: true, timeout: const Duration(seconds: 8));

      connectedDevice = device;
      final devName = device.platformName.isNotEmpty ? device.platformName : "Naveen_Audio_System";
      connectedDeviceName = devName;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_ble_remote_id', device.remoteId.str);

      _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.connected) {
          isConnected = true;
        } else {
          isConnected = false;
          _rxChar = null;
          _txChar = null;
          notifyListeners();
        }
      });

      try {
        await device.requestMtu(512);
      } catch (_) {}

      final services = await device.discoverServices();
      for (var s in services) {
        if (s.uuid == serviceUuid) {
          for (var c in s.characteristics) {
            if (c.uuid == rxUuid) _rxChar = c;
            if (c.uuid == txUuid) {
              _txChar = c;
              await _txChar!.setNotifyValue(true);
              _notifySubscription?.cancel();
              _notifySubscription = _txChar!.onValueReceived.listen((data) {
                _handleIncomingBytes(data);
              });
            }
          }
        }
      }

      isConnected = true;
      notifyListeners();
      sendCommand("REQ_SYNC");
    } catch (_) {
      isConnected = false;
      notifyListeners();
    }
  }

  Future<void> disconnectDevice() async {
    _notifySubscription?.cancel();
    _connectionSubscription?.cancel();
    await connectedDevice?.disconnect();
    isConnected = false;
    connectedDevice = null;
    connectedDeviceName = "NOT CONNECTED";
    notifyListeners();
  }

  void _handleIncomingBytes(List<int> bytes) {
    final chunk = utf8.decode(bytes, allowMalformed: true);
    _rxBuffer += chunk;

    if (_rxBuffer.contains("\n")) {
      final lines = _rxBuffer.split("\n");
      for (int i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.isNotEmpty) {
          _parseSync(line);
        }
      }
      _rxBuffer = lines.last;
    } else if (_rxBuffer.contains(";") && _rxBuffer.endsWith(";")) {
      _parseSync(_rxBuffer.trim());
      _rxBuffer = "";
    }
  }

  void sendCommand(String cmd) async {
    if (isConnected && _rxChar != null) {
      try {
        final payload = utf8.encode("$cmd\n");
        await _rxChar!.write(payload, withoutResponse: true);
      } catch (_) {}
    }
  }

  void sendDspValue(String key, dynamic value) {
    sendCommand("$key:$value");
  }

  Future<void> applySynchronizedTheme(Color core, Color tip, Color accent, Color rail) async {
    colorCore = core;
    colorTip = tip;
    colorAccent = accent;
    colorRail = rail;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('saved_clr_core', core.value);
    await prefs.setInt('saved_clr_tip', tip.value);
    await prefs.setInt('saved_clr_acc', accent.value);
    await prefs.setInt('saved_clr_rail', rail.value);

    final cmd = "CLR:${_colorToHex(core)},${_colorToHex(tip)},${_colorToHex(accent)},${_colorToHex(rail)}";
    sendCommand(cmd);
  }

  Future<void> setNightModeManual(bool val) async {
    isNightModeManual = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('night_manual', val);
  }

  Future<void> setNightSchedule(bool enabled, int startH, int startM, int endH, int endM) async {
    isNightScheduleEnabled = enabled;
    nightStartHour = startH;
    nightStartMinute = startM;
    nightEndHour = endH;
    nightEndMinute = endM;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('night_sched_enabled', enabled);
    await prefs.setInt('night_start_h', startH);
    await prefs.setInt('night_start_m', startM);
    await prefs.setInt('night_end_h', endH);
    await prefs.setInt('night_end_m', endM);
  }

  void setSource(String sourceName) {
    currentSource = sourceName;
    notifyListeners();
    sendDspValue("INP", sourceName);
  }

  void adjustVolume(int delta) {
    final target = (volume + delta).clamp(0, 29);
    if (target != volume) {
      setVolume(target);
    }
  }

  void dispatchTextCommand(String text) {
    final clean = text.trim().toLowerCase();
    final match = RegExp(r'(set\s+)?vol(ume)?\s+(\d+)').firstMatch(clean);

    if (match != null) {
      final target = int.tryParse(match.group(3) ?? "")?.clamp(0, 29);
      if (target != null) {
        setVolume(target);
        return;
      }
    }

    if (clean.contains("mute")) {
      setVolume(0);
      return;
    }

    sendCommand(text.trim());
  }

  void _startLocalCountdown() {
    _localCountDownTimer?.cancel();
    if (sleepRemainingSec > 0 && !isSystemSleeping) {
      _localCountDownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (sleepRemainingSec > 0 && !isSystemSleeping) {
          sleepRemainingSec--;
          notifyListeners();
        } else {
          timer.cancel();
          if (sleepRemainingSec <= 0) {
            isSystemSleeping = true;
            sleepTimer = "SLEEP";
          }
          notifyListeners();
        }
      });
    }
  }

  void _parseSync(String payload) {
    if (!payload.contains("SYNC:")) return;
    final clean = payload.substring(payload.indexOf("SYNC:")).replaceFirst("SYNC:", "");
    final tokens = clean.split(";");

    for (var token in tokens) {
      final parts = token.split("=");
      if (parts.length != 2) continue;
      final k = parts[0].trim();
      final v = parts[1].trim();

      switch (k) {
        case "VOL": volume = int.tryParse(v) ?? volume; break;
        case "SUB": subVolume = int.tryParse(v) ?? subVolume; break;
        case "BAS": bass = int.tryParse(v) ?? bass; break;
        case "MID": mid = int.tryParse(v) ?? mid; break;
        case "TRE": treble = int.tryParse(v) ?? treble; break;
        case "BAL": balance = int.tryParse(v) ?? balance; break;
        case "FAD": fader = int.tryParse(v) ?? fader; break;
        case "PHASE": isSubPhaseInverted = (v == "1" || v.toLowerCase() == "true"); break;
        case "HPF": hpfCutoff = v; break;
        case "BEEP": isBeepEnabled = (v == "1" || v.toLowerCase() == "true"); break;
        case "RTA": isRtaPreTone = (v == "1" || v.toLowerCase() == "true"); break;
        case "GAIN": gain = int.tryParse(v) ?? gain; break;
        case "LOUD": loudness = int.tryParse(v) ?? loudness; break;
        case "LDF": loudnessFreq = v; break;
        case "LDHB": isLoudnessHighBoost = (v == "1" || v.toLowerCase() == "true"); break;
        case "SUBCUT": subCutoff = v; break;
        case "BCTR": bassCenter = v; break;
        case "BQ": bassQ = v; break;
        case "BDC": isBassDcMode = (v == "1" || v.toLowerCase() == "true"); break;
        case "MIDF": midCenter = v; break;
        case "MIDQ": midQ = v; break;
        case "TRECUT": trebleCut = v; break;
        case "INP": currentSource = v; break;
        case "SLP": 
          sleepTimer = v;
          isSystemSleeping = (v == "SLEEP");
          if (v == "OFF") {
            _localCountDownTimer?.cancel();
            sleepRemainingSec = 0;
          }
          break;
        case "SLP_SEC": 
          sleepRemainingSec = int.tryParse(v) ?? 0;
          if (sleepRemainingSec > 0 && !isSystemSleeping) {
            _startLocalCountdown();
          } else {
            _localCountDownTimer?.cancel();
          }
          break;
        case "CLR_CORE": colorCore = _hexToColor(v); break;
        case "CLR_TIP": colorTip = _hexToColor(v); break;
        case "CLR_ACC": colorAccent = _hexToColor(v); break;
        case "CLR_RAIL": colorRail = _hexToColor(v); break;
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _scheduleCheckerTimer?.cancel();
    _localCountDownTimer?.cancel();
    _notifySubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }
}

// ==========================================
// 2. MAIN ENTRY POINT
// ==========================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DspBleService()..initBleAndAutoConnect()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dsp = context.watch<DspBleService>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NV Studio DSP',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: dsp.activeBackground,
      ),
      home: const StudioScreen(),
    );
  }
}

// ==========================================
// 3. STUDIO UI SCREEN
// ==========================================
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  int? localSub;
  int? localBass;
  int? localMid;
  int? localTreble;
  bool isEqExpanded = false;
  final TextEditingController _commandController = TextEditingController();

  String _formatTime(int totalSeconds) {
    if (totalSeconds <= 0) return "OFF";
    int m = totalSeconds ~/ 60;
    int s = totalSeconds % 60;
    return "${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  String _formatTimeOfDay(int h, int m) {
    final period = h >= 12 ? "PM" : "AM";
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return "${hour12.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}$period";
  }

  void _showBleScanDialog(BuildContext context, DspBleService dsp) {
    dsp.startScan();

    showDialog(
      context: context,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: AlertDialog(
          backgroundColor: const Color(0xFF101622),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: dsp.activeRail),
          ),
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "BLUETOOTH DSP CONTROLLER",
                style: TextStyle(color: Color(0xFF90A4AE), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 20),
                onPressed: () => dsp.startScan(),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 250,
            child: Consumer<DspBleService>(
              builder: (_, srv, __) {
                if (srv.scanResults.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: srv.activeAccent, strokeWidth: 2),
                        const SizedBox(height: 12),
                        const Text("Scanning for DSP Hardware...", style: TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: srv.scanResults.length,
                  itemBuilder: (context, i) {
                    final dynamic r = srv.scanResults[i];
                    final name = r.device.platformName.isNotEmpty 
                        ? r.device.platformName 
                        : (r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : "Unknown Device");
                    final isTarget = name.contains("Naveen") || name.contains("Audio");

                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: isTarget ? srv.activeAccent.withOpacity(0.12) : const Color(0xFF141C2B),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: isTarget ? srv.activeAccent : Colors.white12),
                      ),
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.bluetooth_audio_rounded, color: isTarget ? srv.activeAccent : Colors.white54),
                        title: Text(name, style: TextStyle(color: isTarget ? srv.activeAccent : Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                        subtitle: Text(r.device.remoteId.str, style: const TextStyle(color: Colors.white38, fontSize: 9)),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isTarget ? srv.activeAccent : const Color(0xFF1E283B),
                            foregroundColor: isTarget ? Colors.black : Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () {
                            srv.connectToDevice(r.device);
                            Navigator.pop(ctx);
                          },
                          child: const Text("PAIR", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900)),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          actions: [
            if (dsp.isConnected)
              TextButton(
                onPressed: () {
                  dsp.disconnectDevice();
                  Navigator.pop(ctx);
                },
                child: const Text("DISCONNECT", style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("CLOSE", style: TextStyle(color: Color(0xFF78909C), fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  void _showSourceSelectorSheet(BuildContext context, DspBleService dsp) {
    final accent = dsp.activeAccent;
    final rail = dsp.activeRail;

    showModalBottomSheet(
      context: context,
      backgroundColor: dsp.isNightModeActive ? const Color(0xFF060606) : const Color(0xFF0A0F17),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final sources = [
          {"id": "BT", "title": "BLUETOOTH AUDIO", "sub": "Direct Wireless Stream A2DP", "icon": Icons.bluetooth_audio_rounded},
          {"id": "AUX", "title": "AUXILIARY IN", "sub": "Analog Line Input SE2 Direct", "icon": Icons.cable_rounded},
          {"id": "SD_Card", "title": "SD CARD PLAYER", "sub": "Hardware Studio Direct Playback", "icon": Icons.sd_storage_rounded},
        ];

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "SELECT AUDIO INPUT SOURCE",
                    style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                    onPressed: () => Navigator.pop(ctx),
                  )
                ],
              ),
              const SizedBox(height: 12),
              ...sources.map((s) {
                final isSel = dsp.currentSource == s["id"];
                return GestureDetector(
                  onTap: () {
                    dsp.setSource(s["id"] as String);
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: isSel ? accent.withOpacity(0.14) : const Color(0xFF101724),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSel ? accent : rail.withOpacity(0.5),
                        width: isSel ? 1.6 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(s["icon"] as IconData, color: isSel ? accent : const Color(0xFF78909C), size: 22),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s["title"] as String,
                                style: TextStyle(
                                  color: isSel ? accent : Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                s["sub"] as String,
                                style: const TextStyle(color: Color(0xFF607D8B), fontSize: 9.5),
                              ),
                            ],
                          ),
                        ),
                        if (isSel) Icon(Icons.check_circle_rounded, color: accent, size: 18),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ],
          ),
        );
      },
    );
  }

  void _showSettingsSheet(BuildContext context, DspBleService dsp) {
    bool isThemeExpanded = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: dsp.isNightModeActive ? const Color(0xFF050505) : const Color(0xFF0B1017),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalContext, setModalState) {
            final accent = dsp.activeAccent;
            final rail = dsp.activeRail;

            // Plain inference to prevent browser HTML tag stripping
            final studioPalettes = [
              {"name": "Nordic Sage", "core": const Color(0xFF0B2B26), "tip": const Color(0xFF8EB69B), "accent": const Color(0xFFDAF1DE), "rail": const Color(0xFF235347)},
              {"name": "Cyber Ice", "core": const Color(0xFF002244), "tip": const Color(0xFF00E5FF), "accent": const Color(0xFFE0F7FA), "rail": const Color(0xFF005588)},
              {"name": "Amber Tube", "core": const Color(0xFF381A00), "tip": const Color(0xFFFFB300), "accent": const Color(0xFFFFF3E0), "rail": const Color(0xFF6D3900)},
              {"name": "Stealth Slate", "core": const Color(0xFF141820), "tip": const Color(0xFF94A3B8), "accent": const Color(0xFFF8FAFC), "rail": const Color(0xFF334155)},
              {"name": "Deep Crimson", "core": const Color(0xFF33080E), "tip": const Color(0xFFFF4D6D), "accent": const Color(0xFFFFE5EC), "rail": const Color(0xFF66101F)},
              {"name": "Emerald Neon", "core": const Color(0xFF062B19), "tip": const Color(0xFF10B981), "accent": const Color(0xFFD1FAE5), "rail": const Color(0xFF0F5A36)},
              {"name": "Amethyst", "core": const Color(0xFF240A34), "tip": const Color(0xFFD500F9), "accent": const Color(0xFFF3E5F5), "rail": const Color(0xFF5E1B7D)},
              {"name": "Neon Sunset", "core": const Color(0xFF331000), "tip": const Color(0xFFFF6D00), "accent": const Color(0xFFFFE0B2), "rail": const Color(0xFF7A2E00)},
              {"name": "Electric Lime", "core": const Color(0xFF172B00), "tip": const Color(0xFF76FF03), "accent": const Color(0xFFF1F8E9), "rail": const Color(0xFF33691E)},
              {"name": "Synth Pink", "core": const Color(0xFF2B001F), "tip": const Color(0xFFFF1493), "accent": const Color(0xFFFFE4E1), "rail": const Color(0xFF8B008B)},
              {"name": "Deep Ocean", "core": const Color(0xFF001F3F), "tip": const Color(0xFF0074D9), "accent": const Color(0xFF7FDBFF), "rail": const Color(0xFF003366)},
              {"name": "Golden Master", "core": const Color(0xFF332900), "tip": const Color(0xFFFFD700), "accent": const Color(0xFFFFF8DC), "rail": const Color(0xFF665200)},
            ];

            final customColors = [
              const Color(0xFF00E5FF), const Color(0xFF00E676), const Color(0xFFFFB300),
              const Color(0xFFFF5722), const Color(0xFFFF1744), const Color(0xFFF50057),
              const Color(0xFFD500F9), const Color(0xFF7C4DFF), const Color(0xFF40C4FF),
              const Color(0xFF76FF03), const Color(0xFFF5F5F5), const Color(0xFFFF6E40),
            ];

            return Container(
              height: MediaQuery.of(modalContext).size.height * 0.92,
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
              child: ListView(
                physics: const BouncingScrollPhysics(),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "STUDIO DSP & HARDWARE CONTROLS",
                        style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      )
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 1. COLLAPSIBLE THEME CARD
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D14),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: rail),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            setModalState(() {
                              isThemeExpanded = !isThemeExpanded;
                            });
                          },
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.palette_rounded, color: accent, size: 18),
                                  const SizedBox(width: 8),
                                  const Text(
                                    "THEME SELECTOR & LIVE SYNC",
                                    style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: accent.withOpacity(0.16),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      "BLE SYNC",
                                      style: TextStyle(color: accent, fontSize: 8.5, fontWeight: FontWeight.w900),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(
                                    isThemeExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                                    color: accent,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        if (isThemeExpanded) ...[
                          const SizedBox(height: 14),
                          const Divider(color: Color(0xFF1C2638), height: 1),
                          const SizedBox(height: 12),
                          const Text("Select from 12 Studio Presets:", style: TextStyle(color: Color(0xFF78909C), fontSize: 9.5)),
                          const SizedBox(height: 8),

                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              childAspectRatio: 2.8,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: studioPalettes.length,
                            itemBuilder: (context, i) {
                              final p = studioPalettes[i];
                              final isSel = dsp.colorCore.value == (p["core"] as Color).value &&
                                  dsp.colorAccent.value == (p["accent"] as Color).value;

                              return GestureDetector(
                                onTap: () {
                                  dsp.applySynchronizedTheme(
                                    p["core"] as Color,
                                    p["tip"] as Color,
                                    p["accent"] as Color,
                                    p["rail"] as Color,
                                  );
                                  setModalState(() {});
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isSel ? (p["accent"] as Color).withOpacity(0.15) : const Color(0xFF101724),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isSel ? (p["accent"] as Color) : const Color(0xFF1E2A3A),
                                      width: isSel ? 1.8 : 1.0,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 22,
                                        height: 22,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [p["tip"] as Color, p["core"] as Color],
                                          ),
                                          border: Border.all(color: p["accent"] as Color, width: 1.5),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          p["name"] as String,
                                          style: TextStyle(
                                            color: isSel ? (p["accent"] as Color) : const Color(0xFFB0BEC5),
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 14),
                          const Divider(color: Color(0xFF1C2638), height: 1),
                          const SizedBox(height: 10),

                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "CUSTOM COLOR CREATOR",
                                style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold, letterSpacing: 1),
                              ),
                              Text("TAP TO INSTANT SYNC", style: TextStyle(color: accent, fontSize: 8.5, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 8),

                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: customColors.map((c) {
                              final isSel = dsp.colorAccent.value == c.value;
                              return GestureDetector(
                                onTap: () {
                                  final Color accentC = c;
                                  final Color tipC = c;
                                  final Color coreC = Color.lerp(c, Colors.black, 0.75)!;
                                  final Color railC = Color.lerp(c, Colors.black, 0.50)!;
                                  dsp.applySynchronizedTheme(coreC, tipC, accentC, railC);
                                  setModalState(() {});
                                },
                                child: Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: c,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: isSel ? Colors.white : Colors.black26,
                                      width: isSel ? 2.8 : 1.2,
                                    ),
                                    boxShadow: isSel
                                        ? [BoxShadow(color: c.withOpacity(0.6), blurRadius: 8, spreadRadius: 1.5)]
                                        : null,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 2. HARDWARE AUDIO & ANALYZER TOGGLES
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: rail),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.touch_app_rounded, color: accent, size: 18),
                                const SizedBox(width: 8),
                                const Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("TOUCH AUDIO FEEDBACK", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                    SizedBox(height: 2),
                                    Text("TDA7419 Hardware Click on Tap", style: TextStyle(color: Color(0xFF607D8B), fontSize: 9)),
                                  ],
                                ),
                              ],
                            ),
                            Switch(
                              value: dsp.isBeepEnabled,
                              activeColor: accent,
                              onChanged: (val) {
                                setModalState(() => dsp.isBeepEnabled = val);
                                dsp.sendDspValue("BEEP", val ? 1 : 0);
                              },
                            ),
                          ],
                        ),
                        const Divider(color: Color(0xFF1C2638), height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.equalizer_rounded, color: accent, size: 18),
                                const SizedBox(width: 8),
                                const Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("TRUE RTA SPECTRUM", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                    SizedBox(height: 2),
                                    Text("Pre-Tone Source Tap (Flat RTA)", style: TextStyle(color: Color(0xFF607D8B), fontSize: 9)),
                                  ],
                                ),
                              ],
                            ),
                            Switch(
                              value: dsp.isRtaPreTone,
                              activeColor: accent,
                              onChanged: (val) {
                                setModalState(() => dsp.isRtaPreTone = val);
                                dsp.sendDspValue("RTA", val ? 1 : 0);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Night Stealth Card
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: rail),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.nightlight_round, color: dsp.isNightModeActive ? const Color(0xFF7A6843) : const Color(0xFF78909C), size: 18),
                                const SizedBox(width: 8),
                                const Text("NIGHT STEALTH MODE", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Switch(
                              value: dsp.isNightModeManual,
                              activeColor: const Color(0xFF7A6843),
                              onChanged: (val) {
                                dsp.setNightModeManual(val);
                                setModalState(() {});
                              },
                            ),
                          ],
                        ),
                        const Divider(color: Color(0xFF1C2638), height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("AUTO TIME SCHEDULE", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold)),
                            Switch(
                              value: dsp.isNightScheduleEnabled,
                              activeColor: const Color(0xFF7A6843),
                              onChanged: (val) {
                                dsp.setNightSchedule(val, dsp.nightStartHour, dsp.nightStartMinute, dsp.nightEndHour, dsp.nightEndMinute);
                                setModalState(() {});
                              },
                            ),
