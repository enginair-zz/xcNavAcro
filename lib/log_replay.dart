import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:xcnav/models/acro.dart';
import 'package:xcnav/models/flight_log.dart';
import 'package:xcnav/models/waypoint.dart';
import 'package:xcnav/providers/active_plan.dart';
import 'package:xcnav/providers/my_telemetry.dart';
import 'package:xcnav/util.dart';

/// Dev tool: fly a saved xcNav log through the live app, sped up, to watch acro mode (map overlay, wind table).
///
/// Start the app with `--dart-define=REPLAY_LOG=<log path on the device>`, and optionally
/// `--dart-define=REPLAY_SPEED=<times real time>` (default 10). GPS fixes and g samples keep the log's own spacing, so
/// everything that looks at time (wind fits, acro runs) sees the flight as it was flown; only the playback is faster.
const replayLogPath = String.fromEnvironment("REPLAY_LOG");
const replaySpeed = int.fromEnvironment("REPLAY_SPEED", defaultValue: 10);

Timer? _replayTimer;

/// Start replaying [replayLogPath], if one was given at build time.
Future<void> startLogReplay(BuildContext context, MyTelemetry telemetry) async {
  if (replayLogPath.isEmpty || _replayTimer != null) return;
  // Let the app finish starting (plan loaded, map up)
  await Future.delayed(const Duration(seconds: 8));
  if (!context.mounted) return;
  final log = FlightLog.fromJson(replayLogPath, jsonDecode(await File(replayLogPath).readAsString()));
  if (log.samples.isEmpty || !context.mounted) return;
  debugPrint("--- Replaying $replayLogPath at ${replaySpeed}x ---");

  // Phone sensors off; the log is the only source
  telemetry.setStandby(true);
  telemetry.baro = null;

  final plan = Provider.of<ActivePlan>(context, listen: false);
  if (findAcroWaypoint(plan.waypoints.values) == null) {
    final center = _acroCenter(log);
    if (center != null) plan.updateWaypoint(Waypoint(name: acroWaypointName, latlngs: [center]));
  }

  // Log times move to now, so nothing looks stale
  final first = log.samples.first.time;
  final offset = DateTime.now().millisecondsSinceEpoch - first;
  final realStart = DateTime.now().millisecondsSinceEpoch;
  int logNow() => first + (DateTime.now().millisecondsSinceEpoch - realStart) * replaySpeed;

  final g = log.gForceSamples;
  int si = 0, gi = 0, gTime = g.isEmpty ? 0 : g.first.time;
  withClock(Clock(() => DateTime.fromMillisecondsSinceEpoch(logNow() + offset)), () {
    _replayTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      final now = logNow();
      // G on a 100 ms grid, like the live accelerometer record
      telemetry.listenIMU?.cancel();
      telemetry.listenIMU = null;
      while (g.length > 1 && gTime <= now && gTime <= g.last.time) {
        while (gi + 1 < g.length - 1 && g[gi + 1].time <= gTime) {
          gi++;
        }
        final a = g[gi], b = g[gi + 1];
        final value = b.time > a.time ? a.value + (b.value - a.value) * (gTime - a.time) / (b.time - a.time) : a.value;
        telemetry.gForceRecord.add(TimestampValue<double>(gTime + offset, value));
        gTime += 100;
      }
      while (si < log.samples.length && log.samples[si].time <= now) {
        final s = log.samples[si++];
        telemetry.handleGeoUpdate(
            context,
            Position(
              latitude: s.lat,
              longitude: s.lng,
              altitude: s.alt,
              speed: s.spd,
              timestamp: DateTime.fromMillisecondsSinceEpoch(s.time + offset),
              heading: s.hdg * 180 / 3.1415926,
              accuracy: 5,
              speedAccuracy: 0,
              altitudeAccuracy: 0,
              headingAccuracy: 0,
            ),
            bypassRecording: true);
      }
      if (si >= log.samples.length) {
        debugPrint("--- Replay finished ---");
        timer.cancel();
      }
    });
  });
}

/// Middle of where the log came down fastest (over 800 ft/min): where the acro was.
LatLng? _acroCenter(FlightLog log) {
  double lat = 0, lng = 0;
  int n = 0;
  final s = log.samples;
  for (int i = 1; i < s.length; i++) {
    final dt = (s[i].time - s[i - 1].time) / 1000;
    if (dt > 0 && (s[i - 1].alt - s[i].alt) / dt > 4.064) {
      lat += s[i].lat;
      lng += s[i].lng;
      n++;
    }
  }
  return n == 0 ? null : LatLng(lat / n, lng / n);
}
