import 'dart:collection';
import '../../../core/constants/drowsiness_constants.dart';
import '../../../core/utils/signal_smoother.dart';

class FrameData {
  final DateTime timestamp;
  final bool isEyeClosed;
  FrameData(this.timestamp, this.isEyeClosed);
}

class FusionEngine {
  final Queue<FrameData> _timeBuffer = Queue<FrameData>();

  final SignalSmoother _earSmoother = SignalSmoother(windowSize: 3);
  final SignalSmoother _pitchSmoother = SignalSmoother(windowSize: 8);
  final SignalSmoother _marSmoother = SignalSmoother(windowSize: 5);

  double _baselinePerclos = 0.0;
  DateTime? _lastEyesDetectedTime;
  
  DateTime? _blinkStartTime; // Tracks continuous closure for microsleeps
  DateTime? _droopStartTime; // Tracks continuous head droop
  DateTime? _yawnStartTime; // Tracks continuous yawn
  final List<DateTime> _verifiedYawns = []; // Keeps a history of yawns

  FusionEngine({double baselinePerclos = 0.0}) {
    _baselinePerclos = baselinePerclos;
    _lastEyesDetectedTime = DateTime.now();
  }

  void updateBaseline(double baseline) {
    _baselinePerclos = baseline;
  }

  void reset() {
    _timeBuffer.clear();
    _earSmoother.reset();
    _pitchSmoother.reset();
    _marSmoother.reset();
    _lastEyesDetectedTime = DateTime.now();
    _blinkStartTime = null;
    _droopStartTime = null;
    _yawnStartTime = null;
    _verifiedYawns.clear();
  }

  Map<String, dynamic> processFrame({
    required double currentEar,
    required double headPitch,
    required double mar,
    required double earThreshold,
    required double marThreshold,
    required double baselinePitch, 
  }) {
    final now = DateTime.now();

    // 1. Smooth Inputs (Ignore -1.0 occlusions so we don't break the smoothing buffer)
    double sEar = currentEar >= 0.0 ? _earSmoother.smooth(currentEar) : -1.0;
    double sPitch = _pitchSmoother.smooth(headPitch);
    double sMar = mar >= 0.0 ? _marSmoother.smooth(mar) : -1.0;

    double relativePitch = sPitch - baselinePitch;

    bool isYawningInstant = sMar >= 0.0 && sMar > marThreshold;
    bool isNoddingInstant = relativePitch < DrowsinessConstants.headNodPitchThreshold;

    // 2. Occlusion Detection (Focus strictly on Eyes/Sunglasses)
    // IMPORTANT: Check >= 0.0. If eyes are closed but visible, we still update the heartbeat.
    if (currentEar >= 0.0) {
      _lastEyesDetectedTime = now;
    }
    
    final bool isOccluded = now.difference(_lastEyesDetectedTime ?? now).inSeconds > 2;

    // 3. Update History & PERCLOS
    bool eyesClosed = DrowsinessConstants.isDrowsy(sEar, earThreshold);
    bool isMicrosleep = false;

    if (!isOccluded) {
      _timeBuffer.add(FrameData(now, eyesClosed));

      _timeBuffer.removeWhere((frame) => 
          now.difference(frame.timestamp) > DrowsinessConstants.perclosWindowDuration);

      // Microsleep Detection
      if (eyesClosed && !isYawningInstant) {
        _blinkStartTime ??= now;
        if (now.difference(_blinkStartTime!).inMilliseconds > DrowsinessConstants.microsleepDurationMs) {
          isMicrosleep = true;
        }
      } else {
        _blinkStartTime = null;
      }
    } else {
      _blinkStartTime = null; // Reset if eyes occluded
    }

    // --- 30-SECOND WARMUP LOGIC ---
    int closedFrames = _timeBuffer.where((c) => c.isEyeClosed).length;
    double currentPerclos = 0.0;

    if (_timeBuffer.isNotEmpty) {
      final bufferDuration = now.difference(_timeBuffer.first.timestamp);
      if (bufferDuration.inSeconds < 30) {
        int denominator = _timeBuffer.length < 450 ? 450 : _timeBuffer.length;
        currentPerclos = closedFrames / denominator;
      } else {
        currentPerclos = closedFrames / _timeBuffer.length;
      }
    }

    // 4. Calculate Scores
    double score = 0.0;

    double effectivePerclosThreshold = _baselinePerclos + DrowsinessConstants.perclosTolerance;
    if (effectivePerclosThreshold == 0) effectivePerclosThreshold = 0.01;

    double perclosRatio = currentPerclos / effectivePerclosThreshold;
    if (perclosRatio > 2.5) perclosRatio = 2.5;

    bool isContinuousDroop = false;
    if (isNoddingInstant) {
      _droopStartTime ??= now;
      if (now.difference(_droopStartTime!).inMilliseconds > DrowsinessConstants.headDroopDurationMs) {
        isContinuousDroop = true;
      }
    } else {
      _droopStartTime = null;
    }

    bool isContinuousYawn = false;
    if (isYawningInstant) {
      _yawnStartTime ??= now;
      if (now.difference(_yawnStartTime!).inMilliseconds > DrowsinessConstants.yawnDurationMs) {
        isContinuousYawn = true;
      }
    } else {
      if (_yawnStartTime != null && now.difference(_yawnStartTime!).inMilliseconds > DrowsinessConstants.yawnDurationMs) {
        _verifiedYawns.add(now);
      }
      _yawnStartTime = null;
    }

    _verifiedYawns.removeWhere((timestamp) => 
        now.difference(timestamp) > DrowsinessConstants.yawnHistoryWindow);

    double penaltyScore = 0.0;
    if (_verifiedYawns.length >= DrowsinessConstants.frequentYawnCount) {
      penaltyScore += DrowsinessConstants.frequentYawnPenalty;
    }

    // 5. DYNAMIC FUSION SCORING (Sunglasses Mode)
    if (isOccluded) {
      // OCCLUSION MODE: Eyes Blocked by Sunglasses.
      // Ignore PERCLOS and Mouth. Rely entirely on Head posture.
      score += isNoddingInstant ? DrowsinessConstants.weightHeadOccluded : 0;
    } else {
      // NORMAL MODE: Full 3-channel fusion.
      score += perclosRatio * DrowsinessConstants.weightEyes;
      score += isNoddingInstant ? DrowsinessConstants.weightHead : 0;
      score += isContinuousYawn ? DrowsinessConstants.weightMouth : 0;
    }
    
    score += penaltyScore; 

    // 6. Determine Status & Alert Level
    int alertLevel = 0; 
    String status = "Monitoring (Score: ${score.toInt()})";

    if (isMicrosleep || isContinuousDroop || score >= DrowsinessConstants.scoreThresholdAlert) {
      alertLevel = 2; // Critical Alert
      if (isMicrosleep) {
        status = "ALERT: MICROSLEEP DETECTED!";
      } else if (isContinuousDroop) {
        status = "ALERT: HEAD DROPPED!";
      } else if (isOccluded) {
        status = "ALERT: Wake Up! (Eyes Blocked)";
      } else if (_verifiedYawns.length >= DrowsinessConstants.frequentYawnCount) {
        status = "ALERT: EXTREME FATIGUE (Frequent Yawns)";
      } else {
        status = "ALERT: Drowsiness Detected!";
      }
    } else if (isContinuousYawn || score >= DrowsinessConstants.scoreThresholdWarning) {
      alertLevel = 1; // Warning Alert
      if (isContinuousYawn) {
        status = "Warning: Yawning Detected";
      } else if (_verifiedYawns.isNotEmpty) {
        status = "Warning: Fatigue Buildup";
      } else {
        status = "Warning: Fatigue Signs";
      }
    } else {
      if (sEar == -1.0) {
        status = "EYES NOT DETECTED";
      } else if (sMar == -1.0) {
        status = "MOUTH NOT DETECTED";
      } else if (isYawningInstant) {
        status = "Yawning (Low Risk)";
      } else if (eyesClosed) {
        status = "Blink";
      }
    }

    return {
      'alertLevel': alertLevel,
      'status': status,
      'score': score,
      'perclos': currentPerclos,
      'isOccluded': isOccluded,
      'smoothedMar': sMar,
      'smoothedPitch': relativePitch, 
      'smoothedEar': sEar,
    };
  }
}