import 'package:flutter/material.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
import 'coordinates_translator.dart';
import 'package:camera/camera.dart';

class FaceMeshPainter extends CustomPainter {
  final List<FaceMesh> meshes;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;
  final bool isAlerting;

  FaceMeshPainter(this.meshes, this.imageSize, this.rotation, this.cameraLensDirection, this.isAlerting);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint pointPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = isAlerting ? Colors.red.withOpacity(0.6) : Colors.greenAccent.withOpacity(0.4)
      ..strokeWidth = 1.0;

    final Paint linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white.withOpacity(0.2)
      ..strokeWidth = 0.5;

    for (final mesh in meshes) {
      for (final point in mesh.points) {
        final Offset offset = Offset(
          translateX(point.x, size, imageSize, rotation, cameraLensDirection),
          translateY(point.y, size, imageSize, rotation, cameraLensDirection),
        );
        // Draw tiny dots for the mesh
        canvas.drawCircle(offset, 1.0, pointPaint);
      }

      // Optionally draw triangles if needed, but points are enough for the "High Tech" look
    }
  }

  @override
  bool shouldRepaint(FaceMeshPainter oldDelegate) {
    return oldDelegate.meshes != meshes || oldDelegate.isAlerting != isAlerting;
  }
}