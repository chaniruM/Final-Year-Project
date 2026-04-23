import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'camera_utils.dart';

class TrackingUtils {
  /// Utility method to cleanly swap between ARKit and MLKit modes
  static Future<CameraController?> toggleTrackingMode({
    required bool useARKit,
    required ARKitController? arkitController,
    required CameraController? cameraController,
    required Function(bool newUseARKit, Key newArKitKey) onStateUpdate,
    Function()? onBeforeToggle,
    Function(CameraImage)? onImageStream,
  }) async {
    // Execute any caller-specific prep
    onBeforeToggle?.call();

    // 1. Toggle flag and invoke UI set state first.
    // This instantly unmounts the CameraPreview or ARKitSceneView from the widget tree.
    final newUseARKit = !useARKit;
    onStateUpdate(newUseARKit, UniqueKey());

    // Yield control to let Flutter rebuild the widget tree without the old preview
    await Future.delayed(Duration.zero);

    // 2. Cleanup current controller safely now that it's unmounted
    if (useARKit) {
      arkitController?.dispose();
    } else {
      if (cameraController != null) {
        if (cameraController.value.isStreamingImages) {
          try {
            await cameraController.stopImageStream();
          } catch (_) {}
        }
        await cameraController.dispose();
      }
    }

    // 3. Re-initialize new controller stream if jumping to MLKit
    CameraController? newCameraController;
    if (!newUseARKit) {
      newCameraController = await CameraUtils.initializeFrontCamera();
      if (newCameraController != null && onImageStream != null) {
        await newCameraController.startImageStream(onImageStream);
      }
    }

    return newCameraController;
  }

  /// Builds the toggle action button for AppBars
  static Widget buildToggleAction({
    required bool isARKitSupported,
    required bool useARKit,
    required VoidCallback onToggle,
    bool isEnabled = true,
  }) {
    if (!isARKitSupported) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: GestureDetector(
        onTap: isEnabled ? onToggle : null,
        child: Opacity(
          opacity: isEnabled ? 1.0 : 0.5,
          child: Container(
            width: 120,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white24, width: 1.5),
            ),
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: useARKit ? 60 : 2,
                  right: useARKit ? 2 : 60,
                  top: 2,
                  bottom: 2,
                  child: Container(
                    decoration: BoxDecoration(
                      color: useARKit ? Colors.cyanAccent : Colors.tealAccent,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color:
                              (useARKit ? Colors.cyanAccent : Colors.tealAccent)
                                  .withOpacity(0.4),
                          blurRadius: 8,
                          spreadRadius: 1,
                        )
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Center(
                        child: Text(
                          "MLKIT",
                          style: TextStyle(
                            color: !useARKit ? Colors.black : Colors.white70,
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          "ARKIT",
                          style: TextStyle(
                            color: useARKit ? Colors.black : Colors.white70,
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
