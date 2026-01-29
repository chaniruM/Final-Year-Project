import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
// ARKit Import
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
// Device Info Import
import 'package:device_info_plus/device_info_plus.dart';

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
  // --- CAMERA (Android/Standard) ---
  CameraController? _cameraController;

  // --- ARKIT (iOS) ---
  ARKitController? _arkitController;
  ARKitNode? _faceNode;
  ARKitFace? _faceGeometry;
  Key _arKitKey = UniqueKey();

  // --- SERVICES ---
  final FaceDetectorService _faceDetectorService = FaceDetectorService();
  final CalibrationService _calibrationService = CalibrationService();
  final FusionEngine _fusionEngine = FusionEngine();
  final AudioPlayer _audioPlayer = AudioPlayer();

  // --- STATE ---
  bool _isProcessing = false;
  bool _isMonitoring = false;

  int _frameCounter = 0;
  static const int _processEveryNthFrame = 3;

  final ValueNotifier<CustomPaint?> _customPaintNotifier = ValueNotifier(null);
  final ValueNotifier<String> _statusNotifier = ValueNotifier("Ready to Start");
  final ValueNotifier<double> _scoreNotifier = ValueNotifier(0.0);

  bool _isAlerting = false;
  double _currentPerclos = 0.0;
  bool _isOccluded = false;

  double _debugPitch = 0.0;
  double _debugMar = 0.0;
  double _debugEar = 0.0;

  double _baselineEarThreshold = 0.20;
  double _marThreshold = DrowsinessLogic.yawnMarThreshold;

  bool _useARKit = false;
  bool _capabilityCheckDone = false;

  bool get _isIOS => Platform.isIOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _checkDeviceCapabilities();
    _audioPlayer.setReleaseMode(ReleaseMode.loop);
  }

  Future<void> _checkDeviceCapabilities() async {
    if (!_isIOS) {
      _useARKit = false;
      _capabilityCheckDone = true;
      _initializeCamera();
      return;
    }

    // Default to ARKit for iOS
    _useARKit = true;

    if (!_useARKit) {
      _initializeCamera();
    }

    if (mounted) {
      setState(() {
        _capabilityCheckDone = true;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _stopCamera();
      _stopAlert();
    } else if (state == AppLifecycleState.resumed) {
      if (_capabilityCheckDone) {
        if (!_useARKit) {
          _initializeCamera();
        } else {
          if (mounted) {
            setState(() {
              _arKitKey = UniqueKey();
            });
          }
        }
      }
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

  // --- ANDROID / STANDARD CAMERA SETUP ---
  Future<void> _initializeCamera() async {
    if (_cameraController != null) return;

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      _statusNotifier.value = "No Camera";
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
      await controller.startImageStream(_processCameraImage);
      setState(() => _cameraController = controller);
    } catch (e) {
      debugPrint("Camera Init Error: $e");
    }
  }

  Future<void> _stopCamera() async {
    final controller = _cameraController;
    if (mounted) {
      setState(() {
        _cameraController = null;
        _customPaintNotifier.value = null;
      });
    }
    if (controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (e) { debugPrint("Error stopping stream: $e"); }
      await controller.dispose();
    }

    _arkitController?.dispose();
    _faceNode = null;
    _faceGeometry = null;
    _arkitController = null;
  }

  void _startMonitoring() {
    _fusionEngine.reset();
    setState(() {
      _isMonitoring = true;
      _statusNotifier.value = "Monitoring...";
      _scoreNotifier.value = 0.0;
    });
  }

  void _stopMonitoring() {
    _stopAlert();
    setState(() {
      _isMonitoring = false;
      _statusNotifier.value = "Session Paused";
      _isAlerting = false;
      _currentPerclos = 0.0;
      _scoreNotifier.value = 0.0;
    });
  }

  // --- ANDROID: PROCESSING LOOP ---
  void _processCameraImage(CameraImage image) async {
    _frameCounter++;
    if (_frameCounter % _processEveryNthFrame != 0) return;
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      if (_cameraController == null) return;
      _applyLowLightEnhancement(image);

      final inputImage = _prepareInputImage(image);
      if (inputImage == null) return;

      // Smart Service returns either List<FaceMesh> or List<Face>
      final dynamic results = await _faceDetectorService.processImage(inputImage);

      // 1. FACE MESH LOGIC (Priority on Android)
      if (results is List<FaceMesh> && results.isNotEmpty) {
        final mesh = results.first;
        final double currentEar = DrowsinessLogic.calculateMeshEAR(mesh);
        final double mar = DrowsinessLogic.calculateMeshMAR(mesh);
        // Pitch extraction from 3D Mesh points is possible but complex, placeholder 0.0 for now
        final double pitch = 0.0;

        _runFusionLogic(currentEar, mar, pitch);

        final painter = FaceDetectorPainter(
          meshes: results,
          imageSize: inputImage.metadata!.size,
          rotation: inputImage.metadata!.rotation,
          cameraLensDirection: CameraLensDirection.front,
          isAlerting: _isAlerting,
        );
        _customPaintNotifier.value = CustomPaint(painter: painter);
      }
      // 2. STANDARD FACE LOGIC (Fallback)
      else if (results is List<Face> && results.isNotEmpty) {
        final face = results.first;
        final double currentEar = DrowsinessLogic.calculateEAR(face);
        final double mar = DrowsinessLogic.calculateMAR(face);
        final double pitch = face.headEulerAngleX ?? 0.0;

        _runFusionLogic(currentEar, mar, pitch);

        final painter = FaceDetectorPainter(
          faces: results,
          imageSize: inputImage.metadata!.size,
          rotation: inputImage.metadata!.rotation,
          cameraLensDirection: CameraLensDirection.front,
          isAlerting: _isAlerting,
        );
        _customPaintNotifier.value = CustomPaint(painter: painter);
      } else {
        _customPaintNotifier.value = null;
      }
    } catch (e) {
      debugPrint("Processing error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  // --- iOS: ARKIT PROCESSING LOOP ---
  void _onARKitViewCreated(ARKitController arkitController) {
    _arkitController = arkitController;
    _arkitController?.onAddNodeForAnchor = _handleAddAnchor;
    _arkitController?.onUpdateNodeForAnchor = _handleUpdateAnchor;
  }

  void _handleAddAnchor(ARKitAnchor anchor) {
    if (anchor is! ARKitFaceAnchor) return;

    final material = ARKitMaterial(
      fillMode: ARKitFillMode.lines,
      diffuse: ARKitMaterialProperty.color(Colors.cyanAccent.withOpacity(0.8)),
    );

    _faceGeometry = ARKitFace(materials: [material]);
    _faceNode = ARKitNode(geometry: _faceGeometry);
    _arkitController?.add(_faceNode!, parentNodeName: anchor.nodeName);
  }

  void _handleUpdateAnchor(ARKitAnchor anchor) {
    if (anchor is ARKitFaceAnchor && mounted) {
      if (_faceNode != null) {
        _arkitController?.updateFaceGeometry(_faceNode!, anchor.identifier);
      }

      if (!_isMonitoring) {
        _extractAndShowDebug(anchor);
        return;
      }
      _processARKitLogic(anchor);
    }
  }

  double _getPitch(Matrix4 transform) {
    try {
      final q = vector.Quaternion.fromRotation(transform.getRotation());
      final double sinp = 2 * (q.w * q.x - q.y * q.z);
      if (sinp.abs() >= 1) {
        return vector.degrees(pi / 2 * (sinp.sign));
      } else {
        return vector.degrees(asin(sinp));
      }
    } catch (e) {
      return 0.0;
    }
  }

  void _extractAndShowDebug(ARKitFaceAnchor anchor) {
    final blendShapes = anchor.blendShapes;
    final double leftBlink = blendShapes['eyeBlink_L'] ?? 0.0;
    final double rightBlink = blendShapes['eyeBlink_R'] ?? 0.0;
    final double jawOpen = blendShapes['jawOpen'] ?? 0.0;

    final double ear = DrowsinessLogic.calculateArKitEAR(leftBlink, rightBlink);
    final double mar = DrowsinessLogic.calculateArKitMAR(jawOpen);

    final double pitch = _getPitch(anchor.transform);

    if (mounted) {
      setState(() {
        _debugMar = mar;
        _debugEar = ear;
        _debugPitch = pitch;
      });
    }
  }

  void _processARKitLogic(ARKitFaceAnchor anchor) {
    final blendShapes = anchor.blendShapes;
    final double leftBlink = blendShapes['eyeBlink_L'] ?? 0.0;
    final double rightBlink = blendShapes['eyeBlink_R'] ?? 0.0;
    final double jawOpen = blendShapes['jawOpen'] ?? 0.0;

    final double ear = DrowsinessLogic.calculateArKitEAR(leftBlink, rightBlink);
    final double mar = DrowsinessLogic.calculateArKitMAR(jawOpen);

    final double pitch = _getPitch(anchor.transform);

    _runFusionLogic(ear, mar, pitch);
  }

  // --- SHARED: FUSION LOGIC ---
  void _runFusionLogic(double ear, double mar, double pitch) {
    final result = _fusionEngine.processFrame(
      currentEar: ear,
      headPitch: pitch,
      mar: mar,
      earThreshold: _baselineEarThreshold,
      marThreshold: _marThreshold,
    );

    final bool shouldAlert = result['alert'] as bool;
    final double score = result['score'] ?? 0.0;

    if (mounted) {
      setState(() {
        _statusNotifier.value = result['status'] as String;
        _isAlerting = shouldAlert;
        _currentPerclos = result['perclos'] ?? 0.0;
        _isOccluded = result['isOccluded'] ?? false;
        _scoreNotifier.value = score;

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
  }

  void _applyLowLightEnhancement(CameraImage image) {
    if (Platform.isAndroid && image.format.group == ImageFormatGroup.yuv420) {
      try {
        final Uint8List yBytes = image.planes[0].bytes;
        int sum = 0;
        int step = 100;
        for (int i = 0; i < yBytes.length; i += step) {
          sum += yBytes[i];
        }
        double avgBrightness = sum / (yBytes.length / step);
        if (avgBrightness < 80) {
          _performHistogramEqualization(yBytes);
        }
      } catch (e) {
        debugPrint("Enhancement skipped: $e");
      }
    }
  }

  void _performHistogramEqualization(Uint8List bytes) {
    final List<int> hist = List.filled(256, 0);
    for (int i = 0; i < bytes.length; i += 4) hist[bytes[i]]++;
    final List<int> cdf = List.filled(256, 0);
    int sum = 0;
    for (int i = 0; i < 256; i++) {
      sum += hist[i];
      cdf[i] = sum;
    }
    final int totalPixels = (bytes.length / 4).floor();
    final int minCdf = cdf.firstWhere((val) => val > 0, orElse: () => 0);
    final double scale = 255.0 / (totalPixels - minCdf);
    final List<int> map = List.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int val = ((cdf[i] - minCdf) * scale).round();
      map[i] = val.clamp(0, 255);
    }
    for (int i = 0; i < bytes.length; i++) bytes[i] = map[bytes[i]];
  }

  Future<void> _triggerAlert() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [500, 1000, 500, 1000], intensities: [1, 255]);
    }
    if (_audioPlayer.state != PlayerState.playing) {
      try {
        await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
      } catch (e) { debugPrint("Audio Play Error: $e"); }
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
      _statusNotifier.value = "Monitoring Resumed";
      _scoreNotifier.value = 0.0;
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
    _customPaintNotifier.dispose();
    _statusNotifier.dispose();
    _scoreNotifier.dispose();
    super.dispose();
  }

  Future<void> _safeNavigate(Widget destination) async {
    _stopMonitoring();
    await _stopCamera();

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => destination),
    );

    await Future.delayed(const Duration(milliseconds: 200));
    await _loadSettings();
    if (_capabilityCheckDone) {
      if (!_useARKit) {
        await _initializeCamera();
      } else {
        if (mounted) {
          setState(() {
            _arKitKey = UniqueKey();
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_capabilityCheckDone) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final bool isCameraReady = _useARKit || (_cameraController != null && _cameraController!.value.isInitialized);

    if (!isCameraReady) {
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator())
      );
    }

    final size = MediaQuery.of(context).size;

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
          if (_useARKit)
            ARKitSceneView(
              key: _arKitKey,
              configuration: ARKitConfiguration.faceTracking,
              onARKitViewCreated: _onARKitViewCreated,
              enableTapRecognizer: false,
            )
          else
            RepaintBoundary(
              child: Transform.scale(
                scale: size.aspectRatio * _cameraController!.value.aspectRatio,
                child: Center(
                  child: CameraPreview(_cameraController!),
                ),
              ),
            ),

          if (!_useARKit)
            ValueListenableBuilder<CustomPaint?>(
              valueListenable: _customPaintNotifier,
              builder: (context, paint, child) {
                return Transform.scale(
                  scale: size.aspectRatio * _cameraController!.value.aspectRatio,
                  child: Center(child: paint ?? const SizedBox()),
                );
              },
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
                  ValueListenableBuilder<String>(
                    valueListenable: _statusNotifier,
                    builder: (context, status, _) => Text(
                      status.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                  ),

                  if (_isMonitoring)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: ValueListenableBuilder<double>(
                        valueListenable: _scoreNotifier,
                        builder: (context, score, _) => Text(
                          "Risk Score: ${score.toInt()}",
                          style: TextStyle(
                              color: score > 75 ? Colors.orange : Colors.grey,
                              fontSize: 14,
                              fontWeight: FontWeight.bold
                          ),
                        ),
                      ),
                    ),

                  const SizedBox(height: 12),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildMetric(
                          "EAR",
                          "${_debugEar.toStringAsFixed(2)} / ${_baselineEarThreshold.toStringAsFixed(2)}"
                      ),
                      _buildMetric(
                          "MAR",
                          "${_debugMar.toStringAsFixed(2)} / ${_marThreshold.toStringAsFixed(2)}"
                      ),
                      _buildMetric(
                          "PITCH",
                          "${_debugPitch.toInt()}°"
                      ),
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
                        label: const Text(
                            "START MONITORING",
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
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



// import 'dart:async';
// import 'dart:io';
// import 'dart:typed_data';
// import 'dart:math';
// import 'package:camera/camera.dart';
// import 'package:flutter/foundation.dart';
// import 'package:flutter/material.dart';
// import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
// import 'package:audioplayers/audioplayers.dart';
// import 'package:vibration/vibration.dart';
// // ARKit Import
// import 'package:arkit_plugin/arkit_plugin.dart';
// import 'package:vector_math/vector_math_64.dart' as vector;
//
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
//   // --- CAMERA (Android/Standard) ---
//   CameraController? _cameraController;
//
//   // --- ARKIT (iOS) ---
//   ARKitController? _arkitController;
//   ARKitNode? _faceNode;
//   ARKitFace? _faceGeometry;
//   // Key to control ARKit View lifecycle
//   Key _arKitKey = UniqueKey();
//
//   // --- SERVICES ---
//   final FaceDetectorService _faceDetectorService = FaceDetectorService();
//   final CalibrationService _calibrationService = CalibrationService();
//   final FusionEngine _fusionEngine = FusionEngine();
//   final AudioPlayer _audioPlayer = AudioPlayer();
//
//   // --- STATE ---
//   bool _isProcessing = false;
//   bool _isMonitoring = false;
//
//   int _frameCounter = 0;
//   static const int _processEveryNthFrame = 3;
//
//   // UI State Notifiers (To prevent full rebuilds)
//   final ValueNotifier<CustomPaint?> _customPaintNotifier = ValueNotifier(null);
//   final ValueNotifier<String> _statusNotifier = ValueNotifier("Ready to Start");
//   final ValueNotifier<double> _scoreNotifier = ValueNotifier(0.0);
//
//   bool _isAlerting = false;
//   double _currentPerclos = 0.0;
//   bool _isOccluded = false;
//
//   double _debugPitch = 0.0;
//   double _debugMar = 0.0;
//   double _debugEar = 0.0;
//
//   double _baselineEarThreshold = 0.20;
//   double _marThreshold = DrowsinessLogic.yawnMarThreshold;
//
//   bool get _isIOS => Platform.isIOS;
//
//   @override
//   void initState() {
//     super.initState();
//     WidgetsBinding.instance.addObserver(this);
//     _loadSettings();
//
//     // Initial startup
//     if (!_isIOS) {
//       _initializeCamera();
//     }
//
//     _audioPlayer.setReleaseMode(ReleaseMode.loop);
//   }
//
//   @override
//   void didChangeAppLifecycleState(AppLifecycleState state) {
//     if (state == AppLifecycleState.inactive) {
//       _stopCamera();
//       _stopAlert();
//     } else if (state == AppLifecycleState.resumed) {
//       if (!_isIOS) {
//         _initializeCamera();
//       } else {
//         // On iOS, force a rebuild to restart ARKit view by changing the key
//         if (mounted) {
//           setState(() {
//             _arKitKey = UniqueKey();
//           });
//         }
//       }
//     }
//   }
//
//   Future<void> _loadSettings() async {
//     final baselines = await _calibrationService.getBaselines();
//     if (baselines['threshold'] != null && baselines['threshold']! > 0) {
//       _baselineEarThreshold = baselines['threshold']!;
//     }
//     if (baselines['perclos'] != null) {
//       _fusionEngine.updateBaseline(baselines['perclos']!);
//     }
//     if (baselines['mar'] != null && baselines['mar']! > 0) {
//       _marThreshold = baselines['mar']!;
//     }
//     if (mounted) setState(() {});
//   }
//
//   // --- ANDROID / STANDARD CAMERA SETUP ---
//   Future<void> _initializeCamera() async {
//     if (_cameraController != null) return;
//
//     final cameras = await availableCameras();
//     if (cameras.isEmpty) {
//       _statusNotifier.value = "No Camera";
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
//       await controller.startImageStream(_processCameraImage);
//       setState(() => _cameraController = controller);
//     } catch (e) {
//       debugPrint("Camera Init Error: $e");
//     }
//   }
//
//   Future<void> _stopCamera() async {
//     // 1. Android Cleanup
//     final controller = _cameraController;
//     if (mounted) {
//       setState(() {
//         _cameraController = null;
//         _customPaintNotifier.value = null; // Reset painter
//       });
//     }
//     if (controller != null) {
//       try {
//         if (controller.value.isStreamingImages) {
//           await controller.stopImageStream();
//         }
//       } catch (e) { debugPrint("Error stopping stream: $e"); }
//       await controller.dispose();
//     }
//
//     // 2. iOS Cleanup
//     _arkitController?.dispose();
//     _faceNode = null;
//     _faceGeometry = null;
//     _arkitController = null;
//   }
//
//   void _startMonitoring() {
//     _fusionEngine.reset();
//     setState(() {
//       _isMonitoring = true;
//       _statusNotifier.value = "Monitoring...";
//       _scoreNotifier.value = 0.0;
//     });
//   }
//
//   void _stopMonitoring() {
//     _stopAlert();
//     setState(() {
//       _isMonitoring = false;
//       _statusNotifier.value = "Session Paused";
//       _isAlerting = false;
//       _currentPerclos = 0.0;
//       _scoreNotifier.value = 0.0;
//     });
//   }
//
//   // --- ANDROID: PROCESSING LOOP ---
//   void _processCameraImage(CameraImage image) async {
//     _frameCounter++;
//     if (_frameCounter % _processEveryNthFrame != 0) return;
//     if (_isProcessing) return;
//     _isProcessing = true;
//
//     try {
//       if (_cameraController == null) return;
//       _applyLowLightEnhancement(image);
//
//       final inputImage = _prepareInputImage(image);
//       if (inputImage == null) return;
//
//       final faces = await _faceDetectorService.processImage(inputImage);
//
//       if (faces is List<Face> && faces.isNotEmpty) {
//         final face = faces.first;
//         final double currentEar = DrowsinessLogic.calculateEAR(face);
//         final double mar = DrowsinessLogic.calculateMAR(face);
//         final double pitch = face.headEulerAngleX ?? 0.0;
//
//         _runFusionLogic(currentEar, mar, pitch);
//
//         final painter = FaceDetectorPainter(
//           faces: faces,
//           imageSize: inputImage.metadata!.size,
//           rotation: inputImage.metadata!.rotation,
//           cameraLensDirection: CameraLensDirection.front,
//           isAlerting: _isAlerting,
//         );
//
//         _customPaintNotifier.value = CustomPaint(painter: painter);
//
//       } else {
//         _customPaintNotifier.value = null;
//       }
//     } catch (e) {
//       debugPrint("Processing error: $e");
//     } finally {
//       _isProcessing = false;
//     }
//   }
//
//   // --- iOS: ARKIT PROCESSING LOOP ---
//   void _onARKitViewCreated(ARKitController arkitController) {
//     _arkitController = arkitController;
//     _arkitController?.onAddNodeForAnchor = _handleAddAnchor;
//     _arkitController?.onUpdateNodeForAnchor = _handleUpdateAnchor;
//   }
//
//   void _handleAddAnchor(ARKitAnchor anchor) {
//     if (anchor is! ARKitFaceAnchor) return;
//
//     final material = ARKitMaterial(
//       fillMode: ARKitFillMode.lines,
//       diffuse: ARKitMaterialProperty.color(Colors.cyanAccent.withOpacity(0.8)),
//     );
//
//     _faceGeometry = ARKitFace(materials: [material]);
//     _faceNode = ARKitNode(geometry: _faceGeometry);
//     _arkitController?.add(_faceNode!, parentNodeName: anchor.nodeName);
//   }
//
//   void _handleUpdateAnchor(ARKitAnchor anchor) {
//     if (anchor is ARKitFaceAnchor && mounted) {
//       if (_faceNode != null) {
//         _arkitController?.updateFaceGeometry(_faceNode!, anchor.identifier);
//       }
//
//       if (!_isMonitoring) {
//         _extractAndShowDebug(anchor);
//         return;
//       }
//       _processARKitLogic(anchor);
//     }
//   }
//
//   // Calculate pitch from ARKit transform matrix
//   double _calculatePitchFromTransform(Matrix4 transform) {
//     // ARKit transform is a 4x4 matrix.
//     // Pitch (rotation around X) can be derived from the rotation components.
//     // However, ARKit face anchor transform is relative to the camera.
//     // A simpler approximation for pitch is often used by extracting Euler angles.
//
//     // Convert Matrix4 to Quaternion
//     final vector.Quaternion q = vector.Quaternion.fromRotation(transform.getRotation());
//
//     // Convert Quaternion to Euler Angles (Roll, Pitch, Yaw)
//     // Note: Order matters. ARKit usually Y=Up, X=Right, Z=Back (Right-handed)
//     // But pitch is rotation around X.
//
//     // Simplified Pitch extraction:
//     // pitch = atan2(R21, R22) or similar depending on convention.
//     // Let's use vector_math's utility if available, or manual calculation.
//
//     // Extract rotation matrix components
//     final r21 = transform.entry(1, 2);
//     final r22 = transform.entry(2, 2);
//     final r20 = transform.entry(0, 2);
//
//     // Calculate Pitch (in radians)
//     // Typically pitch = asin(-r20) or atan2(r21, r22)
//     // For ARKit Face Anchor, we want head nod (X-axis rotation).
//     // Let's try standard Euler extraction:
//
//     // Pitch (X-axis rotation)
//     // double pitchRadians = asin(-transform[2]); // Simplest approximation
//
//     // More robust Euler extraction from Rotation Matrix
//     // assuming ZYX order
//     // double pitch = -asin(transform.row2.x);
//
//     // Let's use the row-major indices:
//     // Row 0: 0, 4, 8, 12
//     // Row 1: 1, 5, 9, 13
//     // Row 2: 2, 6, 10, 14
//
//     // Pitch is often calculated as:
//     double pitchRadians = -asin(transform.entry(2, 0).clamp(-1.0, 1.0)); // clamping for safety
//
//     // Or if that fails (gimbal lock), use atan2
//     // For head tracking, a simple vector projection is often safer:
//     // Look at the "forward" vector (column 2) y-component.
//
//     // Forward vector Z (column 2)
//     // double forwardY = transform.entry(1, 2);
//     // double forwardZ = transform.entry(2, 2);
//     // double pitchRadians = atan2(forwardY, forwardZ);
//
//     // Let's stick to converting degrees
//     return vector.degrees(pitchRadians);
//   }
//
//   // Better Helper for Euler Angles using quaternion
//   double _getPitch(Matrix4 transform) {
//     try {
//       final q = vector.Quaternion.fromRotation(transform.getRotation());
//       // Euler angles from quaternion: pitch (x), yaw (y), roll (z)
//       // pitch = atan2(2(q0q1 + q2q3), 1 - 2(q1^2 + q2^2))
//
//       // Manual conversion to Euler (X-axis rotation)
//       final double sinp = 2 * (q.w * q.x - q.y * q.z);
//       if (sinp.abs() >= 1) {
//         // use 90 degrees if out of range
//         return vector.degrees(pi / 2 * (sinp.sign));
//       } else {
//         return vector.degrees(asin(sinp));
//       }
//     } catch (e) {
//       return 0.0;
//     }
//   }
//
//   void _extractAndShowDebug(ARKitFaceAnchor anchor) {
//     final blendShapes = anchor.blendShapes;
//     final double leftBlink = blendShapes['eyeBlink_L'] ?? 0.0;
//     final double rightBlink = blendShapes['eyeBlink_R'] ?? 0.0;
//     final double jawOpen = blendShapes['jawOpen'] ?? 0.0;
//
//     final double ear = DrowsinessLogic.calculateArKitEAR(leftBlink, rightBlink);
//     final double mar = DrowsinessLogic.calculateArKitMAR(jawOpen);
//
//     // Calculate Pitch from Transform Matrix
//     final double pitch = _getPitch(anchor.transform);
//
//     if (mounted) {
//       setState(() {
//         _debugMar = mar;
//         _debugEar = ear;
//         _debugPitch = pitch;
//       });
//     }
//   }
//
//   void _processARKitLogic(ARKitFaceAnchor anchor) {
//     final blendShapes = anchor.blendShapes;
//     final double leftBlink = blendShapes['eyeBlink_L'] ?? 0.0;
//     final double rightBlink = blendShapes['eyeBlink_R'] ?? 0.0;
//     final double jawOpen = blendShapes['jawOpen'] ?? 0.0;
//
//     final double ear = DrowsinessLogic.calculateArKitEAR(leftBlink, rightBlink);
//     final double mar = DrowsinessLogic.calculateArKitMAR(jawOpen);
//
//     // Calculate Pitch from Transform Matrix
//     final double pitch = _getPitch(anchor.transform);
//
//     _runFusionLogic(ear, mar, pitch);
//   }
//
//   // --- SHARED: FUSION LOGIC ---
//   void _runFusionLogic(double ear, double mar, double pitch) {
//     final result = _fusionEngine.processFrame(
//       currentEar: ear,
//       headPitch: pitch,
//       mar: mar,
//       earThreshold: _baselineEarThreshold,
//       marThreshold: _marThreshold,
//     );
//
//     final bool shouldAlert = result['alert'] as bool;
//     final double score = result['score'] ?? 0.0;
//
//     if (mounted) {
//       setState(() {
//         _statusNotifier.value = result['status'] as String;
//         _isAlerting = shouldAlert;
//         _currentPerclos = result['perclos'] ?? 0.0;
//         _isOccluded = result['isOccluded'] ?? false;
//         _scoreNotifier.value = score;
//
//         _debugMar = result['smoothedMar'] ?? 0.0;
//         _debugPitch = result['smoothedPitch'] ?? 0.0;
//         _debugEar = result['smoothedEar'] ?? 0.0;
//       });
//
//       if (shouldAlert) {
//         _triggerAlert();
//       } else {
//         _stopAlert();
//       }
//     }
//   }
//
//   void _applyLowLightEnhancement(CameraImage image) {
//     if (Platform.isAndroid && image.format.group == ImageFormatGroup.yuv420) {
//       try {
//         final Uint8List yBytes = image.planes[0].bytes;
//         int sum = 0;
//         int step = 100;
//         for (int i = 0; i < yBytes.length; i += step) {
//           sum += yBytes[i];
//         }
//         double avgBrightness = sum / (yBytes.length / step);
//         if (avgBrightness < 80) {
//           _performHistogramEqualization(yBytes);
//         }
//       } catch (e) {
//         debugPrint("Enhancement skipped: $e");
//       }
//     }
//   }
//
//   void _performHistogramEqualization(Uint8List bytes) {
//     final List<int> hist = List.filled(256, 0);
//     for (int i = 0; i < bytes.length; i += 4) hist[bytes[i]]++;
//     final List<int> cdf = List.filled(256, 0);
//     int sum = 0;
//     for (int i = 0; i < 256; i++) {
//       sum += hist[i];
//       cdf[i] = sum;
//     }
//     final int totalPixels = (bytes.length / 4).floor();
//     final int minCdf = cdf.firstWhere((val) => val > 0, orElse: () => 0);
//     final double scale = 255.0 / (totalPixels - minCdf);
//     final List<int> map = List.filled(256, 0);
//     for (int i = 0; i < 256; i++) {
//       int val = ((cdf[i] - minCdf) * scale).round();
//       map[i] = val.clamp(0, 255);
//     }
//     for (int i = 0; i < bytes.length; i++) bytes[i] = map[bytes[i]];
//   }
//
//   Future<void> _triggerAlert() async {
//     if (await Vibration.hasVibrator() ?? false) {
//       Vibration.vibrate(pattern: [500, 1000, 500, 1000], intensities: [1, 255]);
//     }
//     if (_audioPlayer.state != PlayerState.playing) {
//       try {
//         await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
//       } catch (e) { debugPrint("Audio Play Error: $e"); }
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
//   void _dismissAndReset() {
//     _stopAlert();
//     _fusionEngine.reset();
//     setState(() {
//       _isAlerting = false;
//       _statusNotifier.value = "Monitoring Resumed";
//       _scoreNotifier.value = 0.0;
//     });
//   }
//
//   InputImage? _prepareInputImage(CameraImage image) {
//     if (_cameraController == null) return null;
//     final plane = image.planes.first;
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
//     _stopCamera();
//     _faceDetectorService.dispose();
//     _audioPlayer.dispose();
//     _customPaintNotifier.dispose();
//     _statusNotifier.dispose();
//     _scoreNotifier.dispose();
//     super.dispose();
//   }
//
//   Future<void> _safeNavigate(Widget destination) async {
//     _stopMonitoring();
//     await _stopCamera();
//
//     if (!mounted) return;
//
//     await Navigator.push(
//       context,
//       MaterialPageRoute(builder: (context) => destination),
//     );
//
//     // Wait for the route transition to complete
//     await Future.delayed(const Duration(milliseconds: 200));
//     await _loadSettings();
//
//     // Re-initialize based on platform
//     if (!_isIOS) {
//       await _initializeCamera();
//     } else {
//       // iOS: Regenerate the key to force ARKitSceneView to rebuild fresh
//       if (mounted) {
//         setState(() {
//           _arKitKey = UniqueKey();
//         });
//       }
//     }
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     // Only check camera controller on Android
//     final bool isCameraReady = _isIOS || (_cameraController != null && _cameraController!.value.isInitialized);
//
//     if (!isCameraReady) {
//       return const Scaffold(
//           backgroundColor: Colors.black,
//           body: Center(child: CircularProgressIndicator())
//       );
//     }
//
//     final size = MediaQuery.of(context).size;
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
//           // --- CAMERA LAYER ---
//           if (_isIOS)
//             ARKitSceneView(
//               // Stable key avoids flashing, changing key on nav return fixes freezing
//               key: _arKitKey,
//               configuration: ARKitConfiguration.faceTracking,
//               onARKitViewCreated: _onARKitViewCreated,
//               enableTapRecognizer: false,
//             )
//           else
//             RepaintBoundary(
//               child: Transform.scale(
//                 scale: size.aspectRatio * _cameraController!.value.aspectRatio,
//                 child: Center(
//                   child: CameraPreview(_cameraController!),
//                 ),
//               ),
//             ),
//
//           // --- PAINTER LAYER (Android Only) ---
//           if (!_isIOS)
//             ValueListenableBuilder<CustomPaint?>(
//               valueListenable: _customPaintNotifier,
//               builder: (context, paint, child) {
//                 return Transform.scale(
//                   scale: size.aspectRatio * _cameraController!.value.aspectRatio,
//                   child: Center(child: paint ?? const SizedBox()),
//                 );
//               },
//             ),
//
//           // --- UI OVERLAY ---
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
//                   // Status Text
//                   ValueListenableBuilder<String>(
//                     valueListenable: _statusNotifier,
//                     builder: (context, status, _) => Text(
//                       status.toUpperCase(),
//                       textAlign: TextAlign.center,
//                       style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
//                     ),
//                   ),
//
//                   // Score
//                   if (_isMonitoring)
//                     Padding(
//                       padding: const EdgeInsets.only(top: 4.0),
//                       child: ValueListenableBuilder<double>(
//                         valueListenable: _scoreNotifier,
//                         builder: (context, score, _) => Text(
//                           "Risk Score: ${score.toInt()}",
//                           style: TextStyle(
//                               color: score > 75 ? Colors.orange : Colors.grey,
//                               fontSize: 14,
//                               fontWeight: FontWeight.bold
//                           ),
//                         ),
//                       ),
//                     ),
//
//                   const SizedBox(height: 12),
//
//                   // Debug Metrics
//                   Row(
//                     mainAxisAlignment: MainAxisAlignment.spaceAround,
//                     children: [
//                       _buildMetric(
//                           "EAR",
//                           "${_debugEar.toStringAsFixed(2)} / ${_baselineEarThreshold.toStringAsFixed(2)}"
//                       ),
//                       _buildMetric(
//                           "MAR",
//                           "${_debugMar.toStringAsFixed(2)} / ${_marThreshold.toStringAsFixed(2)}"
//                       ),
//                       _buildMetric(
//                           "PITCH",
//                           "${_debugPitch.toInt()}°"
//                       ),
//                     ],
//                   ),
//
//                   const SizedBox(height: 20),
//
//                   if (_isAlerting)
//                     SizedBox(
//                       width: double.infinity,
//                       child: ElevatedButton.icon(
//                         onPressed: _dismissAndReset,
//                         icon: const Icon(Icons.notifications_off),
//                         label: const Text("DISMISS & RESET"),
//                         style: ElevatedButton.styleFrom(
//                           backgroundColor: Colors.white,
//                           foregroundColor: Colors.red,
//                           padding: const EdgeInsets.symmetric(vertical: 12),
//                         ),
//                       ),
//                     )
//                   else if (!_isMonitoring)
//                     SizedBox(
//                       width: double.infinity,
//                       child: ElevatedButton.icon(
//                         onPressed: _startMonitoring,
//                         icon: const Icon(Icons.play_circle_filled),
//                         label: const Text(
//                             "START MONITORING",
//                             style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
//                         ),
//                         style: ElevatedButton.styleFrom(
//                           backgroundColor: Colors.green,
//                           foregroundColor: Colors.white,
//                           padding: const EdgeInsets.symmetric(vertical: 12),
//                         ),
//                       ),
//                     )
//                   else
//                     SizedBox(
//                       width: double.infinity,
//                       child: ElevatedButton.icon(
//                         onPressed: _stopMonitoring,
//                         icon: const Icon(Icons.stop_circle),
//                         label: const Text("STOP MONITORING"),
//                         style: ElevatedButton.styleFrom(
//                           backgroundColor: Colors.grey[800],
//                           foregroundColor: Colors.white,
//                           padding: const EdgeInsets.symmetric(vertical: 12),
//                         ),
//                       ),
//                     ),
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