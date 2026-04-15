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
import 'dart:ui';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logic/fusion_engine.dart';
import 'calibration_view.dart';
import 'onboarding_view.dart';
import 'profile_view.dart';
import 'widgets/detector_status_panel.dart';
import 'painters/face_detector_painter.dart';
import '../../../core/utils/tracking_utils.dart';

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

  bool _isAudioPlaying = false; // Add this manual tracker

  // --- STATE ---
  bool _isProcessing = false;
  bool _isMonitoring = false;
  String _drowsinessStatus = "Ready to Start";
  
  // 0: Normal, 1: Warning, 2: Critical Alert
  int _currentAlertLevel = 0; 
  
  double _currentScore = 0.0;
  CustomPaint? _customPaint;
  
  int _mlkitFrameCount = 0;
  int _arkitFrameCount = 0;

  // --- THRESHOLDS & DEBUG ---
  double _baselineEarThreshold = 0.20;
  double _marThreshold = DrowsinessConstants.yawnMarThreshold;
  double _baselinePitch = 0.0; // Keep track of the pitch baseline locally
  double _debugPitch = 0.0;
  double _debugMar = 0.0;
  double _debugEar = 0.0;
  bool _isOccluded = false;

  bool _useARKit = false;
  bool _isARKitSupported = false;
  bool _capabilityCheckDone = false;
  
  String? _calibratedEngine;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _initDevice();
    _audioPlayer.setReleaseMode(ReleaseMode.loop);
  }

  Future<void> _initDevice() async {
    _isARKitSupported = await CapabilityUtils.supportsARKit();
    final savedPref = await _calibrationService.getTrackingPreference();
    _useARKit = savedPref != null ? (savedPref && _isARKitSupported) : _isARKitSupported;
    
    if (!_useARKit) {
      _cameraController = await CameraUtils.initializeFrontCamera();
      if (_cameraController != null) {
        await _cameraController!.startImageStream(_processCameraImage);
      }
    }
    
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('has_seen_onboarding') != true) {
      if (mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (context) => const OnboardingView()));
      }
    }

    setState(() => _capabilityCheckDone = true);
  }

  Future<void> _toggleTrackingMode() async {
    if (!_isARKitSupported) return;

    final newController = await TrackingUtils.toggleTrackingMode(
      useARKit: _useARKit,
      arkitController: _arkitController,
      cameraController: _cameraController,
      onBeforeToggle: () {
        _isMonitoring = false;
        _stopAlert();
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
    if (baselines['pitch'] != null) {
      _baselinePitch = baselines['pitch']!;
    }
    
    _calibratedEngine = await _calibrationService.getCalibratedEngine();
    
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
    
    // Frame Skipping: Skip every other frame to save battery/CPU (~15 FPS)
    _mlkitFrameCount++;
    if (_mlkitFrameCount % 2 != 0) return;
    
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
                alertLevel: _currentAlertLevel,
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
        // ARKit naturally runs at 60fps. Throttle to save resources.
        _arkitFrameCount++;
        if (_arkitFrameCount % 3 != 0) return;
        
        if (_faceNode != null) _arkitController?.updateFaceGeometry(_faceNode!, anchor.identifier);
        final blendShapes = anchor.blendShapes;
        // isTracked identifies if the global face mesh broke
        final ear = DrowsinessConstants.calculateArKitEAR(
          blendShapes['eyeBlink_L'] ?? 0.0, 
          blendShapes['eyeBlink_R'] ?? 0.0,
          isTracked: anchor.isTracked,
        );
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
        baselinePitch: _baselinePitch, // Pass the baseline
      );
      if (mounted) {
        setState(() {
          _drowsinessStatus = result['status'] as String;
          _currentAlertLevel = result['alertLevel'] as int;
          _currentScore = result['score'] ?? 0.0;
          _debugMar = result['smoothedMar'] ?? 0.0;
          _debugPitch = result['smoothedPitch'] ?? 0.0;
          _debugEar = result['smoothedEar'] ?? 0.0;
          _isOccluded = result['isOccluded'] == true;
        });
        
        if (_currentAlertLevel > 0) {
          _triggerAlert(_currentAlertLevel);
        } else {
          _stopAlert();
        }
      }
    } else if (mounted) {
      setState(() {
        _debugMar = mar;
        _debugPitch = pitch - _baselinePitch; // Show relative pitch in paused state
        _debugEar = ear;
      });
    }
  }

  Future<void> _triggerAlert(int level) async {
    if (!_isMonitoring) return; // Guard to prevent alerts when paused

    if (level == 2) {
      // CRITICAL ALERT: Audio + Strong Vibration Loop
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [500, 1000, 500, 1000], intensities: [1, 255]);
      }
      
      // Use manual tracking instead of _audioPlayer.state
      if (!_isAudioPlaying) {
        _isAudioPlaying = true;
        try {
          await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));
        } catch (e) { 
          debugPrint("Audio Error: $e"); 
          _isAudioPlaying = false;
        }
      }
    } else if (level == 1) {
      // WARNING ALERT: Short Vibration Only (Don't annoy driver for a yawn)
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(duration: 300);
      }
      // If you add a short warning ding sound in the future, play it here without looping.
    }
  }

  Future<void> _stopAlert() async {
    _isAudioPlaying = false;
    try {
      await _audioPlayer.stop(); // Unconditional stop
    } catch (e) {
      debugPrint("Audio Stop Error: $e");
    }
    Vibration.cancel();
  }

  void _stopAll() async {
    _stopAlert();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _cameraController = null;
    _arkitController?.dispose();
    _arkitController = null;
    
    WakelockPlus.disable(); // Ensure screen can sleep again when completely stopped
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
    
    // Unmount controllers from UI instantly to prevent build exceptions
    final tempCamCtrl = _cameraController;
    final tempArCtrl = _arkitController;
    
    setState(() {
      _cameraController = null;
      _arkitController = null;
      _customPaint = null;
    });

    // Safely dispose hardware without holding the UI hostage
    try {
      if (tempCamCtrl != null && tempCamCtrl.value.isStreamingImages) {
        await tempCamCtrl.stopImageStream();
      }
      await tempCamCtrl?.dispose();
    } catch (_) {}
    
    tempArCtrl?.dispose();

    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (context) => destination));
    await _loadSettings();

    // Hard Sync: Manually check global preference upon return in case it was modified!
    final savedPref = await _calibrationService.getTrackingPreference();
    if (savedPref != null) {
      _useARKit = savedPref && _isARKitSupported;
    } else {
      _useARKit = _isARKitSupported;
    }

    // Restart logic natively based on synchronized preference
    if (!_useARKit) {
      _initCameraStream();
    } else {
      if (mounted) setState(() => _arKitKey = UniqueKey());
    }
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
            onTap: !_useARKit || _isMonitoring
                ? null
                : _toggleTrackingMode,
          ),
          const SizedBox(width: 6),
          _buildModeOption(
            label: "ARKit",
            selected: _useARKit,
            onTap: _useARKit || !_isARKitSupported || _isMonitoring
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

  void _showDetectorMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 20),
                _buildSheetTile(
                  icon: Icons.help_outline,
                  title: "Setup Guide",
                  onTap: () {
                    Navigator.pop(context);
                    _safeNavigate(const OnboardingView());
                  },
                ),
                _buildSheetTile(
                  icon: Icons.person_outline,
                  title: "Profile",
                  onTap: () {
                    Navigator.pop(context);
                    _safeNavigate(const ProfileView());
                  },
                ),
                _buildSheetTile(
                  icon: Icons.tune,
                  title: "Calibration",
                  onTap: () {
                    Navigator.pop(context);
                    _safeNavigate(const CalibrationView());
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSheetTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 14),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right, color: Colors.white54),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_capabilityCheckDone) {
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()));
    }

    Widget cameraLayer = const SizedBox.shrink();
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      final size = MediaQuery.of(context).size;
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
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        toolbarHeight: 64,
        elevation: 0,
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _isMonitoring
                    ? (_currentAlertLevel == 2
                        ? Colors.redAccent
                        : _currentAlertLevel == 1
                            ? Colors.orangeAccent
                            : Colors.greenAccent)
                    : Colors.grey,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              "DriveSafe",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: Colors.white,
              ),
            ),
          ],
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
        actions: [
          // Tracking toggle removed from AppBar, now sits in Stack
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 6),
            child: IconButton(
              onPressed: _showDetectorMenu,
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.08),
                  ),
                ),
                child: const Icon(Icons.more_horiz, color: Colors.white, size: 20),
              ),
            ),
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
                enableTapRecognizer: false)
          else
            cameraLayer,

          Positioned(
            top: MediaQuery.of(context).padding.top + 80,
            left: 0,
            right: 0,
            child: Center(
              child: _buildTrackingModeSwitcher(),
            ),
          ),

          if (_isOccluded && _isMonitoring)
            Positioned(
              top: MediaQuery.of(context).padding.top + 140,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black87, 
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.yellowAccent, width: 2),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.visibility_off, color: Colors.yellowAccent, size: 28),
                    SizedBox(width: 12),
                    Text(
                      "EYES OCCLUDED", 
                      style: TextStyle(
                        color: Colors.yellowAccent, 
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                        letterSpacing: 1.2
                      ),
                    ),
                  ],
                ),
              ),
            ),

          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: DetectorStatusPanel(
              status: _drowsinessStatus,
              score: _currentScore,
              isMonitoring: _isMonitoring,
              alertLevel: _currentAlertLevel,
              debugEar: _debugEar,
              baselineEar: _baselineEarThreshold,
              debugMar: _debugMar,
              baselineMar: _marThreshold,
              debugPitch: _debugPitch,
              onStart: () {
                final currentEngine = _useARKit ? 'arkit' : 'mlkit';
                if (_calibratedEngine != null && _calibratedEngine != currentEngine) {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text("Calibration Mismatch", style: TextStyle(color: Colors.redAccent)),
                      content: Text(
                        "You calibrated your baseline with ${_calibratedEngine?.toUpperCase()}, but are trying to run the detector using ${currentEngine.toUpperCase()}.\n\nPlease open settings and recalibrate.",
                        style: const TextStyle(color: Colors.white70),
                      ),
                      backgroundColor: Colors.grey[900],
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text("OK", style: TextStyle(color: Colors.cyanAccent)),
                        )
                      ],
                    )
                  );
                  return;
                }
                
                _fusionEngine.reset();
                WakelockPlus.enable(); // Keep screen fully awake while monitoring
                setState(() => _isMonitoring = true);
              },
              onStop: () {
                _stopAlert();
                WakelockPlus.disable(); // Let screen sleep when paused
                setState(() {
                  _isMonitoring = false;
                  _currentAlertLevel = 0;
                  _drowsinessStatus = "Paused";
                });
              },
              onDismiss: () {
                _stopAlert();
                _fusionEngine.reset();
                setState(() {
                  _currentAlertLevel = 0;
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