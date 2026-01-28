import 'package:flutter/material.dart';
import '../data/calibration_service.dart';
import 'calibration_view.dart';

class ProfileView extends StatefulWidget {
  const ProfileView({super.key});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  final CalibrationService _calibrationService = CalibrationService();

  bool _isLoading = true;
  double? _earThreshold;
  double? _perclosBaseline;
  double? _marThreshold; // New Variable
  String _statusMessage = "Loading...";

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    final baselines = await _calibrationService.getBaselines();
    setState(() {
      _earThreshold = baselines['threshold'];
      _perclosBaseline = baselines['perclos'];
      _marThreshold = baselines['mar']; // Load MAR
      _isLoading = false;

      if (_earThreshold == null || _earThreshold == 0.0) {
        _statusMessage = "Not Calibrated Yet";
      } else {
        _statusMessage = "Calibrated Active";
      }
    });
  }

  // Helper to safely navigate and reload
  Future<void> _navigateToCalibration() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CalibrationView()),
    );
    _loadProfileData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Driver Profile"),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 1. User Avatar Section
            const CircleAvatar(
              radius: 50,
              backgroundColor: Colors.blueAccent,
              child: Icon(Icons.person, size: 60, color: Colors.white),
            ),
            const SizedBox(height: 16),
            const Text(
              "Current Driver",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Text(
              _statusMessage,
              style: TextStyle(
                fontSize: 16,
                color: _earThreshold != null && _earThreshold! > 0 ? Colors.green : Colors.grey,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 32),

            // 2. Statistics Card
            _buildStatCard(),

            const SizedBox(height: 30),

            // 3. Action Buttons
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _navigateToCalibration,
                icon: const Icon(Icons.settings_accessibility),
                label: const Text("Recalibrate System"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "Recalibrate if you change your driving position, wear new glasses, or drive at night.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text("Active Thresholds", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 30),

            _buildRow(
              icon: Icons.remove_red_eye,
              label: "EAR Threshold",
              value: _earThreshold?.toStringAsFixed(3) ?? "N/A",
              desc: "Eyes considered closed below this ratio.",
            ),
            const SizedBox(height: 20),
            _buildRow(
              icon: Icons.face, // Icon for mouth/face
              label: "Yawn Threshold",
              value: _marThreshold != null && _marThreshold! > 0
                  ? _marThreshold!.toStringAsFixed(3)
                  : "0.500 (Default)",
              desc: "Mouth considered yawning above this ratio.",
            ),
            const SizedBox(height: 20),
            _buildRow(
              icon: Icons.timer,
              label: "Baseline PERCLOS",
              value: _perclosBaseline != null ? "${(_perclosBaseline! * 100).toStringAsFixed(1)}%" : "5.0%",
              desc: "Your normal blinking rate.",
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow({required IconData icon, required String label, required String value, required String desc}) {
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
                  Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, fontFamily: 'Monospace')),
                ],
              ),
              const SizedBox(height: 4),
              Text(desc, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}