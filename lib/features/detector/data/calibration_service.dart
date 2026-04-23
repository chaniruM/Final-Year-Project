import 'package:shared_preferences/shared_preferences.dart';

class CalibrationService {
  static const String _keyThreshold = 'drowsy_threshold_ear';
  static const String _keyPerclos = 'drowsy_baseline_perclos';
  static const String _keyMar = 'drowsy_threshold_mar';
  static const String _keyPitch = 'drowsy_baseline_pitch';
  static const String _keyCalibratedEngine = 'calibrated_engine_mode';
  static const String _keyTrackingPreference =
      'global_tracking_preference_arkit';

  Future<void> saveBaselines(double earThreshold, double perclosBaseline,
      double marThreshold, double pitchBaseline,
      {required bool isARKit}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyThreshold, earThreshold);
    await prefs.setDouble(_keyPerclos, perclosBaseline);
    await prefs.setDouble(_keyMar, marThreshold);
    await prefs.setDouble(_keyPitch, pitchBaseline);
    await prefs.setString(_keyCalibratedEngine, isARKit ? 'arkit' : 'mlkit');
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

  Future<String?> getCalibratedEngine() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCalibratedEngine);
  }

  Future<void> setTrackingPreference(bool useARKit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyTrackingPreference, useARKit);
  }

  Future<bool?> getTrackingPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyTrackingPreference);
  }

  Future<void> clearSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyThreshold);
    await prefs.remove(_keyPerclos);
    await prefs.remove(_keyMar);
    await prefs.remove(_keyPitch);
    await prefs.remove(_keyCalibratedEngine);
  }
}
