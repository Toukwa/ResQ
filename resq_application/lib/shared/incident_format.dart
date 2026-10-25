import '../services/theme_service.dart';
import 'package:flutter/material.dart';
import 'map_pin.dart';
import 'status_style.dart';
import '../services/incident_data.dart';

String formatTimeAgo(DateTime timestamp) {
  final now = DateTime.now();
  final difference = now.difference(timestamp);

  if (difference.inMinutes < 1) {
    return 'Just now';
  } else if (difference.inMinutes < 60) {
    return '${difference.inMinutes} min ago';
  } else if (difference.inHours < 24) {
    return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
  } else {
    return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
  }
}

bool toBool(dynamic val, {bool defaultValue = false}) {
  if (val == null) return defaultValue;
  if (val is bool) return val;
  if (val is int) return val == 1;
  if (val is String) return val == '1' || val.toLowerCase() == 'true';
  return defaultValue;
}

IconData logIconData(String iconName) {
  switch (iconName) {
    case 'local_shipping_outlined':
      return Icons.local_shipping_outlined;
    case 'warning_amber_rounded':
      return Icons.warning_amber_rounded;
    case 'location_on_rounded':
      return Icons.location_on_rounded;
    case 'check_circle_rounded':
      return Icons.check_circle_rounded;
    case 'sync_rounded':
      return Icons.sync_rounded;
    default:
      return Icons.notifications_none;
  }
}

Color departmentBadgeColor(String dept) {
  final d = dept.toUpperCase();
  if (d.contains('BFP') || d.contains('FIRE')) return const Color(0xFFDC2626);
  if (d.contains('PNP') || d.contains('POLICE')) return const Color(0xFF2563EB);
  if (d.contains('CDRRMO') || d.contains('RESCUE') || d.contains('MEDICAL')) return const Color(0xFF059669);
  return const Color(0xFFEA580C);
}

/// The agency symbols, as on the phone app's report cards. Used everywhere an
/// incident or agency is shown (phone and staff screens) so they always match.
({IconData icon, Color color, Color bgColor}) agencySymbol(String? agency) => switch (agency) {
      'BFP' => (icon: Icons.local_fire_department_outlined, color: const Color(0xFFDC2626), bgColor: themedBg(const Color(0xFFFEE2E2))),
      'PNP' => (icon: Icons.local_police_outlined, color: const Color(0xFF1E40AF), bgColor: themedBg(const Color(0xFFDBEAFE))),
      'CDRRMO' => (icon: Icons.health_and_safety_outlined, color: const Color(0xFF16A34A), bgColor: themedBg(const Color(0xFFDCFCE7))),
      // General Emergency: the EOC decides who responds
      'EOC' => (icon: Icons.support_agent_rounded, color: const Color(0xFFFF6B00), bgColor: themedBg(const Color(0xFFFFEDD5))),
      // Several agencies on one report
      _ => (icon: Icons.priority_high_rounded, color: const Color(0xFFFF6B00), bgColor: themedBg(const Color(0xFFFFEDD5))),
    };

/// Incident severity, set by the EOC (Super Admin) before assigning: most to least serious.
/// A new report has none until the EOC rates it.
const severityLevels = ['Immediate', 'Emergent', 'Urgent', 'Semi-urgent', 'Non-urgent'];

/// Badge text and colours for a severity (or "Not rated").
({String label, Color color, Color bgColor}) severityStyle(String? severity) => switch (severity) {
      'Immediate' => (label: 'Immediate', color: const Color(0xFFDC2626), bgColor: themedBg(const Color(0xFFFEE2E2))),
      'Emergent' => (label: 'Emergent', color: const Color(0xFFEA580C), bgColor: themedBg(const Color(0xFFFFEDD5))),
      'Urgent' => (label: 'Urgent', color: const Color(0xFFD97706), bgColor: themedBg(const Color(0xFFFEF3C7))),
      'Semi-urgent' => (label: 'Semi-urgent', color: const Color(0xFF2563EB), bgColor: themedBg(const Color(0xFFDBEAFE))),
      'Non-urgent' => (label: 'Non-urgent', color: const Color(0xFF16A34A), bgColor: themedBg(const Color(0xFFDCFCE7))),
      _ => (label: 'Not rated', color: const Color(0xFF64748B), bgColor: themedBg(const Color(0xFFF1F5F9))),
    };

/// Icon and colours for an incident, from the agencies it is sent to (not words in its name).
Map<String, dynamic> emergencyTypeStyle(dynamic incidentInput) {
  String rawType = '';
  List<String> depts = const [];
  if (incidentInput is Map) {
    rawType = (incidentInput['Incident_Type'] ?? incidentInput['type'] ?? incidentInput['incType'] ?? '').toString();
    final status = incidentInput['dept_status'];
    if (status is Map && status.isNotEmpty) depts = [for (final k in status.keys) '$k'];
  } else {
    rawType = (incidentInput ?? '').toString();
  }
  if (depts.isEmpty) depts = IncidentData.involvedDepartments(rawType);

  final agency = depts.length == 1 ? depts.first : (depts.isEmpty ? 'EOC' : 'MULTI');
  final look = agencySymbol(agency);
  return {'icon': look.icon, 'color': look.color, 'bgColor': look.bgColor, 'agency': agency};
}

/// A vehicle: its agency's colour with a vehicle symbol (filled pin).
Map<String, dynamic> vehicleMarkerConfig(dynamic vehicleInput) {
  String deptStr = '';
  if (vehicleInput is Map) {
    deptStr = (vehicleInput['deptName'] ?? vehicleInput['Department_Name'] ?? vehicleInput['agency'] ?? vehicleInput['department'] ?? vehicleInput['dept_ID'] ?? vehicleInput['dept'] ?? '').toString().toUpperCase();
  } else {
    deptStr = (vehicleInput ?? '').toString().toUpperCase();
  }
  String? agency;
  if (deptStr.contains('BFP') || deptStr.contains('FIRE') || deptStr == '2') agency = 'BFP';
  if (deptStr.contains('PNP') || deptStr.contains('POLICE') || deptStr == '1') agency = 'PNP';
  if (deptStr.contains('CDRRMO') || deptStr.contains('RESCUE') || deptStr.contains('MEDICAL') || deptStr == '3') agency = 'CDRRMO';
  if (agency == null) return {'icon': Icons.directions_car_rounded, 'color': const Color(0xFF64748B)};
  // Agency colour, but a vehicle symbol, so units never look like incidents
  const vehicleIcon = {
    'BFP': Icons.fire_truck_rounded,
    'PNP': Icons.local_police_rounded,
    'CDRRMO': Icons.airport_shuttle_rounded, // ambulance van
  };
  return {'icon': vehicleIcon[agency], 'color': agencySymbol(agency).color};
}

/// Incident marker: an outline circle in the agency colour with a soft pulsing
/// halo (like the citizen's pin on the phone), so open reports draw the eye.
/// The halo stays still when the computer has animations turned off.
class IncidentRingMarker extends StatefulWidget {
  final IconData icon;
  final Color color;
  const IncidentRingMarker({super.key, required this.icon, required this.color});

  @override
  State<IncidentRingMarker> createState() => _IncidentRingMarkerState();
}

class _IncidentRingMarkerState extends State<IncidentRingMarker> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    // Same rhythm as the citizen's pin: 1.8 s out, 1.8 s back
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return SizedBox(
      width: kIncidentMarkerSize,
      height: kIncidentMarkerSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = still ? 0.5 : Curves.easeInOut.transform(_pulse.value);
              final d = kIncidentSize * (0.9 + 0.75 * t); // halo grows past the ring and back
              return Container(
                width: d,
                height: d,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.28 * (1 - t) + 0.08),
                ),
              );
            },
          ),
          MapPin(icon: widget.icon, color: widget.color, filled: false),
        ],
      ),
    );
  }
}

String formatStatus(String? rawStatus) => rawStatus == null ? 'Unknown' : reportStatusLabel(rawStatus);

