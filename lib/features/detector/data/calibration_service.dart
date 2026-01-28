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







// import 'package:shared_preferences/shared_preferences.dart';
//
// class CalibrationService {
//   static const String keyEarThreshold = 'baseline_ear_threshold';
//
//   /// Calculates a personalized threshold based on captured EAR values.
//   /// Typically sets the threshold at 70% of the average 'open' eye value.
//   static const String keyBaselinePerclos = 'baseline_perclos';
//
//   /// Calculates a personalized threshold based on captured EAR values.
//   /// Also returns a baseline PERCLOS estimation (though usually 0 in calibration unless user is tired).
//   /// Returns a map: {'threshold': double, 'perclos': double}
//   Map<String, double> calculateBaselines(List<double> capturedEarValues) {
//     if (capturedEarValues.isEmpty) return {'threshold': 0.25, 'perclos': 0.10};
//
//     // 1. EAR Threshold
//     // Sort to find open eyes (top 30%)
//     List<double> sorted = List.from(capturedEarValues)..sort();
//     int startIndex = (sorted.length * 0.7).toInt();
//     var openValues = sorted.sublist(startIndex);
//     double avgOpenEar = openValues.reduce((a, b) => a + b) / openValues.length;
//     double threshold = avgOpenEar * 0.7;
//
//     // 2. Baseline PERCLOS (during calibration)
//     // We check how many frames during calibration were below this NEW threshold.
//     int closedFrames = capturedEarValues.where((ear) => ear < threshold).length;
//     // double baselinePerclos = capturedEarValues.isNotEmpty
//     //     ? closedFrames / capturedEarValues.length
//     //     : 0.0;
//     double baselinePerclos = 0.10;
//
//     return {
//       'threshold': threshold,
//       'perclos': baselinePerclos,
//     };
//   }
//
//   Future<void> saveBaselines(double earThreshold, double baselinePerclos) async {
//     final prefs = await SharedPreferences.getInstance();
//     await prefs.setDouble(keyEarThreshold, earThreshold);
//     await prefs.setDouble(keyBaselinePerclos, baselinePerclos);
//   }
//
//   Future<Map<String, double?>> getBaselines() async {
//     final prefs = await SharedPreferences.getInstance();
//     return {
//       'threshold': prefs.getDouble(keyEarThreshold),
//       'perclos': prefs.getDouble(keyBaselinePerclos),
//     };
//   }
// }
