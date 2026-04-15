import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import '../data/face_detector_service.dart';
import '../data/calibration_service.dart';
import '../../../core/constants/drowsiness_constants.dart';
import '../../../core/utils/camera_utils.dart';
import '../../../core/utils/capability_utils.dart';
import '../../../core/utils/tracking_utils.dart';
import 'painters/face_detector_painter.dart';

class CalibrationView extends StatefulWidget {
  const CalibrationView({super.key});

  @override
  State<CalibrationView> createState() => _CalibrationViewState();
}

class _CalibrationViewState extends State<CalibrationView> {
  // --- CAMERA ---
  CameraController? _cameraController;
  final FaceDetectorService _detectorService = FaceDetectorService();

  // --- ARKIT ---
  ARKitController? _arkitController;
  ARKitNode? _faceNode;

  final CalibrationService _calibrationService = CalibrationService();

  bool _isCalibrating = false;
  bool _calibrationSuccess = false;
  bool _isProcessing = false;
  int _timerCount = 10;
  bool _useARKit = false;
  bool _isARKitSupported = false;
  bool _capabilityCheckDone = false;
  Key _arKitKey = UniqueKey();

  final List<double> _capturedEarValues = [];
  final List<double> _capturedMarValues = [];
  final List<double> _capturedPitchValues = [];

  String _message = "Position phone. Ensure face is visible.";
  double _currentPreviewEar = 0.0;
  double _currentPreviewMar = 0.0;
  bool _isOccluded = false;
  CustomPaint? _customPaint;
  
  int _frameCount = 0;

  @override
  void initState() {
    super.initState();
    _checkCapabilities();
  }

  Future<void> _checkCapabilities() async {
    _isARKitSupported = await CapabilityUtils.supportsARKit();
    final savedPref = await _calibrationService.getTrackingPreference();
    _useARKit = savedPref != null ? (savedPref && _isARKitSupported) : _isARKitSupported;

    if (!_useARKit) {
      _cameraController = await CameraUtils.initializeFrontCamera();
      if (_cameraController != null) {
        await _cameraController!.startImageStream(_processCameraImage);
      }
    }
    setState(() => _capabilityCheckDone = true);
  }

  Future<void> _toggleTrackingMode() async {
    if (!_isARKitSupported || _isCalibrating) return; // Prevent toggle during calibration

    final newController = await TrackingUtils.toggleTrackingMode(
      useARKit: _useARKit,
      arkitController: _arkitController,
      cameraController: _cameraController,
      onBeforeToggle: () {
        _customPaint = null;
      },
      onStateUpdate: (newUseARKit, newArKitKey) {
        _calibrationService.setTrackingPreference(newUseARKit);
        setState(() {
          _useARKit = newUseARKit;
          _arKitKey = newArKitKey;
          _isProcessing = false;
          if (_useARKit) {
            _cameraController = null;
          } else {
            _arkitController = null;
          }
        });
      },
      onImageStream: _processCameraImage,
    );

    if (!_useARKit) {
      setState(() => _cameraController = newController);
    }
  }

  void _startCalibration() async {
    if (!_useARKit && _cameraController == null) return;

    setState(() {
      _isCalibrating = true;
      _calibrationSuccess = false;
      _timerCount = 10;
      _capturedEarValues.clear();
      _capturedMarValues.clear();
      _capturedPitchValues.clear();
      _frameCount = 0;
      _message = "Keep eyes OPEN. Mouth CLOSED (Neutral).";
    });

    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_timerCount <= 0 || !mounted || !_isCalibrating) {
        timer.cancel();
        if (_isCalibrating) _finishCalibration();
      } else {
        setState(() => _timerCount--);
      }
    });
  }

  // --- PROCESSING ---

  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    
    _frameCount++;
    if (_frameCount % 2 != 0) return;
    
    _isProcessing = true;

    try {
      final inputImage = CameraUtils.prepareInputImage(_cameraController!, image);
      if (inputImage != null) {
        final faces = await _detectorService.processImage(inputImage);

        if (faces.isNotEmpty) {
          final face = faces.first;
          final ear = DrowsinessConstants.calculateEAR(face);
          final mar = DrowsinessConstants.calculateMAR(face);
          final pitch = face.headEulerAngleX ?? 0.0;

          final painter = FaceDetectorPainter(
            faces: faces,
            imageSize: inputImage.metadata!.size,
            rotation: inputImage.metadata!.rotation,
            cameraLensDirection: CameraLensDirection.front,
            alertLevel: 0,
          );

          if (_isCalibrating) {
            if (ear > 0.0) _capturedEarValues.add(ear);
            if (mar > 0.0) _capturedMarValues.add(mar);
            _capturedPitchValues.add(pitch);
          }

          if (mounted) {
            setState(() {
              _currentPreviewEar = ear;
              _currentPreviewMar = mar;
              _isOccluded = (ear < 0.0);
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

  void _onARKitViewCreated(ARKitController arkitController) {
    _arkitController = arkitController;
    _arkitController?.onAddNodeForAnchor = _handleAddAnchor;
    _arkitController?.onUpdateNodeForAnchor = _handleUpdateAnchor;
  }

  void _handleAddAnchor(ARKitAnchor anchor) {
    if (anchor is! ARKitFaceAnchor) return;
    final material = ARKitMaterial(
        fillMode: ARKitFillMode.lines,
        diffuse:
        ARKitMaterialProperty.color(Colors.cyanAccent.withOpacity(0.8)));
    anchor.geometry.materials.value = [material];
    _faceNode = ARKitNode(geometry: anchor.geometry);
    _arkitController?.add(_faceNode!, parentNodeName: anchor.nodeName);
  }

  void _handleUpdateAnchor(ARKitAnchor anchor) {
    if (anchor is ARKitFaceAnchor && mounted) {
      _frameCount++;
      if (_frameCount % 3 != 0) return;
        
      if (_faceNode != null) {
        _arkitController?.updateFaceGeometry(_faceNode!, anchor.identifier);
      }
      final blendShapes = anchor.blendShapes;
      final ear = DrowsinessConstants.calculateArKitEAR(
          blendShapes['eyeBlink_L'] ?? 0.0, 
          blendShapes['eyeBlink_R'] ?? 0.0,
          isTracked: anchor.isTracked,
      );
      final mar = DrowsinessConstants.calculateArKitMAR(blendShapes['jawOpen'] ?? 0.0);
      final pitch = _getPitchFromTransform(anchor.transform);

      if (_isCalibrating) {
        _capturedEarValues.add(ear);
        _capturedMarValues.add(mar);
        _capturedPitchValues.add(pitch);
      }
      setState(() {
        _currentPreviewEar = ear;
        _currentPreviewMar = mar;
        _isOccluded = (ear < 0.0);
      });
    }
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

  Future<void> _finishCalibration() async {
    setState(() {
      _isCalibrating = false;
      _customPaint = null;
    });

    if (_capturedEarValues.isEmpty) {
      setState(() {
        _message = "Calibration Failed. No face detected.";
      });
      return;
    }

    // --- EAR CALIBRATION ---
    _capturedEarValues.sort();
    int earIndex = (_capturedEarValues.length * 0.85).toInt().clamp(0, _capturedEarValues.length - 1);
    double baselineOpenEar = _capturedEarValues[earIndex];
    double personalEarThreshold = baselineOpenEar * 0.75;

    // --- PERCLOS BASELINE (Scientific Constant) ---
    // 10 seconds is statistically too short to measure a natural blink rate.
    // We use the universally researched normal waking PERCLOS of 5% (0.05).
    double baselinePerclos = 0.05;

    // --- MAR CALIBRATION ---
    double personalMarThreshold = 0.5;
    if (_capturedMarValues.isNotEmpty) {
      _capturedMarValues.sort();
      int marIndex = (_capturedMarValues.length * 0.20).toInt().clamp(0, _capturedMarValues.length - 1);
      double baselineClosedMar = _capturedMarValues[marIndex];
      personalMarThreshold = (baselineClosedMar + 0.25).clamp(0.3, 0.6);
    }

    // --- PITCH BASELINE ---
    double baselinePitch = 0.0;
    if (_capturedPitchValues.isNotEmpty) {
      // Define sortedPitchValues properly instead of using _capturedPitchValues.sort()
      List<double> sortedPitchValues = List.from(_capturedPitchValues)..sort();
      
      int pStart = (sortedPitchValues.length * 0.20).toInt();
      int pEnd = (sortedPitchValues.length * 0.80).toInt();
      if (pEnd <= pStart) { pStart = 0; pEnd = sortedPitchValues.length; }
      List<double> validPitch = sortedPitchValues.sublist(pStart, pEnd);
      baselinePitch = validPitch.reduce((a, b) => a + b) / validPitch.length;
    }

    await _calibrationService.saveBaselines(
      personalEarThreshold, 
      baselinePerclos, 
      personalMarThreshold, 
      baselinePitch,
      isARKit: _useARKit,
    );

    setState(() {
      _isCalibrating = false;
      _calibrationSuccess = true;
      _message = "Success!\nEAR Thresh: ${personalEarThreshold.toStringAsFixed(3)}\nBase PERCLOS: ${(baselinePerclos * 100).toStringAsFixed(1)}%\nBase Pitch: ${baselinePitch.toStringAsFixed(1)}°";
    });
  }

  Future<void> _safeExit() async {
    _isProcessing = true;
    final tempCamCtrl = _cameraController;
    final tempArCtrl = _arkitController;

    setState(() {
      _cameraController = null;
      _arkitController = null;
      _customPaint = null;
    });

    try {
      if (tempCamCtrl != null) {
        if (tempCamCtrl.value.isStreamingImages) {
          await tempCamCtrl.stopImageStream();
        }
        await tempCamCtrl.dispose();
      }
    } catch (_) {}

    tempArCtrl?.dispose();

    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _detectorService.dispose();
    _arkitController?.dispose();
    super.dispose();
  }

  Widget _buildTrackingModeSwitcher() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeOption(
            label: "ML Kit",
            selected: !_useARKit,
            onTap: !_useARKit || _isCalibrating
                ? null
                : _toggleTrackingMode,
          ),
          const SizedBox(width: 6),
          _buildModeOption(
            label: "ARKit",
            selected: _useARKit,
            onTap: _useARKit || !_isARKitSupported || _isCalibrating
                ? null
                : _toggleTrackingMode,
          ),
        ],
      ),
    );
  }

  Widget _buildModeOption({
    required String label,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? Colors.cyanAccent.withOpacity(0.95)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_capabilityCheckDone) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final bool isCameraReady =
        _useARKit || (_cameraController != null && _cameraController!.value.isInitialized);

    Widget backgroundLayer;
    if (_useARKit) {
      backgroundLayer = ARKitSceneView(
        key: _arKitKey,
        configuration: ARKitConfiguration.faceTracking,
        onARKitViewCreated: _onARKitViewCreated,
        enableTapRecognizer: false,
      );
    } else if (isCameraReady) {
      final size = MediaQuery.of(context).size;
      var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
      if (scale < 1) scale = 1 / scale;

      backgroundLayer = Transform.scale(
        scale: scale,
        child: Center(
          child: CameraPreview(_cameraController!, child: _customPaint),
        ),
      );
    } else {
      backgroundLayer = const Center(child: CircularProgressIndicator());
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _safeExit();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          toolbarHeight: 64,
          elevation: 0,
          backgroundColor: Colors.transparent,
          leadingWidth: 72,
          leading: Padding(
            padding: const EdgeInsets.only(left: 12, top: 10, bottom: 10),
            child: GestureDetector(
              onTap: _safeExit,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.08),
                  ),
                ),
                child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
              ),
            ),
          ),
          titleSpacing: 4,
          title: const Text(
            "Calibration",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: Colors.white,
            ),
          ),
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.22),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withOpacity(0.08),
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            backgroundLayer,

            Positioned(
              top: MediaQuery.of(context).padding.top + 80,
              left: 0,
              right: 0,
              child: Center(
                child: _buildTrackingModeSwitcher(),
              ),
            ),
            
            if (_isOccluded && _isCalibrating)
              Positioned(
                top: MediaQuery.of(context).padding.top + 140,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black87, 
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.redAccent, width: 2),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.visibility_off, color: Colors.redAccent, size: 28),
                      SizedBox(width: 12),
                      Text(
                        "EYES OCCLUDED", 
                        style: TextStyle(
                          color: Colors.redAccent, 
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                          letterSpacing: 1.2
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_isCalibrating)
                  Container(
                    padding: const EdgeInsets.only(top: 20),
                    child: Column(
                      children: [
                        Text("EAR: ${_currentPreviewEar.toStringAsFixed(3)}",
                            style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 2, color: Colors.black)])),
                        Text("MAR: ${_currentPreviewMar.toStringAsFixed(3)}",
                            style: const TextStyle(color: Colors.yellowAccent, fontSize: 20, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 2, color: Colors.black)])),
                      ],
                    ),
                  )
                else
                  const SizedBox.shrink(),

                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.15), width: 1.5)),
                      ),
                      width: double.infinity,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 16),
                          if (_isCalibrating)
                            Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.cyanAccent.withOpacity(0.1),
                                boxShadow: [BoxShadow(color: Colors.cyanAccent.withOpacity(0.3), blurRadius: 30, spreadRadius: 5)],
                              ),
                              child: Text(
                                "$_timerCount", 
                                style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w900, color: Colors.cyanAccent),
                              ),
                            ),
                          const SizedBox(height: 32),

                          if (!_isCalibrating && _calibrationSuccess)
                            SizedBox(width: double.infinity, height: 56, child: ElevatedButton.icon(onPressed: _safeExit, icon: const Icon(Icons.check_circle), label: const Text("DONE - BACK TO DETECTOR"), style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, elevation: 8, shadowColor: Colors.green.withOpacity(0.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)))))
                          else
                            SizedBox(width: double.infinity, height: 56, child: ElevatedButton(onPressed: _isCalibrating ? null : _startCalibration, style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black, elevation: _isCalibrating ? 0 : 8, shadowColor: Colors.cyanAccent.withOpacity(0.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))), child: Text(_isCalibrating ? "CALIBRATING..." : "START CALIBRATION", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)))),
                        ],
                      ),
                    ),
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