import 'dart:collection';
import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
import '../models/driver_state.dart';

class DrowsinessLogic {
  // --- THRESHOLDS ---
  // Eyes
  static const double defaultEyeClosedThreshold = 0.20; // EAR below this = Closed
  static const int perclosWindowFrames = 150; // ~5 seconds at 30fps

  // Mouth
  static const double yawnMarThreshold = 0.50; // MAR above this = Yawning

  // Head
  static const double headNodPitchThreshold = -10.0; // Degrees. Below -10 is looking down.

  // --- FUSION WEIGHTS (Total 100) ---
  static const double weightEyes = 60.0;
  static const double weightHead = 25.0;
  static const double weightMouth = 15.0;

  // --- ALERTS ---
  static const double scoreThresholdWarning = 40.0;
  static const double scoreThresholdAlert = 80.0;

  // --- CRITICAL OVERRIDES (Safety Net) ---
  // If PERCLOS > 0.30 (30% of time eyes closed), trigger alert immediately.
  static const double criticalPerclos = 0.30;

  // --- MESH INDICES (MediaPipe 468 Standard) ---
  static const List<int> meshLeftEye = [362, 385, 387, 263, 373, 380];
  static const List<int> meshRightEye = [33, 160, 158, 133, 153, 144];
  static const int meshMouthUpper = 13;
  static const int meshMouthLower = 14;
  static const int meshMouthLeft = 78;
  static const int meshMouthRight = 308;

  // --- CALCULATIONS ---

  static double calculateEAR(Face face) {
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;

    if (leftEye == null || rightEye == null || leftEye.length < 3 || rightEye.length < 3) {
      double prob = ((face.leftEyeOpenProbability ?? 0.5) + (face.rightEyeOpenProbability ?? 0.5)) / 2;
      return prob * 0.35;
    }
    return (_getEyeRatio(leftEye) + _getEyeRatio(rightEye)) / 2.0;
  }

  static double calculateMeshEAR(FaceMesh mesh) {
    return (_getMeshEyeRatio(mesh, meshLeftEye) + _getMeshEyeRatio(mesh, meshRightEye)) / 2.0;
  }

  static double calculateMeshMAR(FaceMesh mesh) {
    final points = mesh.points;
    final upper = points[meshMouthUpper];
    final lower = points[meshMouthLower];
    final left = points[meshMouthLeft];
    final right = points[meshMouthRight];

    double height = _dist(upper, lower);
    double width = _dist(left, right);

    if (width <= 0) return 0.0;
    return height / width;
  }

  static double calculateLegacyMAR(Face face) {
    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;
    if (upper == null || lower == null || upper.isEmpty || lower.isEmpty) return 0.0;

    // Simple vertical distance of center points
    int centerU = upper.length ~/ 2;
    int centerL = lower.length ~/ 2;
    double h = (lower[centerL].y - upper[centerU].y).abs().toDouble();

    final lowerOuter = face.contours[FaceContourType.lowerLipBottom]?.points;
    if (lowerOuter == null) return 0.0;
    double w = (lowerOuter.last.x - lowerOuter.first.x).abs().toDouble();

    return w > 0 ? h / w : 0.0;
  }

  // --- PRIVATE HELPERS ---

  static double _getMeshEyeRatio(FaceMesh mesh, List<int> indices) {
    final p = mesh.points;
    // EAR = (|p2-p6| + |p3-p5|) / (2 * |p1-p4|)
    final p1 = p[indices[0]];
    final p2 = p[indices[1]];
    final p3 = p[indices[2]];
    final p4 = p[indices[3]];
    final p5 = p[indices[4]];
    final p6 = p[indices[5]];

    double v1 = _dist(p2, p6);
    double v2 = _dist(p3, p5);
    double h = _dist(p1, p4);

    if (h <= 0) return 0.0;
    return (v1 + v2) / (2.0 * h);
  }

  static double _dist(FaceMeshPoint p1, FaceMeshPoint p2) {
    return sqrt(pow(p1.x - p2.x, 2) + pow(p1.y - p2.y, 2));
  }

  static double _getEyeRatio(List<Point<int>> points) {
    // Basic bounding box estimation for legacy contours
    int minX = 10000, maxX = -10000;
    int minY = 10000, maxY = -10000;
    for (var p in points) {
      if (p.x < minX) minX = p.x; if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y; if (p.y > maxY) maxY = p.y;
    }
    double width = (maxX - minX).toDouble();
    double height = (maxY - minY).toDouble();
    return width > 0 ? height / width : 0.0;
  }
}

class SignalSmoother {
  final int _windowSize;
  final Queue<double> _buffer = Queue<double>();
  SignalSmoother({int windowSize = 5}) : _windowSize = windowSize;

  double smooth(double newValue) {
    if (_buffer.length >= _windowSize) _buffer.removeFirst();
    _buffer.add(newValue);
    if (_buffer.isEmpty) return 0.0;
    return _buffer.reduce((a, b) => a + b) / _buffer.length;
  }
  void reset() => _buffer.clear();
}

class FusionEngine {
  final Queue<bool> _eyeClosedBuffer = Queue<bool>();
  final SignalSmoother _earSmoother = SignalSmoother(windowSize: 3);
  final SignalSmoother _marSmoother = SignalSmoother(windowSize: 5);
  final SignalSmoother _pitchSmoother = SignalSmoother(windowSize: 10); // Slower smooth for head

  void reset() {
    _eyeClosedBuffer.clear();
    _earSmoother.reset();
    _marSmoother.reset();
    _pitchSmoother.reset();
  }

  Map<String, dynamic> processState({
    required DriverState state,
    required double earThreshold,
    required double marThreshold,
  }) {
    // 1. Smooth Inputs
    double sEar = _earSmoother.smooth(state.simulatedEar);
    double sMar = _marSmoother.smooth(state.mouthOpenness);
    double sPitch = _pitchSmoother.smooth(state.headPitch);

    // 2. Calculate Metrics

    // A. Eyes (PERCLOS)
    bool isEyeClosed = sEar < earThreshold;
    if (_eyeClosedBuffer.length >= DrowsinessLogic.perclosWindowFrames) {
      _eyeClosedBuffer.removeFirst();
    }
    _eyeClosedBuffer.add(isEyeClosed);

    int closedFrames = _eyeClosedBuffer.where((c) => c).length;
    double perclos = _eyeClosedBuffer.isEmpty ? 0.0 : closedFrames / _eyeClosedBuffer.length;

    // Normalize PERCLOS to a 0.0-1.0 score (Assuming > 0.4 PERCLOS is "Max Drowsy")
    double eyeScoreRaw = (perclos / 0.4).clamp(0.0, 1.0);
    double weightedEyeScore = eyeScoreRaw * DrowsinessLogic.weightEyes;

    // B. Mouth (Yawning)
    bool isYawning = sMar > marThreshold;
    double yawnScoreRaw = isYawning ? 1.0 : (sMar / marThreshold).clamp(0.0, 1.0);
    double weightedMouthScore = yawnScoreRaw * DrowsinessLogic.weightMouth;

    // C. Head (Nodding/Dropping)
    bool isNodding = sPitch < DrowsinessLogic.headNodPitchThreshold;
    double headScoreRaw = isNodding ? 1.0 : 0.0;
    // Gradual score: Map -5 (awake) to -20 (asleep)
    if (!isNodding && sPitch < -5) {
      headScoreRaw = ((-5 - sPitch) / 15).clamp(0.0, 1.0);
    }
    double weightedHeadScore = headScoreRaw * DrowsinessLogic.weightHead;

    // 3. Fusion Sum
    double totalScore = weightedEyeScore + weightedMouthScore + weightedHeadScore;

    // 4. Status Determination
    bool alert = totalScore >= DrowsinessLogic.scoreThresholdAlert;
    String status = "Active";

    // --- SAFETY NET: CRITICAL OVERRIDES ---
    // Even if the total fusion score is low (e.g. 60), if a specific
    // vital sign is critical, we force the alarm.

    // Force Alert if PERCLOS is critical (> 30%)
    if (perclos > DrowsinessLogic.criticalPerclos) {
      alert = true;
      // Force the score to be visually alarming if it isn't already
      if (totalScore < DrowsinessLogic.scoreThresholdAlert) {
        totalScore = DrowsinessLogic.scoreThresholdAlert;
      }
    }

    // Force Alert if Nodding (Acute danger)
    if (isNodding) {
      alert = true;
      if (totalScore < DrowsinessLogic.scoreThresholdAlert) {
        totalScore = DrowsinessLogic.scoreThresholdAlert;
      }
    }

    if (alert) {
      status = "DANGER: DROWSY!";
      if (isNodding) status = "WAKE UP (Nodding)!";
      else if (perclos > DrowsinessLogic.criticalPerclos) status = "WAKE UP (Eyes)!";
    } else if (totalScore >= DrowsinessLogic.scoreThresholdWarning) {
      status = "Warning: Fatigue Signs";
      if (isYawning) status = "Warning: Yawning";
    }

    return {
      'alert': alert,
      'status': status,
      'score': totalScore,
      'smoothedEar': sEar,
      'smoothedMar': sMar,
      'smoothedPitch': sPitch,
      'perclos': perclos,
    };
  }
}