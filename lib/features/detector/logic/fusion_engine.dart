import 'dart:collection';
import '../../../core/constants/drowsiness_constants.dart';
import '../../../core/utils/signal_smoother.dart';

class FusionEngine {
  final Queue<bool> _eyeClosedBuffer = Queue<bool>();

  final SignalSmoother _earSmoother = SignalSmoother(windowSize: 3);
  final SignalSmoother _pitchSmoother = SignalSmoother(windowSize: 8);
  final SignalSmoother _marSmoother = SignalSmoother(windowSize: 5);

  double _baselinePerclos = 0.0;
  DateTime? _lastEyesDetectedTime;

  FusionEngine({double baselinePerclos = 0.0}) {
    _baselinePerclos = baselinePerclos;
    _lastEyesDetectedTime = DateTime.now();
  }

  void updateBaseline(double baseline) {
    _baselinePerclos = baseline;
  }

  void reset() {
    _eyeClosedBuffer.clear();
    _earSmoother.reset();
    _pitchSmoother.reset();
    _marSmoother.reset();
    _lastEyesDetectedTime = DateTime.now();
  }

  Map<String, dynamic> processFrame({
    required double currentEar,
    required double headPitch,
    required double mar,
    required double earThreshold,
    required double marThreshold,
  }) {
    final now = DateTime.now();

    // 1. Smooth Inputs
    double sEar = _earSmoother.smooth(currentEar);
    double sPitch = _pitchSmoother.smooth(headPitch);
    double sMar = _marSmoother.smooth(mar);

    // 2. Check for Occlusion (Eyes not seen for > 2 seconds)
    if (currentEar > 0.0) {
      _lastEyesDetectedTime = now;
    }
    final timeSinceEyesLastSeen = now.difference(_lastEyesDetectedTime ?? now);
    final bool isOccluded = timeSinceEyesLastSeen.inSeconds > 2;

    // 3. Update History (PERCLOS)
    bool eyesClosed = DrowsinessConstants.isDrowsy(sEar, earThreshold);

    // Only update eye buffer if NOT occluded (garbage data otherwise)
    if (!isOccluded) {
      if (_eyeClosedBuffer.length >= DrowsinessConstants.perclosWindowFrames) {
        _eyeClosedBuffer.removeFirst();
      }
      _eyeClosedBuffer.add(eyesClosed);
    }

    int closedFrames = _eyeClosedBuffer.where((c) => c).length;
    double currentPerclos = _eyeClosedBuffer.isEmpty ? 0.0 : closedFrames / _eyeClosedBuffer.length;

    // 4. Calculate Scores
    double score = 0.0;

    // A. Eyes Score (PERCLOS)
    double effectivePerclosThreshold = _baselinePerclos + DrowsinessConstants.perclosTolerance;
    // Avoid division by zero
    if (effectivePerclosThreshold == 0) effectivePerclosThreshold = 0.01;

    // Calculate ratio: 1.0 means we are AT the threshold. 2.0 means double the threshold.
    double perclosRatio = currentPerclos / effectivePerclosThreshold;
    // Cap ratio at 2.5 to prevent one metric from totally dominating
    if (perclosRatio > 2.5) perclosRatio = 2.5;

    // B. Binary Events
    bool isNodding = sPitch < DrowsinessConstants.headNodPitchThreshold;
    bool isYawning = sMar > marThreshold;

    // 5. Fusion Logic (Adaptive Weights)
    if (isOccluded) {
      // OCCLUSION MODE: Trust Head & Mouth
      score += isNodding ? DrowsinessConstants.weightHeadOccluded : 0;
      score += isYawning ? DrowsinessConstants.weightMouthOccluded : 0;
    } else {
      // NORMAL MODE: Fusion
      // Base score from eyes (e.g. Ratio 1.0 * 60 = 60 points)
      score += perclosRatio * DrowsinessConstants.weightEyes;

      // Adders
      score += isNodding ? DrowsinessConstants.weightHead : 0;
      score += isYawning ? DrowsinessConstants.weightMouth : 0;
    }

    // 6. Determine Status
    bool alert = score >= DrowsinessConstants.scoreThresholdAlert;
    String status = "Monitoring (Score: ${score.toInt()})";

    if (alert) {
      if (isOccluded) {
        status = "ALERT: Wake Up! (No Eyes Detected)";
      } else if (isNodding) {
        status = "ALERT: Head Dropping!";
      } else {
        status = "ALERT: Drowsiness Detected!";
      }
    } else if (score >= DrowsinessConstants.scoreThresholdWarning) {
      if (isYawning) status = "Warning: Yawning...";
      else status = "Warning: Fatigue Signs";
    } else {
      // Informative statuses for low scores
      if (isOccluded) status = "Occlusion Mode";
      else if (isYawning) status = "Yawning (Low Risk)";
      else if (eyesClosed) status = "Blink";
    }

    return {
      'alert': alert,
      'status': status,
      'score': score,
      'perclos': currentPerclos,
      'isOccluded': isOccluded,
      'smoothedMar': sMar,
      'smoothedPitch': sPitch,
      'smoothedEar': sEar,
    };
  }
}