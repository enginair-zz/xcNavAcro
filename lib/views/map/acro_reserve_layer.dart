import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'package:xcnav/models/acro.dart';
import 'package:xcnav/providers/my_telemetry.dart';
import 'package:xcnav/services/acro_service.dart';
import 'package:xcnav/views/map/glide_range_layer.dart';

/// Same look as the glide range, different colors.
const acroZoneEdgeColor = Color(0xff00e5ff);
const acroZoneInnerColor = Color(0xff2962ff);

/// Where the reserve would land if thrown between now and the hard deck.
///
/// The whole range is one band. The lowest third of the run is drawn again on top: that's where landing near the
/// "Acro" waypoint matters most, since higher throws leave time to steer the reserve.
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
  _ZoneImage? all;
  _ZoneImage? lowerThird;
  ReservePrediction? drawn;

  @override
  void initState() {
    super.initState();
    acroService.addListener(onPrediction);
    onPrediction();
  }

  @override
  void dispose() {
    acroService.removeListener(onPrediction);
    all?.image.dispose();
    lowerThird?.image.dispose();
    super.dispose();
  }

  void onPrediction() {
    final prediction = acroService.prediction;
    if (prediction == drawn) return;
    drawn = prediction;
    if (prediction == null) {
      setImages(null, null);
      return;
    }
    Future.wait([render(prediction.landings), render(prediction.lowerThird)]).then((images) {
      if (!mounted || drawn != prediction) {
        for (final each in images) {
          each?.image.dispose();
        }
        return;
      }
      setImages(images[0], images[1]);
    });
  }

  Future<_ZoneImage?> render(List<ReserveLanding> landings) {
    if (landings.isEmpty) return Future.value(null);
    final zone = reserveZoneRange(landings);
    final n = zone.grid.size;
    final pixels = glideRangePixels(zone, edgeColor: acroZoneEdgeColor, innerColor: acroZoneInnerColor);
    final done = Completer<_ZoneImage?>();
    ui.decodeImageFromPixels(
        pixels, n, n, ui.PixelFormat.rgba8888, (decoded) => done.complete(_ZoneImage(decoded, zone.grid.bounds)));
    return done.future;
  }

  void setImages(_ZoneImage? newAll, _ZoneImage? newLowerThird) {
    if (!mounted) {
      newAll?.image.dispose();
      newLowerThird?.image.dispose();
      return;
    }
    final oldAll = all;
    final oldLowerThird = lowerThird;
    setState(() {
      all = newAll;
      lowerThird = newLowerThird;
    });
    oldAll?.image.dispose();
    oldLowerThird?.image.dispose();
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
    return Stack(fit: StackFit.expand, children: [
      if (all != null || lowerThird != null)
        MobileLayerTransformer(
          child: ClipRect(
            child: Stack(children: [
              if (all != null) imageLayer(camera, all!),
              if (lowerThird != null) imageLayer(camera, lowerThird!),
            ]),
          ),
        ),

      // Where to start the run so the lower third lands on the waypoint
      if (startAt != null && me != null)
        PolylineLayer(polylines: [
          Polyline(
              points: [me, startAt],
              color: acroZoneEdgeColor,
              strokeWidth: 3,
              pattern: StrokePattern.dashed(segments: const [12, 8])),
        ]),
      if (startAt != null)
        MarkerLayer(markers: [
          Marker(
              point: startAt,
              width: 90,
              height: 56,
              rotate: true,
              child: const Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add_circle_outline, color: acroZoneEdgeColor, size: 32),
                Text("Acro start",
                    style: TextStyle(
                        color: acroZoneEdgeColor,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black)])),
              ])),
        ]),
    ]);
  }
}
