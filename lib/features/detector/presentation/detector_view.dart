import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import '../../../core/constants/drowsiness_logic.dart';
import '../data/face_detector_service.dart';
import '../data/calibration_service.dart';
import 'calibration_view.dart';
import 'profile_view.dart';
import 'painters/face_detector_painter.dart';

class DetectorView extends StatefulWidget {
  const DetectorView({super.key});

  @override
  State<DetectorView> createState() => _DetectorViewState();
}

class _DetectorViewState extends State<DetectorView> with WidgetsBindingObserver {
  CameraController? _cameraController;
  final FaceDetectorService _faceDetectorService = FaceDetectorService();
  final CalibrationService _calibrationService = CalibrationService();

  final FusionEngine _fusionEngine = FusionEngine();
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _isProcessing = false;
  bool _isMonitoring = false;

  String _drowsinessStatus = "Ready to Start";
  bool _isAlerting = false;
  bool _isOccluded = false;
  double _currentPerclos = 0.0;

  double _debugPitch = 0.0;
  double _debugMar = 0.0;
  double _debugEar = 0.0;

  CustomPaint? _customPaint;

  double _baselineEarThreshold = 0.20;
  double _marThreshold = DrowsinessLogic.yawnMarThreshold;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _initializeCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _loadSettings() async {
    final baselines = await _calibrationService.getBaselines();

    if (baselines['threshold'] != null && baselines['threshold']! > 0) {
      _baselineEarThreshold = baselines['threshold']!;
    }

    if (baselines['perclos'] != null) {
      _fusionEngine.updateBaseline(baselines['perclos']!);
    }

    if (baselines['mar'] != null && baselines['mar']! > 0) {
      _marThreshold = baselines['mar']!;
    }

    if (mounted) setState(() {});
  }

  Future<void> _initializeCamera() async {
    if (_cameraController != null) return;

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) setState(() => _drowsinessStatus = "No Camera");
      return;
    }

    final frontCamera = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21,
    );

    try {
      await controller.initialize();
      if (!mounted) return;

      // Start streaming
      await controller.startImageStream(_processCameraImage);

      setState(() => _cameraController = controller);
    } catch (e) {
      debugPrint("Camera Init Error: $e");
      // Optional: Retry logic if camera is busy
    }
  }

  /// FIXED: Sets controller to null BEFORE disposing to prevent UI crash
  Future<void> _stopCamera() async {
    final controller = _cameraController;

    // 1. Remove from UI immediately so build() doesn't use a dying controller
    if (mounted) {
      setState(() {
        _cameraController = null;
        _customPaint = null;
      });
    }

    // 2. Dispose safely in background
    if (controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (e) {
        debugPrint("Error stopping stream: $e");
      }
      await controller.dispose();
    }
  }

  void _startMonitoring() {
    _fusionEngine.reset();
    setState(() {
      _isMonitoring = true;
      _drowsinessStatus = "Monitoring...";
    });
  }

  void _stopMonitoring() {
    _stopAlert();
    setState(() {
      _isMonitoring = false;
      _drowsinessStatus = "Session Paused";
      _isAlerting = false;
      _currentPerclos = 0.0;
    });
  }

  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      // Guard: If controller is gone, stop processing
      if (_cameraController == null) return;

      final inputImage = _prepareInputImage(image);
      if (inputImage == null) return;

      final faces = await _faceDetectorService.processImage(inputImage);

      if (faces.isNotEmpty) {
        final face = faces.first;

        final double currentEar = DrowsinessLogic.calculateEAR(face);
        final double mar = DrowsinessLogic.calculateMAR(face);
        final double pitch = face.headEulerAngleX ?? 0.0;

        if (_isMonitoring) {
          final result = _fusionEngine.processFrame(
            currentEar: currentEar,
            headPitch: pitch,
            mar: mar,
            earThreshold: _baselineEarThreshold,
            marThreshold: _marThreshold,
          );

          final bool shouldAlert = result['alert'] as bool;

          if (mounted) {
            setState(() {
              _drowsinessStatus = result['status'] as String;
              _isAlerting = shouldAlert;
              _currentPerclos = result['perclos'] ?? 0.0;
              _isOccluded = result['isOccluded'] ?? false;

              _debugMar = result['smoothedMar'] ?? 0.0;
              _debugPitch = result['smoothedPitch'] ?? 0.0;
              _debugEar = result['smoothedEar'] ?? 0.0;
            });

            if (shouldAlert) {
              _triggerAlert();
            } else {
              _stopAlert();
            }
          }
        } else {
          if (mounted) {
            setState(() {
              _debugMar = mar;
              _debugPitch = pitch;
              _debugEar = currentEar;
            });
          }
        }

        final painter = FaceDetectorPainter(
          faces,
          inputImage.metadata!.size,
          inputImage.metadata!.rotation,
          CameraLensDirection.front,
          _isAlerting,
        );

        if (mounted) {
          setState(() => _customPaint = CustomPaint(painter: painter));
        }
      } else {
        if (mounted) setState(() => _customPaint = null);
      }
    } catch (e) {
      debugPrint("Processing error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _triggerAlert() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [500, 1000, 500, 1000], intensities: [1, 255]);
    }
  }

  Future<void> _stopAlert() async {
    if (_audioPlayer.state == PlayerState.playing) {
      await _audioPlayer.stop();
    }
    Vibration.cancel();
  }

  void _dismissAndReset() {
    _stopAlert();
    _fusionEngine.reset();
    setState(() {
      _isAlerting = false;
      _drowsinessStatus = "Monitoring Resumed";
    });
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
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    _faceDetectorService.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _safeNavigate(Widget destination) async {
    _stopMonitoring();

    // Stop camera and wait
    await _stopCamera();

    if (!mounted) return;

    // Navigate
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => destination),
    );

    // Give a tiny delay for the previous screen to fully release hardware
    await Future.delayed(const Duration(milliseconds: 200));

    // Re-initialize when back
    await _loadSettings();
    await _initializeCamera();
  }

  @override
  Widget build(BuildContext context) {
    // Robust check prevents "buildPreview called on disposed controller"
    final bool isCameraReady = _cameraController != null && _cameraController!.value.isInitialized;

    if (!isCameraReady) {
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator())
      );
    }

    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Driver Guardian"),
        elevation: 0,
        backgroundColor: _isAlerting ? Colors.red : Colors.blueAccent,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: "Driver Profile",
            onPressed: () => _safeNavigate(const ProfileView()),
          ),
          IconButton(
            icon: const Icon(Icons.settings_accessibility),
            onPressed: () => _safeNavigate(const CalibrationView()),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Transform.scale(
            scale: scale,
            child: Center(
              child: CameraPreview(_cameraController!, child: _customPaint),
            ),
          ),

          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              decoration: BoxDecoration(
                color: _isAlerting ? Colors.red.withOpacity(0.9) : Colors.black87,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _drowsinessStatus.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildMetric("EAR", _debugEar.toStringAsFixed(2)),
                      _buildMetric("EAR THRESH", _baselineEarThreshold.toStringAsFixed(2)),
                      _buildMetric("MAR", _debugMar.toStringAsFixed(2)),
                    ],
                  ),

                  const SizedBox(height: 20),

                  if (_isAlerting)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _dismissAndReset,
                        icon: const Icon(Icons.notifications_off),
                        label: const Text("DISMISS & RESET"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    )
                  else if (!_isMonitoring)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _startMonitoring,
                        icon: const Icon(Icons.play_circle_filled),
                        label: const Text("START MONITORING"),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _stopMonitoring,
                        icon: const Icon(Icons.stop_circle),
                        label: const Text("STOP MONITORING"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey[800],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetric(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontFamily: "Monospace")),
      ],
    );
  }
}

// outer lip
// import 'dart:async';
// import 'dart:io';
// import 'package:camera/camera.dart';
// import 'package:flutter/foundation.dart';
// import 'package:flutter/material.dart';
// import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
// import 'package:audioplayers/audioplayers.dart';
// import 'package:vibration/vibration.dart';
// import '../../../core/constants/drowsiness_logic.dart';
// import '../data/face_detector_service.dart';
// import '../data/calibration_service.dart';
// import 'calibration_view.dart';
// import 'profile_view.dart';
// import 'painters/face_detector_painter.dart';
//
// class DetectorView extends StatefulWidget {
//   const DetectorView({super.key});
//
//   @override
//   State<DetectorView> createState() => _DetectorViewState();
// }
//
// class _DetectorViewState extends State<DetectorView> with WidgetsBindingObserver {
//   CameraController? _cameraController;
//   final FaceDetectorService _faceDetectorService = FaceDetectorService();
//   final CalibrationService _calibrationService = CalibrationService();
//
//   final FusionEngine _fusionEngine = FusionEngine();
//   final AudioPlayer _audioPlayer = AudioPlayer();
//
//   bool _isProcessing = false;
//   String _drowsinessStatus = "Detecting...";
//   bool _isAlerting = false;
//   bool _isOccluded = false;
//   double _currentPerclos = 0.0;
//
//   // Debug values
//   double _debugPitch = 0.0;
//   double _debugMar = 0.0;
//   double _debugEar = 0.0;
//
//   CustomPaint? _customPaint;
//
//   // Default Thresholds
//   double _baselineEarThreshold = 0.20;
//   double _marThreshold = DrowsinessLogic.yawnMarThreshold;
//
//   @override
//   void initState() {
//     super.initState();
//     WidgetsBinding.instance.addObserver(this);
//     _loadSettings();
//     _initializeCamera();
//   }
//
//   // Handle app lifecycle changes (e.g., minimizing app)
//   @override
//   void didChangeAppLifecycleState(AppLifecycleState state) {
//     if (_cameraController == null || !_cameraController!.value.isInitialized) {
//       return;
//     }
//
//     if (state == AppLifecycleState.inactive) {
//       _stopCamera();
//     } else if (state == AppLifecycleState.resumed) {
//       _initializeCamera();
//     }
//   }
//
//   Future<void> _loadSettings() async {
//     final baselines = await _calibrationService.getBaselines();
//
//     // EAR
//     if (baselines['threshold'] != null && baselines['threshold']! > 0) {
//       _baselineEarThreshold = baselines['threshold']!;
//     }
//
//     // PERCLOS
//     if (baselines['perclos'] != null) {
//       _fusionEngine.updateBaseline(baselines['perclos']!);
//     }
//
//     // MAR
//     if (baselines['mar'] != null && baselines['mar']! > 0) {
//       _marThreshold = baselines['mar']!;
//       debugPrint("Loaded Calibrated MAR: $_marThreshold");
//     }
//
//     if (mounted) setState(() {});
//   }
//
//   Future<void> _initializeCamera() async {
//     // Prevent duplicate initialization
//     if (_cameraController != null) return;
//
//     final cameras = await availableCameras();
//     if (cameras.isEmpty) {
//       if (mounted) setState(() => _drowsinessStatus = "No Camera");
//       return;
//     }
//
//     final frontCamera = cameras.firstWhere(
//           (c) => c.lensDirection == CameraLensDirection.front,
//       orElse: () => cameras.first,
//     );
//
//     final controller = CameraController(
//       frontCamera,
//       ResolutionPreset.medium,
//       enableAudio: false,
//       imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21,
//     );
//
//     try {
//       await controller.initialize();
//       if (!mounted) return;
//
//       // Start streaming immediately
//       await controller.startImageStream(_processCameraImage);
//
//       setState(() {
//         _cameraController = controller;
//       });
//     } catch (e) {
//       debugPrint("Camera Init Error: $e");
//     }
//   }
//
//   /// Explicitly stops and releases the camera
//   Future<void> _stopCamera() async {
//     if (_cameraController != null) {
//       // Stop stream to prevent "CameraException: Camera is closed" errors
//       await _cameraController!.stopImageStream();
//       await _cameraController!.dispose();
//       setState(() {
//         _cameraController = null;
//         _customPaint = null; // Clear overlay
//       });
//     }
//   }
//
//   void _processCameraImage(CameraImage image) async {
//     if (_isProcessing) return;
//     _isProcessing = true;
//
//     try {
//       // Guard against processing if camera was disposed mid-frame
//       if (_cameraController == null) return;
//
//       final inputImage = _prepareInputImage(image);
//       if (inputImage == null) return;
//
//       final faces = await _faceDetectorService.processImage(inputImage);
//
//       if (faces.isNotEmpty) {
//         final face = faces.first;
//
//         // 1. Calculate Metrics
//         final double currentEar = DrowsinessLogic.calculateEAR(face);
//         final double mar = DrowsinessLogic.calculateMAR(face);
//         final double pitch = face.headEulerAngleX ?? 0.0;
//
//         // 2. Process Fusion
//         final result = _fusionEngine.processFrame(
//           currentEar: currentEar,
//           headPitch: pitch,
//           mar: mar,
//           earThreshold: _baselineEarThreshold,
//           marThreshold: _marThreshold,
//         );
//
//         final bool shouldAlert = result['alert'] as bool;
//
//         // Visuals
//         final painter = FaceDetectorPainter(
//           faces,
//           inputImage.metadata!.size,
//           inputImage.metadata!.rotation,
//           CameraLensDirection.front,
//           shouldAlert,
//         );
//
//         if (mounted) {
//           setState(() {
//             _customPaint = CustomPaint(painter: painter);
//             _drowsinessStatus = result['status'] as String;
//             _isAlerting = shouldAlert;
//             _currentPerclos = result['perclos'] ?? 0.0;
//             _isOccluded = result['isOccluded'] ?? false;
//
//             _debugMar = result['smoothedMar'] ?? 0.0;
//             _debugPitch = result['smoothedPitch'] ?? 0.0;
//             _debugEar = result['smoothedEar'] ?? 0.0;
//           });
//
//           if (shouldAlert) {
//             _triggerAlert();
//           } else {
//             _stopAlert();
//           }
//         }
//       } else {
//         if (mounted) setState(() => _customPaint = null);
//       }
//     } catch (e) {
//       debugPrint("Processing error: $e");
//     } finally {
//       _isProcessing = false;
//     }
//   }
//
//   Future<void> _triggerAlert() async {
//     if (await Vibration.hasVibrator() ?? false) {
//       Vibration.vibrate(pattern: [500, 1000, 500, 1000], intensities: [1, 255]);
//     }
//   }
//
//   Future<void> _stopAlert() async {
//     if (_audioPlayer.state == PlayerState.playing) {
//       await _audioPlayer.stop();
//     }
//     Vibration.cancel();
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
//     WidgetsBinding.instance.removeObserver(this);
//     _stopCamera(); // Ensure clean disposal
//     _faceDetectorService.dispose();
//     _audioPlayer.dispose();
//     super.dispose();
//   }
//
//   // --- SAFE NAVIGATION HELPER ---
//   Future<void> _safeNavigate(Widget destination) async {
//     // 1. Release the camera resource
//     await _stopCamera();
//
//     if (!mounted) return;
//
//     // 2. Navigate away
//     await Navigator.push(
//       context,
//       MaterialPageRoute(builder: (context) => destination),
//     );
//
//     // 3. Re-acquire resource when we come back
//     await _loadSettings();
//     await _initializeCamera();
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     // If controller is null (stopped) or not initialized, show loading
//     if (_cameraController == null || !_cameraController!.value.isInitialized) {
//       return const Scaffold(
//         backgroundColor: Colors.black,
//         body: Center(child: CircularProgressIndicator()),
//       );
//     }
//
//     final size = MediaQuery.of(context).size;
//     var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
//     if (scale < 1) scale = 1 / scale;
//
//     return Scaffold(
//       appBar: AppBar(
//         title: const Text("Driver Guardian"),
//         elevation: 0,
//         backgroundColor: _isAlerting ? Colors.red : Colors.blueAccent,
//         actions: [
//           IconButton(
//             icon: const Icon(Icons.person),
//             tooltip: "Driver Profile",
//             onPressed: () => _safeNavigate(const ProfileView()),
//           ),
//           IconButton(
//             icon: const Icon(Icons.settings_accessibility),
//             onPressed: () => _safeNavigate(const CalibrationView()),
//           ),
//         ],
//       ),
//       body: Stack(
//         fit: StackFit.expand,
//         children: [
//           Transform.scale(
//             scale: scale,
//             child: Center(
//               child: CameraPreview(_cameraController!, child: _customPaint),
//             ),
//           ),
//
//           Positioned(
//             bottom: 30,
//             left: 20,
//             right: 20,
//             child: Container(
//               padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
//               decoration: BoxDecoration(
//                 color: _isAlerting ? Colors.red.withOpacity(0.9) : Colors.black87,
//                 borderRadius: BorderRadius.circular(16),
//               ),
//               child: Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   Text(
//                     _drowsinessStatus.toUpperCase(),
//                     textAlign: TextAlign.center,
//                     style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
//                   ),
//                   const SizedBox(height: 12),
//                   Row(
//                     mainAxisAlignment: MainAxisAlignment.spaceAround,
//                     children: [
//                       _buildMetric("EAR", _debugEar.toStringAsFixed(2)),
//                       _buildMetric("EAR THRESH", _baselineEarThreshold.toStringAsFixed(2)),
//                       _buildMetric("MAR", _debugMar.toStringAsFixed(2)),
//                     ],
//                   ),
//                 ],
//               ),
//             ),
//           ),
//         ],
//       ),
//     );
//   }
//
//   Widget _buildMetric(String label, String value) {
//     return Column(
//       children: [
//         Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
//         const SizedBox(height: 4),
//         Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontFamily: "Monospace")),
//       ],
//     );
//   }
// }
