import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xcnav/audio_cue_service.dart';
import 'package:xcnav/dem_service.dart';
import 'package:xcnav/models/acro.dart';
import 'package:xcnav/models/geo.dart';
import 'package:xcnav/models/waypoint.dart';
import 'package:xcnav/models/wind_table.dart';
import 'package:xcnav/providers/active_plan.dart';
import 'package:xcnav/providers/wind.dart';
import 'package:xcnav/settings_service.dart';
import 'package:xcnav/tts_service.dart';
import 'package:xcnav/units.dart';
import 'package:xcnav/util.dart';

typedef GroundAt = double? Function(LatLng latlng);

double? _sampleGround(LatLng latlng) => sampleDem(latlng, true);

/// What the acro heights are measured from.
enum AcroGroundRef {
  /// Ground under the "Acro" waypoint
  waypoint,

  /// Launch altitude
  launch,

  /// Ground under the pilot
  here,
}

/// Acro mode: wind table, acro runs and the learned descent rate, and reserve landing predictions.
///
/// Fed every GPS fix while acro mode is on.
class AcroService with ChangeNotifier {
  WindTable table = WindTable();
  final QuarterTurnWindFitter fitter = QuarterTurnWindFitter();
  final AcroRunDetector runDetector = AcroRunDetector();

  /// Why the wind table isn't recording right now. Null while recording.
  String? tableGate = "No GPS yet";
  WindEstimate? lastEstimate;
  AcroRun? lastRun;
  ReservePrediction? prediction;
  Waypoint? acroWaypoint;

  /// Ground the heights are measured from (meters MSL)
  double? groundRef;
  AcroGroundRef? groundRefSource;

  /// Pilot's height above [groundRef] (meters)
  double? height;

  final GroundAt groundAt;
  AcroService({this.groundAt = _sampleGround});

  int _lastGTime = 0;
  bool _loaded = false;
  Timer? _saveTimer;
  static const _prefsKey = "acro.windTable";

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final loaded = WindTable.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        // Keep anything recorded before the load finished
        loaded.bands.addAll(table.bands);
        table = loaded;
        table.expire(DateTime.now().millisecondsSinceEpoch);
        notifyListeners();
      }
    } catch (err, trace) {
      debugPrint("Failed to load wind table: $err\n$trace");
    }
  }

  void _scheduleSave() {
    _saveTimer ??= Timer(const Duration(seconds: 10), () async {
      _saveTimer = null;
      final prefs = await SharedPreferences.getInstance();
      prefs.setString(_prefsKey, jsonEncode(table.toJson()));
    });
  }

  void clearTable() {
    table.clear();
    fitter.reset();
    lastEstimate = null;
    _scheduleSave();
    notifyListeners();
  }

  /// Read the app state and settings, then [update]. Learns from finished runs and calls out the hard deck.
  void handleGeo(BuildContext context, Geo geo, Geo? prev,
      {required double vario, required List<TimestampValue<double>> gForce, double? launchAlt}) {
    load();
    final plan = Provider.of<ActivePlan>(context, listen: false);
    final wind = Provider.of<Wind>(context, listen: false).result;
    final hardDeck = settingsMgr.acroHardDeck.value;
    final run = update(geo, prev,
        vario: vario,
        gForce: gForce,
        launchAlt: launchAlt,
        waypoints: plan.waypoints.values,
        currentWind:
            wind == null ? null : (east: wind.windSpd * sin(wind.windHdg), north: wind.windSpd * cos(wind.windHdg)),
        hardDeck: hardDeck,
        acroRate: settingsMgr.acroDescentRate.value,
        reserveRates: [settingsMgr.acroReserve1Rate.value, settingsMgr.acroReserve2Rate.value]);

    if (run != null) {
      if (run.accepted) {
        final (rate, runs) =
            learnDescentRate(settingsMgr.acroDescentRate.value, settingsMgr.acroDescentRuns.value, run.descentRate);
        settingsMgr.acroDescentRate.value = rate;
        settingsMgr.acroDescentRuns.value = runs;
      }
      if (run.endedAtHardDeck) {
        audioCueService.ttsService.speak(AudioMessage(
            "Hard deck reached, ${unitConverters[UnitType.distFine]!(hardDeck).round()}",
            priority: 0,
            expires: DateTime.now().add(const Duration(seconds: 5))));
      }
    }
  }

  /// Process a GPS fix. Returns a run when one just finished.
  ///
  /// [currentWind] is the live wind solution, used while the wind table is empty.
  AcroRun? update(Geo geo, Geo? prev,
      {required double vario,
      required List<TimestampValue<double>> gForce,
      double? launchAlt,
      required Iterable<Waypoint> waypoints,
      WindVector? currentWind,
      required double hardDeck,
      required double acroRate,
      required List<double> reserveRates}) {
    final now = geo.time;

    // --- Height reference
    acroWaypoint = findAcroWaypoint(waypoints);
    final wpGround = acroWaypoint == null ? null : groundAt(acroWaypoint!.latlng.first);
    if (wpGround != null) {
      groundRef = wpGround;
      groundRefSource = AcroGroundRef.waypoint;
    } else if (launchAlt != null) {
      groundRef = launchAlt;
      groundRefSource = AcroGroundRef.launch;
    } else {
      groundRef = geo.ground;
      groundRefSource = geo.ground == null ? null : AcroGroundRef.here;
    }
    height = groundRef == null ? null : geo.alt - groundRef!;

    // --- G-load
    double? maxG;
    for (int i = gForce.length - 1; i >= 0 && gForce[i].time > now - 2000; i--) {
      maxG = max(maxG ?? 0, gForce[i].value);
    }
    final firstNew = gForce.indexWhere((g) => g.time > _lastGTime);
    if (firstNew >= 0) {
      for (int i = firstNew; i < gForce.length; i++) {
        runDetector.addG(gForce[i].time, gForce[i].value);
      }
      _lastGTime = gForce.last.time;
    }

    // --- Wind table
    final varioNow = prev != null && geo.time > prev.time ? (geo.alt - prev.alt) / (geo.time - prev.time) * 1000 : null;
    tableGate = windTableGate(height: height, vario: vario, varioNow: varioNow, maxG: maxG);
    if (tableGate == null) {
      final est = fitter.add(time: now, alt: geo.alt, hdg: geo.hdg, spd: geo.spd);
      if (est != null) {
        table.add(est);
        lastEstimate = est;
        _scheduleSave();
      }
    } else {
      fitter.reset();
    }
    if (table.expire(now)) _scheduleSave();

    // --- Acro runs
    runDetector.addAlt(now, geo.alt);
    final run = runDetector.update(now, height: height, hardDeck: hardDeck);
    if (run != null) lastRun = run;

    // --- Reserve landings
    prediction = null;
    final ref = groundRef;
    if (ref != null && height != null && height! > 0) {
      WindVector? windAt(double h) => table.windAt(ref + h) ?? currentWind;
      prediction = predictReserveLandings(
          from: geo.latlng,
          height: height!,
          hardDeck: hardDeck,
          acroRate: acroRate,
          reserveRates: reserveRates,
          windAt: windAt,
          target: acroWaypoint?.latlng.first);
    }

    notifyListeners();
    return run;
  }
}

final acroService = AcroService();
