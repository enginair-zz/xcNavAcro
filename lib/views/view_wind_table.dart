import 'dart:math';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:xcnav/models/acro.dart';
import 'package:xcnav/models/wind_table.dart';
import 'package:xcnav/providers/wind.dart';
import 'package:xcnav/services/acro_service.dart';
import 'package:xcnav/settings_service.dart';
import 'package:xcnav/units.dart';

/// Wind table and acro predictions, mostly for debugging.
class ViewWindTable extends StatefulWidget {
  const ViewWindTable({super.key});

  @override
  State<ViewWindTable> createState() => _ViewWindTableState();
}

class _ViewWindTableState extends State<ViewWindTable> {
  static const _dim = TextStyle(color: Colors.grey, fontSize: 13);

  @override
  void initState() {
    super.initState();
    acroService.load();
  }

  String _dist(double meters) =>
      "${printValue(UnitType.distFine, meters, decimals: 0)} ${getUnitStr(UnitType.distFine)}";

  /// A band as "1000-1500 ft" MSL
  String _range(int band) =>
      "${printValue(UnitType.distFine, WindTable.bandBottom(band), decimals: 0)}-${_dist(WindTable.bandBottom(band + 1))}";
  String _coarse(double meters) =>
      "${printValue(UnitType.distCoarse, meters, decimals: 2)} ${getUnitStr(UnitType.distCoarse)}";
  String _speed(double mps) => "${printValue(UnitType.speed, mps, decimals: 0)} ${getUnitStr(UnitType.speed)}";
  String _vario(double mps) => "${printValue(UnitType.vario, mps, decimals: 0)} ${getUnitStr(UnitType.vario)}";

  String _age(int ms) {
    final minutes = (DateTime.now().millisecondsSinceEpoch - ms) ~/ 60000;
    return minutes < 1 ? "now" : (minutes < 60 ? "${minutes}m" : "${minutes ~/ 60}h${minutes % 60}m");
  }

  /// Distance and compass direction of an offset in meters east and north
  String _offset(WindVector m) {
    final dist = sqrt(m.east * m.east + m.north * m.north);
    const names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
    final hdg = (atan2(m.east, m.north) * 180 / pi + 360) % 360;
    return "${_coarse(dist)} ${names[((hdg + 22.5) ~/ 45) % 8]}";
  }

  Widget _card(String title, List<Widget> children, {Widget? trailing}) {
    return Card(
      color: Colors.grey.shade900,
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            if (trailing != null) trailing,
          ]),
          const SizedBox(height: 6),
          ...children,
        ]),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [Expanded(child: Text(label, style: _dim)), Text(value)]),
      );

  Widget _windArrow(double towardHdg) => Transform.rotate(
      angle: towardHdg, child: const Icon(Icons.arrow_upward, size: 18, color: Colors.lightBlueAccent));

  Widget _table(AcroService acro) {
    final ref = acro.groundRef;
    final keys = acro.table.bands.keys.toList()..sort((a, b) => b.compareTo(a));
    if (keys.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text("Empty. Fills in from GPS whenever you circle (not during acro), one band per 500 ft MSL.",
            style: _dim),
      );
    }
    final current = acro.height == null || ref == null ? null : WindTable.bandFor(acro.height! + ref);
    const header = TextStyle(color: Colors.grey, fontSize: 12);
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.9),
        1: FlexColumnWidth(1.4),
        2: FlexColumnWidth(1.1),
        3: FlexColumnWidth(1.1),
        4: FlexColumnWidth(0.6),
        5: FlexColumnWidth(0.9),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(children: [
          const Text("MSL", style: header),
          const Text("From", style: header),
          const Text("Wind", style: header),
          const Text("Air", style: header),
          const Text("Fits", style: header),
          const Text("Age", style: header),
        ]),
        // Measured layers only, highest first
        for (final key in keys)
          () {
            final band = acro.table.bands[key]!;
            final style = TextStyle(color: key == current ? Colors.amber : null);
            return TableRow(children: [
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(_range(key), style: style)),
              Row(children: [
                _windArrow(band.fromHdg + pi),
                Text(" ${(band.fromHdg * 180 / pi).round().toString().padLeft(3, "0")}°", style: style),
              ]),
              Text(_speed(band.speed), style: style),
              Text(_speed(band.airspeed), style: style),
              Text("${band.count}", style: style),
              Text(_age(band.updated), style: style),
            ]);
          }(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final liveWind = Provider.of<Wind>(context).result;
    return ListenableBuilder(
        listenable: acroService,
        builder: (context, _) {
          final acro = acroService;
          final prediction = acro.prediction;
          final wp = acro.acroWaypoint;
          final refName = switch (acro.groundRefSource) {
            AcroGroundRef.waypoint => "ground at \"${wp?.name}\"",
            AcroGroundRef.launch => "launch",
            AcroGroundRef.here => "ground below you",
            null => "unknown",
          };
          final run = acro.lastRun;
          return ListView(padding: const EdgeInsets.only(bottom: 16), children: [
            // --- Table
            _card(
                "Wind Table",
                [
                  _row("Recording", acro.tableGate == null ? "Yes" : "No: ${acro.tableGate}"),
                  _row("Turn so far",
                      "${acro.fitter.sampleCount} fixes, track swung ${(acro.fitter.span * 180 / pi).round()}°"),
                  _row("Height & hard deck from", refName),
                  if (liveWind != null)
                    _row("Live wind (xcNav)",
                        "${((liveWind.windHdg * 180 / pi + 180) % 360).round()}° at ${_speed(liveWind.windSpd)}"),
                  const Divider(),
                  _table(acro),
                ],
                trailing: IconButton(
                    tooltip: "Clear wind table",
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                              title: const Text("Clear the wind table?"),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                                TextButton(
                                    onPressed: () {
                                      acroService.clearTable();
                                      Navigator.pop(context);
                                    },
                                    child: const Text("Clear")),
                              ],
                            )))),

            // --- Reserve predictions
            _card("If You Throw Your Reserve", [
              _row("Height now", acro.height == null ? "-" : _dist(acro.height!)),
              _row("Hard deck", _dist(settingsMgr.acroHardDeck.value)),
              if (prediction == null)
                const Text("Needs wind (table or live) and a height above the ground.", style: _dim)
              else ...[
                for (final l in prediction.throwNow)
                  _row(
                      "Now, ${_vario(l.rate)} reserve",
                      wp == null
                          ? "drifts ${_offset(metersBetween(l.throwAt, l.landAt))}"
                          : _fromWp(wp.latlng.first, l)),
                for (final l in prediction.throwAtHardDeck)
                  if (l.throwHeight != prediction.landings.first.throwHeight)
                    _row(
                        "At hard deck, ${_vario(l.rate)} reserve",
                        wp == null
                            ? "drifts ${_offset(metersBetween(l.throwAt, l.landAt))}"
                            : _fromWp(wp.latlng.first, l)),
                if (wp != null) ...[
                  _row("Lower third lands", _offset(metersBetween(wp.latlng.first, prediction.lowerThirdCenter))),
                  if (prediction.startAt != null)
                    _row("Acro start point",
                        "${_offset(metersBetween(wp.latlng.first, prediction.startAt!))} of \"${wp.name}\""),
                ] else
                  const Text("Add a waypoint named \"$acroWaypointName\" to see landings relative to it.", style: _dim),
              ],
            ]),

            // --- Acro descent rate
            _card("Acro Descent", [
              _row("Average used", _vario(settingsMgr.acroDescentRate.value)),
              _row("Runs learned", "${settingsMgr.acroDescentRuns.value}"),
              _row("Run in progress",
                  acro.runDetector.running ? "Yes, ${_entryName(acro.runDetector.runEntry)} entry" : "No"),
              _row("Rotation now",
                  acro.rotationRecord.isEmpty ? "no gyro data" : "${acro.rotationRecord.last.value.round()}°/s"),
              if (run != null)
                _row("Last run",
                    "${_entryName(run.entry)}, ${_vario(run.descentRate)}, ${run.duration.inSeconds}s${run.endedAtHardDeck ? ", to hard deck" : ""}${run.accepted ? "" : " (not used)"}"),
            ]),
          ]);
        });
  }

  String _entryName(AcroEntry? entry) => switch (entry) {
        AcroEntry.stall => "stall",
        AcroEntry.sharpTurn => "sharp turn",
        AcroEntry.gLoad => "g-load",
        null => "-",
      };

  String _fromWp(LatLng wpLatLng, ReserveLanding l) => "${_offset(metersBetween(wpLatLng, l.landAt))} of Acro";
}
