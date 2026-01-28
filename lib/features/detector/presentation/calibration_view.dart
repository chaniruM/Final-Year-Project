import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../data/face_detector_service.dart';
import '../data/calibration_service.dart';
import '../../../core/constants/drowsiness_logic.dart';
import 'painters/face_detector_painter.dart';

class CalibrationView extends StatefulWidget {
  const CalibrationView({super.key});

  @override
  State<CalibrationView> createState() => _CalibrationViewState();
}

class _CalibrationViewState extends State<CalibrationView> {
  CameraController? _cameraController;
  final FaceDetectorService _detectorService = FaceDetectorService();
  final CalibrationService _calibrationService = CalibrationService();

  bool _isCalibrating = false;
  bool _calibrationSuccess = false;
  bool _isProcessing = false;
  int _timerCount = 10;

  List<double> _capturedEarValues = [];
  List<double> _capturedMarValues = [];

  String _message = "Position phone. Ensure face is visible.";
  double _currentPreviewEar = 0.0;
  double _currentPreviewMar = 0.0;

  CustomPaint? _customPaint;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final front = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first
    );

    _cameraController = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21,
    );

    await _cameraController!.initialize();
    if (mounted) setState(() {});
  }

  void _startCalibration() async {
    if (_cameraController == null) return;

    setState(() {
      _isCalibrating = true;
      _calibrationSuccess = false;
      _timerCount = 10;
      _capturedEarValues.clear();
      _capturedMarValues.clear();
      _message = "Keep eyes OPEN. Mouth CLOSED (Neutral).";
    });

    await _cameraController!.startImageStream(_processCameraImage);

    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_timerCount <= 0 || !mounted || !_isCalibrating) {
        timer.cancel();
        if (_isCalibrating) _finishCalibration();
      } else {
        setState(() => _timerCount--);
      }
    });
  }

  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _prepareInputImage(image);
      if (inputImage != null) {
        final faces = await _detectorService.processImage(inputImage);

        if (faces.isNotEmpty) {
          final face = faces.first;
          final ear = DrowsinessLogic.calculateEAR(face);
          final mar = DrowsinessLogic.calculateMAR(face);

          final painter = FaceDetectorPainter(
            faces,
            inputImage.metadata!.size,
            inputImage.metadata!.rotation,
            CameraLensDirection.front,
            false,
          );

          if (_isCalibrating) {
            if (ear > 0.0) _capturedEarValues.add(ear);
            if (mar > 0.0) _capturedMarValues.add(mar);
          }

          if (mounted) {
            setState(() {
              _currentPreviewEar = ear;
              _currentPreviewMar = mar;
              _customPaint = CustomPaint(painter: painter);
            });
          }
        } else {
          if (mounted) setState(() => _customPaint = null);
        }
      }
    } catch (e) {
      debugPrint("Calibration stream error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _finishCalibration() async {
    await _cameraController?.stopImageStream();
    setState(() => _customPaint = null);

    if (_capturedEarValues.isEmpty) {
      setState(() {
        _isCalibrating = false;
        _message = "Calibration Failed. No face detected.";
      });
      return;
    }

    // EAR Logic
    _capturedEarValues.sort();
    int start = (_capturedEarValues.length * 0.10).toInt();
    int end = (_capturedEarValues.length * 0.90).toInt();
    if (end <= start) { start = 0; end = _capturedEarValues.length; }

    List<double> validEar = _capturedEarValues.sublist(start, end);
    double avgOpenEar = validEar.reduce((a, b) => a + b) / validEar.length;
    double personalEarThreshold = avgOpenEar * 0.75;

    // MAR Logic
    double personalMarThreshold = 0.5;
    if (_capturedMarValues.isNotEmpty) {
      _capturedMarValues.sort();
      int mStart = (_capturedMarValues.length * 0.10).toInt();
      int mEnd = (_capturedMarValues.length * 0.90).toInt();
      if (mEnd <= mStart) { mStart = 0; mEnd = _capturedMarValues.length; }

      List<double> validMar = _capturedMarValues.sublist(mStart, mEnd);
      double avgRestingMar = validMar.reduce((a, b) => a + b) / validMar.length;

      personalMarThreshold = avgRestingMar + 0.25;

      if (personalMarThreshold < 0.3) personalMarThreshold = 0.3;
      if (personalMarThreshold > 0.6) personalMarThreshold = 0.6;
    }

    await _calibrationService.saveBaselines(personalEarThreshold, 0.05, personalMarThreshold);

    setState(() {
      _isCalibrating = false;
      _calibrationSuccess = true;
      _message = "Success!\n"
          "EAR Thresh: ${personalEarThreshold.toStringAsFixed(3)}\n"
          "MAR Thresh: ${personalMarThreshold.toStringAsFixed(3)}";
    });
  }

  // Safe Exit Method used by button AND PopScope
  Future<void> _safeExit() async {
    // 1. Stop processing
    _isProcessing = true;

    // 2. Stop stream and dispose explicitly
    if (_cameraController != null) {
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
      await _cameraController!.dispose();
    }
    _cameraController = null;

    if (!mounted) return;

    // 3. Pop ONLY if we can (to avoid duplicate pops if PopScope triggered this)
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  InputImage? _prepareInputImage(CameraImage image) {
    if (_cameraController == null) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotation.rotation270deg,
        format: Platform.isIOS ? InputImageFormat.bgra8888 : InputImageFormat.nv21,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _detectorService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isCameraReady = _cameraController != null && _cameraController!.value.isInitialized;

    // PopScope intercepts the System Back Button (Android/iOS Swipe)
    return PopScope(
      canPop: false, // Prevent default pop
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        // Perform safe cleanup, then pop manually
        await _safeExit();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text("Calibration")),
        body: Stack(
          children: [
            if (isCameraReady)
              Positioned.fill(
                child: Transform.scale(
                  scale: MediaQuery.of(context).size.aspectRatio * _cameraController!.value.aspectRatio < 1
                      ? 1 / (MediaQuery.of(context).size.aspectRatio * _cameraController!.value.aspectRatio)
                      : MediaQuery.of(context).size.aspectRatio * _cameraController!.value.aspectRatio,
                  child: Center(
                    child: CameraPreview(_cameraController!, child: _customPaint),
                  ),
                ),
              )
            else
              const Center(child: CircularProgressIndicator()),

            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_isCalibrating)
                  Container(
                    padding: const EdgeInsets.only(top: 20),
                    child: Column(
                      children: [
                        Text(
                          "EAR: ${_currentPreviewEar.toStringAsFixed(3)}",
                          style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              shadows: [Shadow(blurRadius: 2, color: Colors.black)]
                          ),
                        ),
                        Text(
                          "MAR: ${_currentPreviewMar.toStringAsFixed(3)}",
                          style: const TextStyle(
                              color: Colors.yellowAccent,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              shadows: [Shadow(blurRadius: 2, color: Colors.black)]
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const SizedBox.shrink(),

                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  width: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
                      const SizedBox(height: 10),
                      if (_isCalibrating)
                        Text("$_timerCount", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                      const SizedBox(height: 20),

                      if (!_isCalibrating && _calibrationSuccess)
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton.icon(
                            onPressed: _safeExit,
                            icon: const Icon(Icons.check_circle),
                            label: const Text("DONE - BACK TO DETECTOR"),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                          ),
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            onPressed: _isCalibrating ? null : _startCalibration,
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                            child: Text(_isCalibrating ? "Calibrating..." : "Start Calibration", style: const TextStyle(color: Colors.white)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}


// outer lip
// import 'dart:async';
// import 'dart:io';
// import 'dart:math'; // For Point
// import 'package:camera/camera.dart';
// import 'package:flutter/material.dart';
// import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
// import '../data/face_detector_service.dart';
// import '../data/calibration_service.dart';
// import '../../../core/constants/drowsiness_logic.dart';
// import 'painters/coordinates_translator.dart';
//
// class CalibrationView extends StatefulWidget {
//   const CalibrationView({super.key});
//
//   @override
//   State<CalibrationView> createState() => _CalibrationViewState();
// }
//
// class _CalibrationViewState extends State<CalibrationView> {
//   CameraController? _cameraController;
//   final FaceDetectorService _detectorService = FaceDetectorService();
//   final CalibrationService _calibrationService = CalibrationService();
//
//   bool _isCalibrating = false;
//   bool _isProcessing = false;
//   int _timerCount = 10;
//
//   List<double> _capturedEarValues = [];
//   List<double> _capturedMarValues = [];
//
//   String _message = "Position phone. Ensure face is visible.";
//   double _currentPreviewEar = 0.0;
//   double _currentPreviewMar = 0.0;
//
//   CustomPaint? _customPaint;
//
//   @override
//   void initState() {
//     super.initState();
//     _initCamera();
//   }
//
//   Future<void> _initCamera() async {
//     final cameras = await availableCameras();
//     if (cameras.isEmpty) return;
//
//     final front = cameras.firstWhere(
//             (c) => c.lensDirection == CameraLensDirection.front,
//         orElse: () => cameras.first
//     );
//
//     _cameraController = CameraController(
//       front,
//       ResolutionPreset.medium,
//       enableAudio: false,
//       imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21,
//     );
//
//     await _cameraController!.initialize();
//     if (mounted) setState(() {});
//   }
//
//   void _startCalibration() async {
//     if (_cameraController == null) return;
//
//     setState(() {
//       _isCalibrating = true;
//       _timerCount = 10;
//       _capturedEarValues.clear();
//       _capturedMarValues.clear();
//       _message = "Keep eyes OPEN. Mouth CLOSED (Neutral).";
//     });
//
//     await _cameraController!.startImageStream(_processCameraImage);
//
//     Timer.periodic(const Duration(seconds: 1), (timer) async {
//       if (_timerCount <= 0 || !mounted || !_isCalibrating) {
//         timer.cancel();
//         if (_isCalibrating) _finishCalibration();
//       } else {
//         setState(() => _timerCount--);
//       }
//     });
//   }
//
//   void _processCameraImage(CameraImage image) async {
//     if (_isProcessing) return;
//     _isProcessing = true;
//
//     try {
//       final inputImage = _prepareInputImage(image);
//       if (inputImage != null) {
//         final faces = await _detectorService.processImage(inputImage);
//
//         if (faces.isNotEmpty) {
//           final face = faces.first;
//           final ear = DrowsinessLogic.calculateEAR(face);
//           final mar = DrowsinessLogic.calculateMAR(face);
//
//           final painter = CalibrationPainter(
//             face: face,
//             imageSize: inputImage.metadata!.size,
//             rotation: inputImage.metadata!.rotation,
//             cameraLensDirection: CameraLensDirection.front,
//           );
//
//           if (_isCalibrating) {
//             if (ear > 0.0) _capturedEarValues.add(ear);
//             if (mar > 0.0) _capturedMarValues.add(mar);
//           }
//
//           if (mounted) {
//             setState(() {
//               _currentPreviewEar = ear;
//               _currentPreviewMar = mar;
//               _customPaint = CustomPaint(painter: painter);
//             });
//           }
//         } else {
//           if (mounted) setState(() => _customPaint = null);
//         }
//       }
//     } catch (e) {
//       debugPrint("Calibration stream error: $e");
//     } finally {
//       _isProcessing = false;
//     }
//   }
//
//   Future<void> _finishCalibration() async {
//     await _cameraController?.stopImageStream();
//     setState(() => _customPaint = null);
//
//     if (_capturedEarValues.isEmpty) {
//       setState(() {
//         _isCalibrating = false;
//         _message = "Calibration Failed. No face detected.";
//       });
//       return;
//     }
//
//     // EAR Calculation
//     _capturedEarValues.sort();
//     int start = (_capturedEarValues.length * 0.10).toInt();
//     int end = (_capturedEarValues.length * 0.90).toInt();
//     if (end <= start) { start = 0; end = _capturedEarValues.length; }
//
//     List<double> validEar = _capturedEarValues.sublist(start, end);
//     double avgOpenEar = validEar.reduce((a, b) => a + b) / validEar.length;
//     double personalEarThreshold = avgOpenEar * 0.75;
//
//     // MAR Calculation
//     double personalMarThreshold = DrowsinessLogic.yawnMarThreshold;
//     if (_capturedMarValues.isNotEmpty) {
//       _capturedMarValues.sort();
//       int mStart = (_capturedMarValues.length * 0.10).toInt();
//       int mEnd = (_capturedMarValues.length * 0.90).toInt();
//       if (mEnd <= mStart) { mStart = 0; mEnd = _capturedMarValues.length; }
//
//       List<double> validMar = _capturedMarValues.sublist(mStart, mEnd);
//       double avgRestingMar = validMar.reduce((a, b) => a + b) / validMar.length;
//
//       personalMarThreshold = avgRestingMar + 0.35;
//       if (personalMarThreshold < 0.4) personalMarThreshold = 0.4;
//       if (personalMarThreshold > 0.6) personalMarThreshold = 0.6;
//     }
//
//     await _calibrationService.saveBaselines(personalEarThreshold, 0.05, personalMarThreshold);
//
//     setState(() {
//       _isCalibrating = false;
//       _message = "Success!\n"
//           "EAR Thresh: ${personalEarThreshold.toStringAsFixed(3)}\n"
//           "MAR Thresh: ${personalMarThreshold.toStringAsFixed(3)}";
//     });
//   }
//
//   InputImage? _prepareInputImage(CameraImage image) {
//     if (_cameraController == null) return null;
//     final plane = image.planes.first;
//
//     return InputImage.fromBytes(
//       bytes: plane.bytes,
//       metadata: InputImageMetadata(
//         size: Size(image.width.toDouble(), image.height.toDouble()),
//         rotation: InputImageRotation.rotation270deg,
//         format: Platform.isIOS ? InputImageFormat.bgra8888 : InputImageFormat.nv21,
//         bytesPerRow: plane.bytesPerRow,
//       ),
//     );
//   }
//
//   @override
//   void dispose() {
//     _cameraController?.stopImageStream();
//     _cameraController?.dispose();
//     _detectorService.dispose();
//     super.dispose();
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     if (_cameraController == null || !_cameraController!.value.isInitialized) {
//       return const Scaffold(body: Center(child: CircularProgressIndicator()));
//     }
//
//     // --- 1. CALCULATE SCALE TO COVER SCREEN ---
//     // This matches the logic in DetectorView exactly
//     final size = MediaQuery.of(context).size;
//     var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
//     if (scale < 1) scale = 1 / scale;
//
//     return Scaffold(
//       appBar: AppBar(title: const Text("Calibration")),
//       body: Stack(
//         children: [
//           // --- 2. CAMERA LAYER (SCALED) ---
//           Positioned.fill(
//             child: Transform.scale(
//               scale: scale,
//               child: Center(
//                 child: CameraPreview(
//                   _cameraController!,
//                   child: _customPaint, // Painter is now correctly scaled inside preview
//                 ),
//               ),
//             ),
//           ),
//
//           // --- 3. UI OVERLAY LAYER ---
//           // Controls sit on top of the camera feed
//           Column(
//             mainAxisAlignment: MainAxisAlignment.spaceBetween,
//             children: [
//               // Top Info
//               if (_isCalibrating)
//                 Container(
//                   padding: const EdgeInsets.only(top: 20),
//                   child: Column(
//                     children: [
//                       Text(
//                         "EAR: ${_currentPreviewEar.toStringAsFixed(3)}",
//                         style: const TextStyle(
//                             color: Colors.greenAccent,
//                             fontSize: 20,
//                             fontWeight: FontWeight.bold,
//                             shadows: [Shadow(blurRadius: 2, color: Colors.black)]
//                         ),
//                       ),
//                       Text(
//                         "MAR: ${_currentPreviewMar.toStringAsFixed(3)}",
//                         style: const TextStyle(
//                             color: Colors.yellowAccent,
//                             fontSize: 20,
//                             fontWeight: FontWeight.bold,
//                             shadows: [Shadow(blurRadius: 2, color: Colors.black)]
//                         ),
//                       ),
//                     ],
//                   ),
//                 )
//               else
//                 const SizedBox.shrink(),
//
//               // Bottom Control Panel
//               Container(
//                 padding: const EdgeInsets.all(24),
//                 decoration: const BoxDecoration(
//                   color: Colors.black87,
//                   borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
//                 ),
//                 width: double.infinity,
//                 child: Column(
//                   mainAxisSize: MainAxisSize.min,
//                   children: [
//                     Text(_message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
//                     const SizedBox(height: 10),
//                     if (_isCalibrating)
//                       Text("$_timerCount", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
//                     const SizedBox(height: 20),
//                     SizedBox(
//                       width: double.infinity,
//                       height: 50,
//                       child: ElevatedButton(
//                         onPressed: _isCalibrating ? null : _startCalibration,
//                         style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
//                         child: Text(_isCalibrating ? "Calibrating..." : "Start Calibration", style: const TextStyle(color: Colors.white)),
//                       ),
//                     ),
//                   ],
//                 ),
//               ),
//             ],
//           ),
//         ],
//       ),
//     );
//   }
// }
//
// class CalibrationPainter extends CustomPainter {
//   final Face face;
//   final Size imageSize;
//   final InputImageRotation rotation;
//   final CameraLensDirection cameraLensDirection;
//
//   CalibrationPainter({
//     required this.face,
//     required this.imageSize,
//     required this.rotation,
//     required this.cameraLensDirection,
//   });
//
//   @override
//   void paint(Canvas canvas, Size size) {
//     final Paint eyePaint = Paint()
//       ..style = PaintingStyle.fill
//       ..color = Colors.greenAccent;
//
//     // Helper for mirroring X
//     double transformX(double x) {
//       double tx = translateX(x, size, imageSize, rotation, cameraLensDirection);
//       if (cameraLensDirection == CameraLensDirection.front) {
//         return size.width - tx;
//       }
//       return tx;
//     }
//
//     // --- 1. Draw Eye Points ---
//     void paintContour(FaceContourType type) {
//       final contour = face.contours[type];
//       if (contour?.points != null) {
//         for (final point in contour!.points) {
//           canvas.drawCircle(
//             Offset(
//               transformX(point.x.toDouble()),
//               translateY(point.y.toDouble(), size, imageSize, rotation, cameraLensDirection),
//             ),
//             2,
//             eyePaint,
//           );
//         }
//       }
//     }
//     paintContour(FaceContourType.leftEye);
//     paintContour(FaceContourType.rightEye);
//
//     // --- 2. Draw MAR Points ---
//     final upper = face.contours[FaceContourType.upperLipTop]?.points;
//     final lower = face.contours[FaceContourType.lowerLipBottom]?.points;
//
//     final Paint mouthHeightPaint = Paint()..color = Colors.yellow..style = PaintingStyle.fill;
//     final Paint mouthWidthPaint = Paint()..color = Colors.cyanAccent..style = PaintingStyle.fill;
//
//     if (upper != null && lower != null && upper.isNotEmpty && lower.isNotEmpty) {
//       int centerU = upper.length ~/ 2;
//       int centerL = lower.length ~/ 2;
//
//       List<Point<int>> heightPoints = [];
//
//       if (centerU >= 1 && centerU < upper.length - 1) {
//         heightPoints.addAll([upper[centerU - 1], upper[centerU], upper[centerU + 1]]);
//       }
//       if (centerL >= 1 && centerL < lower.length - 1) {
//         heightPoints.addAll([lower[centerL - 1], lower[centerL], lower[centerL + 1]]);
//       }
//
//       for (var point in heightPoints) {
//         canvas.drawCircle(
//           Offset(
//             transformX(point.x.toDouble()),
//             translateY(point.y.toDouble(), size, imageSize, rotation, cameraLensDirection),
//           ),
//           2.5,
//           mouthHeightPaint,
//         );
//       }
//
//       final p1 = lower.first;
//       final p2 = lower.last;
//       canvas.drawCircle(
//           Offset(transformX(p1.x.toDouble()), translateY(p1.y.toDouble(), size, imageSize, rotation, cameraLensDirection)),
//           4.0, mouthWidthPaint
//       );
//       canvas.drawCircle(
//           Offset(transformX(p2.x.toDouble()), translateY(p2.y.toDouble(), size, imageSize, rotation, cameraLensDirection)),
//           4.0, mouthWidthPaint
//       );
//     }
//   }
//
//   @override
//   bool shouldRepaint(CalibrationPainter oldDelegate) {
//     return oldDelegate.face != face || oldDelegate.imageSize != imageSize;
//   }
// }
