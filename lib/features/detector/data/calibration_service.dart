import 'package:shared_preferences/shared_preferences.dart';

class CalibrationService {
  static const String _keyThreshold = 'drowsy_threshold_ear';
  static const String _keyPerclos = 'drowsy_baseline_perclos';
  static const String _keyMar = 'drowsy_threshold_mar';
  static const String _keyPitch = 'drowsy_baseline_pitch';

  Future<void> saveBaselines(double earThreshold, double perclosBaseline, double marThreshold, double pitchBaseline) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyThreshold, earThreshold);
    await prefs.setDouble(_keyPerclos, perclosBaseline);
    await prefs.setDouble(_keyMar, marThreshold);
    await prefs.setDouble(_keyPitch, pitchBaseline);
  }

  Future<Map<String, double>> getBaselines() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'threshold': prefs.getDouble(_keyThreshold) ?? 0.0,
      'perclos': prefs.getDouble(_keyPerclos) ?? 0.0,
      'mar': prefs.getDouble(_keyMar) ?? 0.0,
      'pitch': prefs.getDouble(_keyPitch) ?? 0.0,
    };
  }

  Future<void> clearSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyThreshold);
    await prefs.remove(_keyPerclos);
    await prefs.remove(_keyMar);
    await prefs.remove(_keyPitch);
  }
}