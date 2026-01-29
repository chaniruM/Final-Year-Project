import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart'; // Add Mesh support
import 'coordinates_translator.dart';

class FaceDetectorPainter extends CustomPainter {
  FaceDetectorPainter({
    required this.imageSize,
    required this.rotation,
    required this.cameraLensDirection,
    this.faces,
    this.meshes, // New: Support for Mesh
    this.isAlerting = false,
  });

  final List<Face>? faces;
  final List<FaceMesh>? meshes;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;
  final bool isAlerting;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = isAlerting ? Colors.red : Colors.greenAccent;

    final Paint meshPaint = Paint()
      ..style = PaintingStyle.fill
      ..strokeWidth = 1.0
      ..color = Colors.cyanAccent.withOpacity(0.4);

    // Helper to mirror X
    double transformX(double x) {
      double tx = translateX(x, size, imageSize, rotation, cameraLensDirection);
      if (cameraLensDirection == CameraLensDirection.front) {
        return size.width - tx;
      }
      return tx;
    }

    // --- MODE 1: DRAW FACES (Standard ML Kit) ---
    if (faces != null) {
      _paintFaces(canvas, size, paint, transformX);
    }

    // --- MODE 2: DRAW MESHES (Android Face Mesh) ---
    if (meshes != null) {
      _paintMeshes(canvas, size, meshPaint, transformX);
    }
  }

  void _paintMeshes(Canvas canvas, Size size, Paint paint, double Function(double) transformX) {
    for (final FaceMesh mesh in meshes!) {
      // Draw all 468 points as a point cloud
      // Note: Drawing lines (triangles) requires a triangulation map which is huge.
      // Points are faster and look decent.
      for (final point in mesh.points) {
        canvas.drawCircle(
          Offset(
            transformX(point.x.toDouble()),
            translateY(point.y.toDouble(), size, imageSize, rotation, cameraLensDirection),
          ),
          1.5, // Small dots
          paint,
        );
      }
    }
  }

  void _paintFaces(Canvas canvas, Size size, Paint paint, double Function(double) transformX) {
    // ... Copy your existing Face painting logic here ...
    // I will paste the previous robust logic below for completeness
    final Paint heightPointPaint = Paint()..style = PaintingStyle.fill..color = Colors.yellow;
    final Paint widthPointPaint = Paint()..style = PaintingStyle.fill..color = Colors.cyanAccent;
    final Paint eyePointPaint = Paint()..style = PaintingStyle.fill..color = Colors.green;
    final Paint linePaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.0..color = Colors.cyanAccent.withOpacity(0.5);

    for (final Face face in faces!) {
      // Box
      final left = transformX(face.boundingBox.left);
      final top = translateY(face.boundingBox.top, size, imageSize, rotation, cameraLensDirection);
      final right = transformX(face.boundingBox.right);
      final bottom = translateY(face.boundingBox.bottom, size, imageSize, rotation, cameraLensDirection);
      canvas.drawRect(Rect.fromLTRB(left < right ? left : right, top, left < right ? right : left, bottom), paint);

      // Eyes (Landmarks)
      void paintLandmark(FaceLandmarkType type) {
        final landmark = face.landmarks[type];
        if (landmark?.position != null) {
          canvas.drawCircle(Offset(transformX(landmark!.position.x.toDouble()), translateY(landmark.position.y.toDouble(), size, imageSize, rotation, cameraLensDirection)), 3, paint);
        }
      }
      paintLandmark(FaceLandmarkType.leftEye);
      paintLandmark(FaceLandmarkType.rightEye);
      paintLandmark(FaceLandmarkType.noseBase);

      // Eye Contours
      void paintContour(FaceContourType type) {
        final contour = face.contours[type];
        if (contour?.points != null) {
          for (final point in contour!.points) {
            canvas.drawCircle(Offset(transformX(point.x.toDouble()), translateY(point.y.toDouble(), size, imageSize, rotation, cameraLensDirection)), 2.0, eyePointPaint);
          }
        }
      }
      paintContour(FaceContourType.leftEye);
      paintContour(FaceContourType.rightEye);

      // Mouth (Inner & Outer)
      final upperInner = face.contours[FaceContourType.upperLipBottom]?.points;
      final lowerInner = face.contours[FaceContourType.lowerLipTop]?.points;
      final lowerOuter = face.contours[FaceContourType.lowerLipBottom]?.points;

      if (upperInner != null && lowerInner != null && upperInner.isNotEmpty && lowerInner.isNotEmpty) {
        int centerU = upperInner.length ~/ 2;
        int centerL = lowerInner.length ~/ 2;
        List<Point<int>> heightPoints = [];
        if (centerU >= 1 && centerU < upperInner.length - 1) heightPoints.addAll([upperInner[centerU - 1], upperInner[centerU], upperInner[centerU + 1]]);
        if (centerL >= 1 && centerL < lowerInner.length - 1) heightPoints.addAll([lowerInner[centerL - 1], lowerInner[centerL], lowerInner[centerL + 1]]);

        for (var point in heightPoints) {
          canvas.drawCircle(Offset(transformX(point.x.toDouble()), translateY(point.y.toDouble(), size, imageSize, rotation, cameraLensDirection)), 2.5, heightPointPaint);
        }

        if (lowerOuter != null && lowerOuter.isNotEmpty) {
          final p1 = lowerOuter.first;
          final p2 = lowerOuter.last;
          final p1Offset = Offset(transformX(p1.x.toDouble()), translateY(p1.y.toDouble(), size, imageSize, rotation, cameraLensDirection));
          final p2Offset = Offset(transformX(p2.x.toDouble()), translateY(p2.y.toDouble(), size, imageSize, rotation, cameraLensDirection));
          canvas.drawCircle(p1Offset, 4.0, widthPointPaint);
          canvas.drawCircle(p2Offset, 4.0, widthPointPaint);
          canvas.drawLine(p1Offset, p2Offset, linePaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(FaceDetectorPainter oldDelegate) {
    return oldDelegate.isAlerting != isAlerting || oldDelegate.faces != faces || oldDelegate.meshes != meshes;
  }
}

// import 'dart:math';
// import 'package:camera/camera.dart';
// import 'package:flutter/material.dart';
// import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
// import 'coordinates_translator.dart';
//
// class FaceDetectorPainter extends CustomPainter {
//   FaceDetectorPainter(
//       this.faces,
//       this.imageSize,
//       this.rotation,
//       this.cameraLensDirection,
//       this.isAlerting,
//       );
//
//   final List<Face> faces;
//   final Size imageSize;
//   final InputImageRotation rotation;
//   final CameraLensDirection cameraLensDirection;
//   final bool isAlerting;
//
//   @override
//   void paint(Canvas canvas, Size size) {
//     final Paint paint = Paint()
//       ..style = PaintingStyle.stroke
//       ..strokeWidth = 2.0
//       ..color = isAlerting ? Colors.red : Colors.greenAccent;
//
//     // Paint for the height points (Yellow) - INNER Lips
//     final Paint heightPointPaint = Paint()
//       ..style = PaintingStyle.fill
//       ..color = Colors.yellow;
//
//     // Paint for the width points (Cyan) - Corners
//     final Paint widthPointPaint = Paint()
//       ..style = PaintingStyle.fill
//       ..color = Colors.cyanAccent;
//
//     // Paint for Eye EAR points (Green)
//     final Paint eyePointPaint = Paint()
//       ..style = PaintingStyle.fill
//       ..color = Colors.green;
//
//     // Paint for connecting lines
//     final Paint linePaint = Paint()
//       ..style = PaintingStyle.stroke
//       ..strokeWidth = 1.0
//       ..color = Colors.cyanAccent.withOpacity(0.5);
//
//     // Helper to mirror the X-coordinate for front camera
//     double transformX(double x) {
//       double tx = translateX(x, size, imageSize, rotation, cameraLensDirection);
//       if (cameraLensDirection == CameraLensDirection.front) {
//         return size.width - tx;
//       }
//       return tx;
//     }
//
//     for (final Face face in faces) {
//       // Calculate bounding box using the mirrored X transform
//       final left = transformX(face.boundingBox.left);
//       final top = translateY(face.boundingBox.top, size, imageSize, rotation, cameraLensDirection);
//       final right = transformX(face.boundingBox.right);
//       final bottom = translateY(face.boundingBox.bottom, size, imageSize, rotation, cameraLensDirection);
//
//       // 1. Draw bounding box
//       canvas.drawRect(
//           Rect.fromLTRB(
//               left < right ? left : right,
//               top,
//               left < right ? right : left,
//               bottom
//           ),
//           paint
//       );
//
//       // 2. Draw Eye Contours (Used for EAR)
//       void paintContour(FaceContourType type) {
//         final contour = face.contours[type];
//         if (contour?.points != null) {
//           for (final point in contour!.points) {
//             canvas.drawCircle(
//               Offset(
//                 transformX(point.x.toDouble()),
//                 translateY(point.y.toDouble(), size, imageSize, rotation, cameraLensDirection),
//               ),
//               2.0, // Small green dot
//               eyePointPaint,
//             );
//           }
//         }
//       }
//
//       paintContour(FaceContourType.leftEye);
//       paintContour(FaceContourType.rightEye);
//
//       // 3. Draw Standard Landmarks (Nose)
//       final nose = face.landmarks[FaceLandmarkType.noseBase];
//       if (nose?.position != null) {
//         canvas.drawCircle(
//           Offset(
//             transformX(nose!.position.x.toDouble()),
//             translateY(nose.position.y.toDouble(), size, imageSize, rotation, cameraLensDirection),
//           ),
//           3,
//           paint,
//         );
//       }
//
//       // 4. Draw MAR Calculation Points (Strictly INNER Lips)
//       final upperInner = face.contours[FaceContourType.upperLipBottom]?.points;
//       final lowerInner = face.contours[FaceContourType.lowerLipTop]?.points;
//
//       if (upperInner != null && lowerInner != null && upperInner.isNotEmpty && lowerInner.isNotEmpty) {
//         // --- A. Height Points (Yellow) ---
//         int centerU = upperInner.length ~/ 2;
//         int centerL = lowerInner.length ~/ 2;
//
//         List<Point<int>> heightPoints = [];
//
//         // Get 3 central points from upper inner lip
//         if (centerU >= 1 && centerU < upperInner.length - 1) {
//           heightPoints.addAll([upperInner[centerU - 1], upperInner[centerU], upperInner[centerU + 1]]);
//         }
//
//         // Get 3 central points from lower inner lip
//         if (centerL >= 1 && centerL < lowerInner.length - 1) {
//           heightPoints.addAll([lowerInner[centerL - 1], lowerInner[centerL], lowerInner[centerL + 1]]);
//         }
//
//         for (var point in heightPoints) {
//           canvas.drawCircle(
//             Offset(
//               transformX(point.x.toDouble()),
//               translateY(point.y.toDouble(), size, imageSize, rotation, cameraLensDirection),
//             ),
//             2.5, // Yellow dots
//             heightPointPaint,
//           );
//         }
//
//         // --- B. Width Points (Cyan) ---
//         // Use the corners of the INNER lower lip to match the visual style
//         // Or Outer, but keeping consistent with what we had
//         final p1 = lowerInner.first;
//         final p2 = lowerInner.last;
//
//         final p1Offset = Offset(
//             transformX(p1.x.toDouble()),
//             translateY(p1.y.toDouble(), size, imageSize, rotation, cameraLensDirection)
//         );
//         final p2Offset = Offset(
//             transformX(p2.x.toDouble()),
//             translateY(p2.y.toDouble(), size, imageSize, rotation, cameraLensDirection)
//         );
//
//         canvas.drawCircle(p1Offset, 4.0, widthPointPaint);
//         canvas.drawCircle(p2Offset, 4.0, widthPointPaint);
//         canvas.drawLine(p1Offset, p2Offset, linePaint);
//       }
//     }
//   }
//
//   @override
//   bool shouldRepaint(FaceDetectorPainter oldDelegate) {
//     return oldDelegate.isAlerting != isAlerting || oldDelegate.faces != faces;
//   }
// }