import 'dart:ui';
import 'package:flutter/material.dart';

class DetectorStatusPanel extends StatelessWidget {
  final String status;
  final double score;
  final bool isMonitoring;
  final int alertLevel;
  final double debugEar;
  final double baselineEar;
  final double debugMar;
  final double baselineMar;
  final double debugPitch;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onDismiss;

  const DetectorStatusPanel({
    super.key,
    required this.status,
    required this.score,
    required this.isMonitoring,
    required this.alertLevel,
    required this.debugEar,
    required this.baselineEar,
    required this.debugMar,
    required this.baselineMar,
    required this.debugPitch,
    required this.onStart,
    required this.onStop,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    Color bgColor = Colors.black;
    if (alertLevel == 2) bgColor = Colors.red;
    if (alertLevel == 1) bgColor = Colors.orange;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          decoration: BoxDecoration(
            color: bgColor.withOpacity(alertLevel > 0 ? 0.6 : 0.4),
            borderRadius: BorderRadius.circular(24),
            border:
                Border.all(color: Colors.white.withOpacity(0.15), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 10,
                spreadRadius: 2,
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                status.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold),
              ),
              if (isMonitoring)
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    "Risk Score: ${score.toInt()}",
                    style: TextStyle(
                        color:
                            score > 75 ? Colors.redAccent : Colors.cyanAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMetric("EAR",
                      "${debugEar.toStringAsFixed(2)} / ${baselineEar.toStringAsFixed(2)}"),
                  _buildMetric("MAR",
                      "${debugMar.toStringAsFixed(2)} / ${baselineMar.toStringAsFixed(2)}"),
                  _buildMetric("PITCH", "${debugPitch.toInt()}°"),
                ],
              ),
              const SizedBox(height: 20),
              if (alertLevel > 0)
                _buildButton(
                  onPressed: onDismiss,
                  icon: Icons.notifications_off,
                  label: "DISMISS & RESET",
                  bgColor: Colors.white,
                  fgColor: alertLevel == 2 ? Colors.red : Colors.orange,
                )
              else if (!isMonitoring)
                _buildButton(
                  onPressed: onStart,
                  icon: Icons.play_circle_filled,
                  label: "START MONITORING",
                  bgColor: Colors.green,
                  fgColor: Colors.white,
                )
              else
                _buildButton(
                  onPressed: onStop,
                  icon: Icons.stop_circle,
                  label: "STOP MONITORING",
                  bgColor: Colors.white12,
                  fgColor: Colors.white,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetric(String label, String value) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 10)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                color: Colors.white, fontSize: 16, fontFamily: "Monospace")),
      ],
    );
  }

  Widget _buildButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color bgColor,
    required Color fgColor,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: bgColor,
          foregroundColor: fgColor,
          elevation: alertLevel > 0 ? 8 : 0,
          shadowColor: bgColor.withOpacity(0.5),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        ),
      ),
    );
  }
}
