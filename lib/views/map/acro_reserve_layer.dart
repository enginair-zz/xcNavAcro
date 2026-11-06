import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'package:xcnav/models/acro.dart';
import 'package:xcnav/models/glide_range.dart';
import 'package:xcnav/providers/my_telemetry.dart';
import 'package:xcnav/services/acro_service.dart';
import 'package:xcnav/settings_service.dart';
import 'package:xcnav/views/map/glide_range_layer.dart';

const int _fillAlpha = 90;
const int _edgeAlpha = 230;

/// Reserve color for a landing, by which reserve it is.
Color reserveColor(int reserve) =>
    reserve == 0 ? settingsMgr.acroReserve1Color.value : settingsMgr.acroReserve2Color.value;

/// RGBA pixels, one per grid cell, in one solid [color]: an even see-through fill with a stronger edge.
Uint8List solidZonePixels(GlideRange zone, Color color) {
  final n = zone.grid.size;
  final dist = glideEdgeDistance(zone);
  final pixels = Uint8List(n * n * 4);
  for (int i = 0; i < n * n; i++) {
    final d = dist[i];
    if (d == 0) continue;
    final alpha = d <= 1 ? _edgeAlpha : _fillAlpha;
    // Raw pixels are premultiplied
    pixels[i * 4] = (color.r * alpha).round();
    pixels[i * 4 + 1] = (color.g * alpha).round();
    pixels[i * 4 + 2] = (color.b * alpha).round();
    pixels[i * 4 + 3] = alpha;
  }
  return pixels;
}

/// Where each reserve would land if thrown between now and the hard deck, in that reserve's color.
///
/// Each reserve's whole range is one band. The lowest third of the run is drawn again on top, so it's more solid:
/// that's where landing near the "Acro" waypoint matters most, since higher throws leave time to steer the reserve.
class AcroReserveLayer extends StatefulWidget {
  const AcroReserveLayer({super.key});

  @override
  State<AcroReserveLayer> createState() => _AcroReserveLayerState();
}

class _ZoneImage {
  final ui.Image image;
  final LatLngBounds bounds;

  _ZoneImage(this.image, this.bounds);
}

class _AcroReserveLayerState extends State<AcroReserveLayer> {
  /// Bottom to top
  List<_ZoneImage> images = [];
  ReservePrediction? drawn;

  @override
  void initState() {
    super.initState();
    acroService.addListener(onPrediction);
    settingsMgr.acroReserve1Color.listenable.addListener(onColor);
    settingsMgr.acroReserve2Color.listenable.addListener(onColor);
    onPrediction();
  }

  @override
  void dispose() {
    acroService.removeListener(onPrediction);
    settingsMgr.acroReserve1Color.listenable.removeListener(onColor);
    settingsMgr.acroReserve2Color.listenable.removeListener(onColor);
    for (final each in images) {
      each.image.dispose();
    }
    super.dispose();
  }

  /// Redraw the current zones in the new colors.
  void onColor() {
    drawn = null;
    onPrediction();
  }

  void onPrediction() {
    final prediction = acroService.prediction;
    if (prediction == drawn) return;
    drawn = prediction;
    if (prediction == null) {
      setImages([]);
      return;
    }
    // Whole range and lower third, per reserve
    GlideRange? zoneOf(Iterable<ReserveLanding> landings, int reserve) {
      final mine = landings.where((l) => l.reserve == reserve).toList();
      return mine.isEmpty ? null : reserveZoneRange(mine);
    }

    final all = {
      for (final r in [0, 1]) r: zoneOf(prediction.landings, r)
    };
    final lower = {
      for (final r in [0, 1]) r: zoneOf(prediction.lowerThird, r)
    };

    // Reserve 1 is cut out wherever it overlaps reserve 2, so the two never cover each other
    final second = all[1];
    if (second != null) {
      if (all[0] != null) all[0] = subtractZone(all[0]!, second);
      if (lower[0] != null) lower[0] = subtractZone(lower[0]!, second);
    }

    final layers = <Future<_ZoneImage?>>[];
    for (final reserve in [1, 0]) {
      final color = reserveColor(reserve);
      layers.add(render(all[reserve], color));
      layers.add(render(lower[reserve], color));
    }
    Future.wait(layers).then((rendered) {
      final done = rendered.nonNulls.toList();
      if (!mounted || drawn != prediction) {
        for (final each in done) {
          each.image.dispose();
        }
        return;
      }
      setImages(done);
    });
  }

  Future<_ZoneImage?> render(GlideRange? zone, Color color) {
    if (zone == null) return Future.value(null);
    final n = zone.grid.size;
    final done = Completer<_ZoneImage?>();
    ui.decodeImageFromPixels(solidZonePixels(zone, color), n, n, ui.PixelFormat.rgba8888,
        (decoded) => done.complete(_ZoneImage(decoded, zone.grid.bounds)));
    return done.future;
  }

  void setImages(List<_ZoneImage> newImages) {
    if (!mounted) {
      for (final each in newImages) {
        each.image.dispose();
      }
      return;
    }
    final old = images;
    setState(() => images = newImages);
    for (final each in old) {
      each.image.dispose();
    }
  }

  Widget imageLayer(MapCamera camera, _ZoneImage zone) {
    final rect = Rect.fromPoints(
      camera.getOffsetFromOrigin(zone.bounds.northWest),
      camera.getOffsetFromOrigin(zone.bounds.southEast),
    );
    return Positioned.fromRect(
      rect: rect,
      child: RawImage(image: zone.image, fit: BoxFit.fill, filterQuality: FilterQuality.low),
    );
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final startAt = drawn?.startAt;
    final me = myTelemetry.geo?.latlng;
    final color = settingsMgr.acroReserve1Color.value;
    final textColor = color.computeLuminance() > 0.4 ? Colors.black : Colors.white;
    return Stack(fit: StackFit.expand, children: [
      if (images.isNotEmpty)
        MobileLayerTransformer(
          child: ClipRect(
            child: Stack(children: images.map((each) => imageLayer(camera, each)).toList()),
          ),
        ),

      // Where to start the run so the lower third lands on the waypoint
      if (startAt != null && me != null)
        PolylineLayer(polylines: [
          Polyline(
              points: [me, startAt],
              color: color,
              strokeWidth: 4,
              borderColor: Colors.black,
              borderStrokeWidth: 1.5,
              pattern: StrokePattern.dashed(segments: const [14, 8])),
        ]),
      if (startAt != null)
        MarkerLayer(markers: [
          Marker(
              point: startAt,
              width: 110,
              height: 88,
              rotate: true,
              // Target centered on the point (and the end of the dashed line), label hanging below it
              child: Stack(alignment: Alignment.center, children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black)]),
                  child: Icon(Icons.gps_fixed, size: 18, color: textColor),
                ),
                Positioned(
                  top: 44 + 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.black, width: 1.5)),
                    child: Text("ACRO START",
                        style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w900)),
                  ),
                ),
              ])),
        ]),
    ]);
  }
}
