import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:arkit_plugin/arkit_plugin.dart'; // iOS
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'; // Fallback
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart'; // Android Mesh
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';

import '../../../core/constants/drowsiness_logic.dart';
import '../../../core/models/driver_state.dart';
import '../data/face_detector_service.dart';
import '../data/face_mesh_service.dart';
import '../data/calibration_service.dart';
import 'painters/face_detector_painter.dart';
import 'painters/face_mesh_painter.dart';
import 'profile_view.dart';
import 'calibration_view.dart';

class DetectorView extends StatefulWidget {
  const DetectorView({super.key});

  @override
  State<DetectorView> createState() => _DetectorViewState();
}

class _DetectorViewState extends State<DetectorView> with WidgetsBindingObserver {
  // --- Services ---
  final CalibrationService _calibrationService = CalibrationService();
  final FusionEngine _fusionEngine = FusionEngine();
  final AudioPlayer _audioPlayer = AudioPlayer();

  // --- Android / Legacy Variables ---
  CameraController? _cameraController;
  final FaceDetectorService _legacyService = FaceDetectorService();
  final FaceMeshService _meshService = FaceMeshService();
  bool _isProcessing = false;
  CustomPaint? _customPaint;

  // --- iOS AR Variables ---
  ARKitController? _arController;
  ARKitNode? _faceNode;
  bool _useArKit = false;

  // --- State ---
  bool _isMonitoring = false;
  String _drowsinessStatus = "Initializing...";
  bool _isAlerting = false;
  double _currentScore = 0.0;

  // Debug UI
  double _debugEar = 0.0;
  double _debugMar = 0.0;
  double _debugPitch = 0.0;

  // Settings
  double _baselineEarThreshold = 0.20;
  double _marThreshold = DrowsinessLogic.yawnMarThreshold;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audioPlayer.setReleaseMode(ReleaseMode.loop);
    _checkPlatformAndInit();
  }

  Future<void> _checkPlatformAndInit() async {
    await _loadSettings();

    if (Platform.isIOS) {
      setState(() {
        _useArKit = true;
      });
    } else {
      _initializeCamera();
    }
  }

  Future<void> _loadSettings() async {
    final baselines = await _calibrationService.getBaselines();
    if (baselines['threshold'] != null && baselines['threshold']! > 0) {
      _baselineEarThreshold = baselines['threshold']!;
    }
    if (baselines['mar'] != null && baselines['mar']! > 0) {
      _marThreshold = baselines['mar']!;
    }
  }

  // ----------------------------------------------------------------------
  // 1. iOS ARKit Implementation
  // ----------------------------------------------------------------------

  Widget _buildIOSView() {
    return ARKitSceneView(
      configuration: ARKitConfiguration.faceTracking,
      onARKitViewCreated: _onARViewCreated,
    );
  }

  void _onARViewCreated(ARKitController controller) {
    _arController = controller;
    _arController!.onAddNodeForAnchor = _handleAddAnchor;
    _arController!.onUpdateNodeForAnchor = _handleUpdateAnchor;
  }

  void _handleAddAnchor(ARKitAnchor anchor) {
    if (anchor is! ARKitFaceAnchor) return;

    // Visual Mesh Feedback
    final material = ARKitMaterial(
      fillMode: ARKitFillMode.lines,
      diffuse: ARKitMaterialProperty.color(
          _isAlerting ? Colors.red.withOpacity(0.6) : Colors.greenAccent.withOpacity(0.4)
      ),
    );

    anchor.geometry.materials.value = [material];

    _faceNode = ARKitNode(geometry: anchor.geometry);
    _arController!.add(_faceNode!, parentNodeName: anchor.nodeName);
  }

  void _handleUpdateAnchor(ARKitAnchor anchor) {
    if (anchor is ARKitFaceAnchor) {

      // 1. Update Visual Mesh Geometry
      if (_faceNode != null) {
        _arController!.updateFaceGeometry(_faceNode!, anchor.identifier);

        // Update color if alerting
        final color = _isAlerting ? Colors.red.withOpacity(0.6) : Colors.greenAccent.withOpacity(0.4);
        // Note: ARKitPlugin materials might need re-assignment or property update depending on version,
        // but geometry update is the critical part for movement.
      }

      // 2. Monitoring Logic
      if (_isMonitoring) {
        final shapes = anchor.blendShapes;
        final leftBlink = shapes['eyeBlink_L'] ?? 0.0;
        final rightBlink = shapes['eyeBlink_R'] ?? 0.0;
        final jawOpen = shapes['jawOpen'] ?? 0.0;

        double pitch = 0.0; // Simplify pitch for ARKit

        final state = DriverState(
          leftEyeOpenProbability: 1.0 - leftBlink,
          rightEyeOpenProbability: 1.0 - rightBlink,
          mouthOpenness: jawOpen,
          headPitch: pitch,
          headYaw: 0,
          isFaceDetected: true,
        );

        _processUnifiedState(state);
      }
    }
  }

  // ----------------------------------------------------------------------
  // 2. Android / Fallback Implementation (Camera + ML Kit)
  // ----------------------------------------------------------------------

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

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

    await controller.initialize();
    if (!mounted) return;

    await controller.startImageStream(_processCameraImage);
    setState(() => _cameraController = controller);
  }

  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      if (_cameraController == null) return;
      final inputImage = _prepareInputImage(image);
      if (inputImage == null) return;

      DriverState? driverState;
      CustomPaint? newPaint;

      // A. Try Face Mesh (Android Priority)
      if (Platform.isAndroid) {
        final meshes = await _meshService.processImage(inputImage);
        if (meshes.isNotEmpty) {
          final mesh = meshes.first;
          driverState = _meshService.mapToDriverState(mesh);

          newPaint = CustomPaint(
            painter: FaceMeshPainter(
              meshes,
              inputImage.metadata!.size,
              inputImage.metadata!.rotation,
              CameraLensDirection.front,
              _isAlerting,
            ),
          );
        }
      }

      // B. Fallback to Legacy Detector
      if (driverState == null) {
        final faces = await _legacyService.processImage(inputImage);
        if (faces.isNotEmpty) {
          final face = faces.first;
          double ear = DrowsinessLogic.calculateEAR(face);
          double mar = DrowsinessLogic.calculateLegacyMAR(face);

          double simProb = ear / 0.35;
          if (simProb > 1.0) simProb = 1.0;

          driverState = DriverState(
            leftEyeOpenProbability: simProb,
            rightEyeOpenProbability: simProb,
            mouthOpenness: mar,
            headPitch: face.headEulerAngleX ?? 0.0,
            headYaw: 0,
            isFaceDetected: true,
          );

          newPaint = CustomPaint(
            painter: FaceDetectorPainter(
              faces,
              inputImage.metadata!.size,
              inputImage.metadata!.rotation,
              CameraLensDirection.front,
              _isAlerting,
            ),
          );
        }
      }

      if (mounted) {
        setState(() => _customPaint = newPaint);
        if (driverState != null && _isMonitoring) {
          _processUnifiedState(driverState);
        } else if (driverState == null && _isMonitoring) {
          _processUnifiedState(DriverState.empty());
        }
      }

    } catch (e) {
      debugPrint("Error processing frame: $e");
    } finally {
      _isProcessing = false;
    }
  }

  // ----------------------------------------------------------------------
  // 3. Central Logic Processor
  // ----------------------------------------------------------------------

  void _processUnifiedState(DriverState state) {
    final result = _fusionEngine.processState(
      state: state,
      earThreshold: _baselineEarThreshold,
      marThreshold: _marThreshold,
    );

    setState(() {
      _drowsinessStatus = result['status'];
      _currentScore = result['score'];
      _isAlerting = result['alert'];

      _debugEar = result['smoothedEar'];
      _debugMar = result['smoothedMar'];
      _debugPitch = result['smoothedPitch'];
    });

    if (_isAlerting) {
      _triggerAlert();
    } else {
      _stopAlert();
    }
  }

  // ----------------------------------------------------------------------
  // 4. UI & Lifecycle
  // ----------------------------------------------------------------------

  void _startMonitoring() {
    _fusionEngine.reset();
    setState(() {
      _isMonitoring = true;
      _currentScore = 0.0;
      _drowsinessStatus = "Active Monitoring";
    });
  }

  void _stopMonitoring() {
    _stopAlert();
    setState(() {
      _isMonitoring = false;
      _currentScore = 0.0;
      _drowsinessStatus = "Paused";
    });
  }

  Future<void> _triggerAlert() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [500, 500, 500, 500], intensities: [255, 255]);
    }
    if (_audioPlayer.state != PlayerState.playing) {
      _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
    }
  }

  Future<void> _stopAlert() async {
    if (_audioPlayer.state == PlayerState.playing) {
      _audioPlayer.stop();
    }
    Vibration.cancel();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _arController?.dispose();
    _legacyService.dispose();
    _meshService.dispose();
    _audioPlayer.dispose();
    super.dispose();
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
  Widget build(BuildContext context) {
    Widget bodyContent;

    if (_useArKit) {
      bodyContent = _buildIOSView();
    } else {
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        bodyContent = const Center(child: CircularProgressIndicator());
      } else {
        final size = MediaQuery.of(context).size;
        var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
        if (scale < 1) scale = 1 / scale;

        bodyContent = Transform.scale(
          scale: scale,
          child: Center(
            child: CameraPreview(_cameraController!, child: _customPaint),
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_useArKit ? "Driver Guardian (AR)" : "Driver Guardian (Mesh)"),
        backgroundColor: _isAlerting ? Colors.red : Colors.blueAccent,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const ProfileView())),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const CalibrationView())),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          bodyContent,
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: _buildHud(),
          ),
        ],
      ),
    );
  }

  Widget _buildHud() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isAlerting ? Colors.red.withOpacity(0.9) : Colors.black87,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _drowsinessStatus,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _statItem("EAR", _debugEar.toStringAsFixed(2)),
              _statItem("MAR", _debugMar.toStringAsFixed(2)),
              _statItem("SCORE", _currentScore.toInt().toString()),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isMonitoring ? _stopMonitoring : _startMonitoring,
              icon: Icon(_isMonitoring ? Icons.stop : Icons.play_arrow),
              label: Text(_isMonitoring ? "STOP MONITORING" : "START MONITORING"),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isMonitoring ? Colors.grey : Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _statItem(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontFamily: 'Monospace')),
      ],
    );
  }
}