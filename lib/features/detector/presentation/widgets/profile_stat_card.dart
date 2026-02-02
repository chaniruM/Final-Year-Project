import 'package:flutter/material.dart';

class ProfileStatCard extends StatelessWidget {
  final double? earThreshold;
  final double? marThreshold;
  final double? perclosBaseline;

  const ProfileStatCard({
    super.key,
    required this.earThreshold,
    required this.marThreshold,
    required this.perclosBaseline,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text("Active Thresholds",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 30),

            _buildRow(
              icon: Icons.remove_red_eye,
              label: "EAR Threshold",
              value: earThreshold?.toStringAsFixed(3) ?? "N/A",
              desc: "Eyes considered closed below this ratio.",
            ),
            const SizedBox(height: 20),
            _buildRow(
              icon: Icons.face,
              label: "Yawn Threshold",
              value: marThreshold != null && marThreshold! > 0
                  ? marThreshold!.toStringAsFixed(3)
                  : "0.500 (Default)",
              desc: "Mouth considered yawning above this ratio.",
            ),
            const SizedBox(height: 20),
            _buildRow(
              icon: Icons.timer,
              label: "Baseline PERCLOS",
              value: perclosBaseline != null
                  ? "${(perclosBaseline! * 100).toStringAsFixed(1)}%"
                  : "5.0%",
              desc: "Your normal blinking rate.",
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow({
    required IconData icon,
    required String label,
    required String value,
    required String desc,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Colors.blueAccent, size: 28),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  Text(value,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          fontFamily: 'Monospace')),
                ],
              ),
              const SizedBox(height: 4),
              Text(desc,
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}