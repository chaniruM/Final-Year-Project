import 'dart:async';
import 'dart:io';
import 'dart:math'; // For pi, asin
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
// ARKit Imports
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
  // --- CAMERA (Android/Fallback) ---
  CameraController? _cameraController;
  final FaceDetectorService _faceDetectorService = FaceDetectorService();

  // --- ARKIT (iOS FaceID) ---
  ARKitController? _arkitController;
  ARKitNode? _faceNode;
  ARKitFace? _faceGeometry;
  Key _arKitKey = UniqueKey();

  final CalibrationService _calibrationService = CalibrationService();
  final FusionEngine _fusionEngine = FusionEngine();
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _isProcessing = false;
  bool _isMonitoring = false;

  String _drowsinessStatus = "Ready to Start";
  bool _isAlerting = false;
  bool _isOccluded = false;
  double _currentPerclos = 0.0;

  // Debug values
  double _debugPitch = 0.0;
  double _debugMar = 0.0;
  double _debugEar = 0.0;
  double _currentScore = 0.0;

  CustomPaint? _customPaint;

  double _baselineEarThreshold = 0.20;
  double _marThreshold = DrowsinessLogic.yawnMarThreshold;

  // Capability Flags
  bool _useARKit = false;
  bool _capabilityCheckDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _checkDeviceCapabilities();
    _audioPlayer.setReleaseMode(ReleaseMode.loop);
  }

  Future<void> _checkDeviceCapabilities() async {
    if (Platform.isIOS) {
      final deviceInfo = DeviceInfoPlugin();
      final iosInfo = await deviceInfo.iosInfo;

      // We prioritize ARKit (FaceID) if available because it works in the dark (IR)
      if (iosInfo.isPhysicalDevice) {
        setState(() {
          _useARKit = true;
          _capabilityCheckDone = true;
        });
      } else {
        // Simulator -> Fallback to Standard Camera
        setState(() {
          _useARKit = false;
          _capabilityCheckDone = true;
        });
        _initializeCamera();
      }
    } else {
      // Android always uses ML Kit
      setState(() {
        _useARKit = false;
        _capabilityCheckDone = true;
      });
      _initializeCamera();
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
          // ARKit usually handles resume internally, but we can force rebuild if needed
          if (mounted) setState(() => _arKitKey = UniqueKey());
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

  // --- STANDARD CAMERA SETUP (Android / iOS Fallback) ---
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
        _customPaint = null;
      });
    }

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

    // Dispose ARKit as well
    _arkitController?.dispose();
    _arkitController = null;
    _faceNode = null;
    _faceGeometry = null;
  }

  void _startMonitoring() {
    _fusionEngine.reset();
    setState(() {
      _isMonitoring = true;
      _drowsinessStatus = "Monitoring...";
      _currentScore = 0.0;
    });
  }

  void _stopMonitoring() {
    _stopAlert();
    setState(() {
      _isMonitoring = false;
      _drowsinessStatus = "Session Paused";
      _isAlerting = false;
      _currentPerclos = 0.0;
      _currentScore = 0.0;
    });
  }

  // --- ML KIT PROCESSING (Android/Fallback) ---
  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      if (_cameraController == null) return;

      final inputImage = _prepareInputImage(image);
      if (inputImage == null) return;

      final faces = await _faceDetectorService.processImage(inputImage);

      if (faces.isNotEmpty) {
        final face = faces.first;

        final double currentEar = DrowsinessLogic.calculateEAR(face);
        final double mar = DrowsinessLogic.calculateMAR(face);
        // ML Kit returns Positive for looking UP, Negative for looking DOWN
        final double pitch = face.headEulerAngleX ?? 0.0;

        _processFusionLogic(currentEar, mar, pitch);

        final painter = FaceDetectorPainter(
          faces: faces,
          imageSize: inputImage.metadata!.size,
          rotation: inputImage.metadata!.rotation,
          cameraLensDirection: CameraLensDirection.front,
          isAlerting: _isAlerting,
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

  // --- ARKIT PROCESSING (iOS FaceID) ---
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

      // Extract Data from Blendshapes
      final blendShapes = anchor.blendShapes;
      final double leftBlink = blendShapes['eyeBlink_L'] ?? 0.0;
      final double rightBlink = blendShapes['eyeBlink_R'] ?? 0.0;
      final double jawOpen = blendShapes['jawOpen'] ?? 0.0;

      final double ear = DrowsinessLogic.calculateArKitEAR(leftBlink, rightBlink);
      final double mar = DrowsinessLogic.calculateArKitMAR(jawOpen);

      // Extract Pitch from Transform Matrix
      final double pitch = _getPitchFromTransform(anchor.transform);

      _processFusionLogic(ear, mar, pitch);
    }
  }

  /// Calculates Head Pitch (Nodding) from ARKit Transform.
  ///
  /// WHY WE USE ARKIT TRANSFORM INSTEAD OF ML KIT HERE:
  /// 1. Night Vision: ARKit uses the TrueDepth (IR) sensor, allowing detection in
  ///    complete darkness. ML Kit relies on RGB and fails in low light.
  /// 2. Performance: We are already running the AR session. Extracting images
  ///    for ML Kit would double the CPU/GPU load.
  /// 3. Synchronization: ARKit data is synchronous with the frame (60fps).
  double _getPitchFromTransform(Matrix4 transform) {
    try {
      final q = vector.Quaternion.fromRotation(transform.getRotation());

      // Calculate Pitch (Rotation around X-axis) from Quaternion
      final double sinp = 2 * (q.w * q.x - q.y * q.z);

      // ARKit native coordinates: Positive Pitch = Looking Down.
      // ML Kit coordinates: Positive Pitch = Looking Up.
      // We negate (-) the result to match ML Kit's standard for our FusionEngine.
      if (sinp.abs() >= 1) {
        return -vector.degrees(pi / 2 * (sinp.sign));
      } else {
        return -vector.degrees(asin(sinp));
      }
    } catch (e) {
      return 0.0;
    }
  }

  // --- SHARED LOGIC ---
  void _processFusionLogic(double ear, double mar, double pitch) {
    if (_isMonitoring) {
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
          _drowsinessStatus = result['status'] as String;
          _isAlerting = shouldAlert;
          _currentPerclos = result['perclos'] ?? 0.0;
          _isOccluded = result['isOccluded'] ?? false;
          _currentScore = score;

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
      // Just update debug values for UI when not monitoring
      if (mounted) {
        setState(() {
          _debugMar = mar;
          _debugPitch = pitch;
          _debugEar = ear;
        });
      }
    }
  }

  Future<void> _triggerAlert() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [500, 1000, 500, 1000], intensities: [1, 255]);
    }

    if (_audioPlayer.state != PlayerState.playing) {
      try {
        await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
      } catch (e) {
        debugPrint("Audio Play Error: $e");
      }
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
      _currentScore = 0.0;
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
    await _stopCamera();

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => destination),
    );

    await Future.delayed(const Duration(milliseconds: 200));
    await _loadSettings();

    // Re-init correct camera type
    if (_capabilityCheckDone) {
      if (!_useARKit) {
        await _initializeCamera();
      } else {
        if (mounted) setState(() => _arKitKey = UniqueKey());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_capabilityCheckDone) {
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator())
      );
    }

    final bool isCameraReady = _useARKit || (_cameraController != null && _cameraController!.value.isInitialized);

    if (!isCameraReady) {
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator())
      );
    }

    // Calculate scale for standard camera preview
    double scale = 1.0;
    if (!_useARKit && _cameraController != null) {
      final size = MediaQuery.of(context).size;
      scale = size.aspectRatio * _cameraController!.value.aspectRatio;
      if (scale < 1) scale = 1 / scale;
    }

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
          // --- VIDEO LAYER ---
          if (_useARKit)
            ARKitSceneView(
              key: _arKitKey,
              configuration: ARKitConfiguration.faceTracking,
              onARKitViewCreated: _onARKitViewCreated,
              enableTapRecognizer: false,
            )
          else
            Transform.scale(
              scale: scale,
              child: Center(
                child: CameraPreview(_cameraController!, child: _customPaint),
              ),
            ),

          // --- UI LAYER ---
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
                  if (_isMonitoring)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        "Risk Score: ${_currentScore.toInt()}",
                        style: TextStyle(
                            color: _currentScore > 75 ? Colors.orange : Colors.grey,
                            fontSize: 14,
                            fontWeight: FontWeight.bold
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