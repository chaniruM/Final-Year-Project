import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import '../../../core/constants/drowsiness_constants.dart';
import '../../../core/utils/camera_utils.dart';
import '../../../core/utils/capability_utils.dart';
import '../data/face_detector_service.dart';
import '../data/calibration_service.dart';
import '../logic/fusion_engine.dart';
import 'calibration_view.dart';
import 'profile_view.dart';
import 'widgets/detector_status_panel.dart';
import 'painters/face_detector_painter.dart';

class DetectorView extends StatefulWidget {
  const DetectorView({super.key});

  @override
  State<DetectorView> createState() => _DetectorViewState();
}

class _DetectorViewState extends State<DetectorView> with WidgetsBindingObserver {
  // --- CONTROLLERS ---
  CameraController? _cameraController;
  final FaceDetectorService _faceDetectorService = FaceDetectorService();
  ARKitController? _arkitController;
  ARKitNode? _faceNode;
  Key _arKitKey = UniqueKey();

  final CalibrationService _calibrationService = CalibrationService();
  final FusionEngine _fusionEngine = FusionEngine();
  final AudioPlayer _audioPlayer = AudioPlayer();

  // --- STATE ---
  bool _isProcessing = false;
  bool _isMonitoring = false;
  String _drowsinessStatus = "Ready to Start";
  bool _isAlerting = false;
  double _currentScore = 0.0;
  CustomPaint? _customPaint;

  // --- THRESHOLDS & DEBUG ---
  double _baselineEarThreshold = 0.20;
  double _marThreshold = DrowsinessConstants.yawnMarThreshold;
  double _debugPitch = 0.0;
  double _debugMar = 0.0;
  double _debugEar = 0.0;

  bool _useARKit = false;
  bool _capabilityCheckDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _initDevice();
    _audioPlayer.setReleaseMode(ReleaseMode.loop);
  }

  Future<void> _initDevice() async {
    _useARKit = await CapabilityUtils.supportsARKit();
    if (!_useARKit) {
      _cameraController = await CameraUtils.initializeFrontCamera();
      if (_cameraController != null) {
        await _cameraController!.startImageStream(_processCameraImage);
      }
    }
    setState(() => _capabilityCheckDone = true);
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _stopAll();
    } else if (state == AppLifecycleState.resumed && _capabilityCheckDone) {
      if (!_useARKit) {
        _initCameraStream();
      } else {
        if (mounted) setState(() => _arKitKey = UniqueKey());
      }
    }
  }

  Future<void> _initCameraStream() async {
    _cameraController = await CameraUtils.initializeFrontCamera();
    if (_cameraController != null) {
      await _cameraController!.startImageStream(_processCameraImage);
      setState(() {});
    }
  }

  void _processCameraImage(CameraImage image) async {
    if (_isProcessing || _cameraController == null) return;
    _isProcessing = true;
    try {
      final inputImage = CameraUtils.prepareInputImage(_cameraController!, image);
      if (inputImage == null) return;
      final faces = await _faceDetectorService.processImage(inputImage);
      if (faces.isNotEmpty) {
        final face = faces.first;
        final ear = DrowsinessConstants.calculateEAR(face);
        final mar = DrowsinessConstants.calculateMAR(face);
        final pitch = face.headEulerAngleX ?? 0.0;
        _processFusionLogic(ear, mar, pitch);
        if (mounted) {
          setState(() {
            _customPaint = CustomPaint(
              painter: FaceDetectorPainter(
                faces: faces,
                imageSize: inputImage.metadata!.size,
                rotation: inputImage.metadata!.rotation,
                cameraLensDirection: CameraLensDirection.front,
                isAlerting: _isAlerting,
              ),
            );
          });
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

  // --- ARKIT LOGIC ---
  void _onARKitViewCreated(ARKitController arkitController) {
    _arkitController = arkitController;
    _arkitController?.onAddNodeForAnchor = (anchor) {
      if (anchor is! ARKitFaceAnchor) return;
      final material = ARKitMaterial(
          fillMode: ARKitFillMode.lines,
          diffuse: ARKitMaterialProperty.color(Colors.cyanAccent.withOpacity(0.8)));
      _faceNode = ARKitNode(geometry: ARKitFace(materials: [material]));
      _arkitController?.add(_faceNode!, parentNodeName: anchor.nodeName);
    };
    _arkitController?.onUpdateNodeForAnchor = (anchor) {
      if (anchor is ARKitFaceAnchor && mounted) {
        if (_faceNode != null) _arkitController?.updateFaceGeometry(_faceNode!, anchor.identifier);
        final blendShapes = anchor.blendShapes;
        final ear = DrowsinessConstants.calculateArKitEAR(blendShapes['eyeBlink_L'] ?? 0.0, blendShapes['eyeBlink_R'] ?? 0.0);
        final mar = DrowsinessConstants.calculateArKitMAR(blendShapes['jawOpen'] ?? 0.0);
        final pitch = _getPitchFromTransform(anchor.transform);
        _processFusionLogic(ear, mar, pitch);
      }
    };
  }

  double _getPitchFromTransform(Matrix4 transform) {
    try {
      final q = vector.Quaternion.fromRotation(transform.getRotation());
      final double sinp = 2 * (q.w * q.x - q.y * q.z);
      if (sinp.abs() >= 1) return -vector.degrees(pi / 2 * (sinp.sign));
      return -vector.degrees(asin(sinp));
    } catch (e) {
      return 0.0;
    }
  }

  // --- FUSION LOGIC ---
  void _processFusionLogic(double ear, double mar, double pitch) {
    if (_isMonitoring) {
      final result = _fusionEngine.processFrame(
        currentEar: ear,
        headPitch: pitch,
        mar: mar,
        earThreshold: _baselineEarThreshold,
        marThreshold: _marThreshold,
      );
      if (mounted) {
        setState(() {
          _drowsinessStatus = result['status'] as String;
          _isAlerting = result['alert'] as bool;
          _currentScore = result['score'] ?? 0.0;
          _debugMar = result['smoothedMar'] ?? 0.0;
          _debugPitch = result['smoothedPitch'] ?? 0.0;
          _debugEar = result['smoothedEar'] ?? 0.0;
        });
        _isAlerting ? _triggerAlert() : _stopAlert();
      }
    } else if (mounted) {
      setState(() {
        _debugMar = mar;
        _debugPitch = pitch;
        _debugEar = ear;
      });
    }
  }

  Future<void> _triggerAlert() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [500, 1000, 500, 1000], intensities: [1, 255]);
    }
    if (_audioPlayer.state != PlayerState.playing) {
      try {
        await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
      } catch (e) { debugPrint("Audio Error: $e"); }
    }
  }

  Future<void> _stopAlert() async {
    if (_audioPlayer.state == PlayerState.playing) await _audioPlayer.stop();
    Vibration.cancel();
  }

  void _stopAll() async {
    _stopAlert();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _cameraController = null;
    _arkitController?.dispose();
    _arkitController = null;
    setState(() => _customPaint = null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAll();
    _faceDetectorService.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _safeNavigate(Widget destination) async {
    _isMonitoring = false;
    _stopAlert();
    // Stop camera before navigation to free resources
    if (_cameraController != null && _cameraController!.value.isStreamingImages) {
      await _cameraController!.stopImageStream();
    }

    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (context) => destination));
    await _loadSettings();

    // Restart logic
    if (!_useARKit) {
      // Re-initialize completely for stability
      _initCameraStream();
    } else {
      if (mounted) setState(() => _arKitKey = UniqueKey());
    }
  }

  // @override
  // Widget build(BuildContext context) {
  //   if (!_capabilityCheckDone) return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));
  //
  //   return Scaffold(
  //     appBar: AppBar(
  //       title: const Text("Driver Guardian"),
  //       backgroundColor: _isAlerting ? Colors.red : Colors.blueAccent,
  //       actions: [
  //         IconButton(icon: const Icon(Icons.person), onPressed: () => _safeNavigate(const ProfileView())),
  //         IconButton(icon: const Icon(Icons.settings_accessibility), onPressed: () => _safeNavigate(const CalibrationView())),
  //       ],
  //     ),
  //     body: Stack(
  //       fit: StackFit.expand,
  //       children: [
  //         if (_useARKit)
  //           ARKitSceneView(key: _arKitKey, configuration: ARKitConfiguration.faceTracking, onARKitViewCreated: _onARKitViewCreated, enableTapRecognizer: false)
  //         else if (_cameraController != null && _cameraController!.value.isInitialized)
  //           CameraPreview(_cameraController!, child: _customPaint)
  //         else
  //           const Center(child: CircularProgressIndicator()),
  //
  //         Positioned(
  //           bottom: 30, left: 20, right: 20,
  //           child: DetectorStatusPanel(
  //             status: _drowsinessStatus,
  //             score: _currentScore,
  //             isMonitoring: _isMonitoring,
  //             isAlerting: _isAlerting,
  //             debugEar: _debugEar,
  //             baselineEar: _baselineEarThreshold,
  //             debugMar: _debugMar,
  //             baselineMar: _marThreshold,
  //             debugPitch: _debugPitch,
  //             onStart: () { _fusionEngine.reset(); setState(() => _isMonitoring = true); },
  //             onStop: () { _stopAlert(); setState(() { _isMonitoring = false; _isAlerting = false; _drowsinessStatus = "Paused"; }); },
  //             onDismiss: () { _stopAlert(); _fusionEngine.reset(); setState(() { _isAlerting = false; _drowsinessStatus = "Resumed"; }); },
  //           ),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  @override
  Widget build(BuildContext context) {
    if (!_capabilityCheckDone) {
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()));
    }

    // Calculate scaling to ensure the camera covers the screen without stretching
    Widget cameraLayer = const SizedBox.shrink();
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      final size = MediaQuery.of(context).size;
      // Calculate scale factor
      // Android cameras are usually landscape (e.g. 4:3), so we invert ratio for portrait
      var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
      if (scale < 1) scale = 1 / scale;

      cameraLayer = Transform.scale(
        scale: scale,
        child: Center(
          child: CameraPreview(_cameraController!, child: _customPaint),
        ),
      );
    } else if (!_useARKit) {
      cameraLayer = const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Drive Safe"),
        backgroundColor: _isAlerting ? Colors.red : Colors.blueAccent,
        actions: [
          IconButton(
              icon: const Icon(Icons.person),
              onPressed: () => _safeNavigate(const ProfileView())),
          IconButton(
              icon: const Icon(Icons.settings_accessibility),
              onPressed: () => _safeNavigate(const CalibrationView())),
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
                enableTapRecognizer: false)
          else
            cameraLayer, // Use the scaled camera layer here

          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: DetectorStatusPanel(
              status: _drowsinessStatus,
              score: _currentScore,
              isMonitoring: _isMonitoring,
              isAlerting: _isAlerting,
              debugEar: _debugEar,
              baselineEar: _baselineEarThreshold,
              debugMar: _debugMar,
              baselineMar: _marThreshold,
              debugPitch: _debugPitch,
              onStart: () {
                _fusionEngine.reset();
                setState(() => _isMonitoring = true);
              },
              onStop: () {
                _stopAlert();
                setState(() {
                  _isMonitoring = false;
                  _isAlerting = false;
                  _drowsinessStatus = "Paused";
                });
              },
              onDismiss: () {
                _stopAlert();
                _fusionEngine.reset();
                setState(() {
                  _isAlerting = false;
                  _drowsinessStatus = "Resumed";
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}