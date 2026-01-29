import 'package:shared_preferences/shared_preferences.dart';

class CalibrationService {
  static const String _keyThreshold = 'drowsy_threshold_ear';
  static const String _keyPerclos = 'drowsy_baseline_perclos';
  static const String _keyMar = 'drowsy_threshold_mar'; // New Key

  Future<void> saveBaselines(double earThreshold, double perclosBaseline, double marThreshold) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyThreshold, earThreshold);
    await prefs.setDouble(_keyPerclos, perclosBaseline);
    await prefs.setDouble(_keyMar, marThreshold);
  }

  Future<Map<String, double>> getBaselines() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'threshold': prefs.getDouble(_keyThreshold) ?? 0.0,
      'perclos': prefs.getDouble(_keyPerclos) ?? 0.0,
      'mar': prefs.getDouble(_keyMar) ?? 0.0, // Return saved MAR or 0.0
    };
  }

  Future<void> clearSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
