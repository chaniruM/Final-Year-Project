import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drive_safe/features/detector/data/calibration_service.dart';

void main() {
  group('CalibrationService Tests', () {
    late CalibrationService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = CalibrationService();
    });

    test('saveBaselines and getBaselines work correctly', () async {
      await service.saveBaselines(0.2, 0.15, 0.4, -10.0, isARKit: true);

      final baselines = await service.getBaselines();
      
      expect(baselines['threshold'], 0.2);
      expect(baselines['perclos'], 0.15);
      expect(baselines['mar'], 0.4);
      expect(baselines['pitch'], -10.0);
    });

    test('getCalibratedEngine returns correct engine', () async {
      await service.saveBaselines(0.2, 0.15, 0.4, -10.0, isARKit: true);
      expect(await service.getCalibratedEngine(), 'arkit');

      await service.saveBaselines(0.2, 0.15, 0.4, -10.0, isARKit: false);
      expect(await service.getCalibratedEngine(), 'mlkit');
    });

    test('setTrackingPreference and getTrackingPreference work correctly', () async {
      await service.setTrackingPreference(true);
      expect(await service.getTrackingPreference(), true);

      await service.setTrackingPreference(false);
      expect(await service.getTrackingPreference(), false);
    });

    test('clearSettings removes all calibration data', () async {
      await service.saveBaselines(0.2, 0.15, 0.4, -10.0, isARKit: true);
      
      await service.clearSettings();
      
      final baselines = await service.getBaselines();
      expect(baselines['threshold'], 0.0);
      expect(baselines['perclos'], 0.0);
      expect(baselines['mar'], 0.0);
      expect(baselines['pitch'], 0.0);
      
      expect(await service.getCalibratedEngine(), isNull);
    });
  });
}
