import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// "3:42:07 PM", ticking every second. Only this text redraws, not the screen around it.
class LiveClock extends StatefulWidget {
  final TextStyle? style;
  const LiveClock({super.key, this.style});

  @override
  State<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<LiveClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(DateFormat('h:mm:ss a').format(DateTime.now()), style: widget.style);
}
