import 'dart:math';

import 'package:every_door/helpers/good_tags.dart';
import 'package:every_door/providers/legend.dart';
import 'package:every_door/widgets/legend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:every_door/constants.dart';
import 'package:every_door/helpers/equirectangular.dart';
import 'package:every_door/models/amenity.dart';
import 'package:every_door/providers/api_status.dart';
import 'package:every_door/providers/geolocation.dart';
import 'package:every_door/providers/location.dart';
import 'package:every_door/providers/editor_mode.dart';
import 'package:every_door/providers/need_update.dart';
import 'package:every_door/providers/osm_data.dart';
import 'package:every_door/providers/poi_filter.dart';
import 'package:every_door/widgets/map.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:raw_gnss/gnss_status_model.dart';
import 'package:raw_gnss/raw_gnss.dart';

import '../../providers/gnss_filter.dart';

class GNSSPane extends ConsumerStatefulWidget {
  final Widget? areaStatusPanel;
  final bool isWide;

  const GNSSPane({this.areaStatusPanel, this.isWide = false});

  @override
  ConsumerState createState() => GNSSListPageState();
}

class GNSSListPageState extends ConsumerState<GNSSPane> {
  List<LatLng> otherPOI = [];
  List<OsmChange> nearestPOI = [];
  final mapController = AmenityMapController();
  bool farFromUser = false;
  late RawGnss _gnss;

  @override
  void initState() {
    super.initState();
    _gnss = RawGnss();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      updateFarFromUser();
      updateNearest();
    });
  }

  updateFarFromUser() {
    final gpsLocation = ref.read(geolocationProvider);
    bool newFar;
    if (gpsLocation != null) {
      final location = ref.read(effectiveLocationProvider);
      final distance = DistanceEquirectangular();
      newFar = distance(location, gpsLocation) >= kFarDistance;
    } else {
      newFar = true;
    }

    if (newFar != farFromUser) {
      setState(() {
        farFromUser = newFar;
      });
    }
  }

  updateNearest({LatLng? forceLocation, int? forceRadius}) async {
    // Disabling updates in zoomed in mode.
    if (forceLocation == null && ref.read(microZoomedInProvider) != null)
      return;

    final provider = ref.read(osmDataProvider);
    final isMicromapping =
        ref.read(editorModeProvider) == EditorMode.micromapping;
    final isGNSS = ref.read(editorModeProvider) == EditorMode.gnss;
    final filter = ref.read(poiFilterProvider);
    final location = forceLocation ?? ref.read(effectiveLocationProvider)!;
    // Query for amenities around the location.
    final int radius =
        forceRadius ?? (farFromUser ? kFarVisibilityRadius : kVisibilityRadius);
    List<OsmChange> data = await provider.getElements(location, radius);

    // Remove points too far from the user.
    const distance = DistanceEquirectangular();
    data = data
        .where((e) => e.isPoint || e.isArea)
        .where((element) => distance(location, element.location) <= radius)
        .toList();

    // Keep other mode objects to show.
    final otherData = data
        .where((e) {
          switch (e.kind) {
            case ElementKind.amenity:
              return isMicromapping;
            case ElementKind.micro:
              return !isMicromapping;
            default:
              return false;
          }
        })
        .map((e) => e.location)
        .toList();

    // Filter for amenities (or not amenities).
    data = data.where((e) {
      switch (e.kind) {
        case ElementKind.amenity:
          return !isMicromapping;
        case ElementKind.micro:
          return isMicromapping;
        case ElementKind.building:
          return isGNSS;
        case ElementKind.address:
        case ElementKind.entrance:
          return false;
        default:
          return e.isNew;
      }
    }).toList();
    // Apply the building filter.
    if (filter.isNotEmpty) {
      data = data.where((e) => filter.matches(e)).toList();
    }
    // Sort by distance.
    data.sort((a, b) => distance(location, a.location)
        .compareTo(distance(location, b.location)));
    // Trim to 10-20 elements.
    final maxElements = !isMicromapping ? kAmenitiesInList : kMicroStuffInList;
    if (data.length > maxElements) data = data.sublist(0, maxElements);

    // Update the map.
    if (!mounted) return;
    setState(() {
      nearestPOI = data;
      otherPOI = otherData;
    });

    // Update the legend.
    if (isMicromapping) {
      final locale = Localizations.localeOf(context);
      ref.read(legendProvider.notifier).updateLegend(data, locale: locale);
    }

    // Zoom automatically only when tracking location.
    if (ref.read(trackingProvider)) {
      mapController.zoomToFit(data.map((e) => e.location));
    }
  }

  Widget _loadingSpinner() => const Center(child: CircularProgressIndicator());
  @override
  Widget build(BuildContext context) {
    final location = ref.read(effectiveLocationProvider);
    final isMicromapping =
        ref.watch(editorModeProvider) == EditorMode.micromapping;
    final isGNSS = ref.watch(editorModeProvider) == EditorMode.gnss;
    final isZoomedIn = ref.watch(microZoomedInProvider) != null;
    final apiStatus = ref.watch(apiStatusProvider);
    ref.listen(editorModeProvider, (_, next) {
      updateNearest();
    });
    ref.listen(needMapUpdateProvider, (_, next) {
      updateNearest();
    });
    ref.listen(GNSSFilterProvider, (_, next) {
      updateNearest();
    });
    ref.listen(effectiveLocationProvider, (_, LatLng next) {
      mapController.setLocation(next, emitDrag: false, onlyIfFar: true);
      updateFarFromUser();
      updateNearest();
    });
    ref.listen<LatLngBounds?>(microZoomedInProvider, (_, next) {
      // Only update when returning from the mode.
      if (next == null) updateNearest();
    });

    final Widget bottomPane;
    if (apiStatus != ApiStatus.idle) {
      bottomPane = Expanded(
        flex: isMicromapping || farFromUser ? 10 : 23,
        child: buildApiStatusPane(context, apiStatus),
      );
    } else if (!isMicromapping || isZoomedIn) {
      // We want to constraint vertical size, so that tiles
      // don't take precious space from the map.
      final bottomPaneChild = SafeArea(
        bottom: false,
        left: false,
        right: false,
        top: widget.isWide,
        child: gNSSPaneBuilder(),
      );
      final needMaxMap = isMicromapping || farFromUser;
      final mediaHeight = MediaQuery.of(context).size.height;
      if (widget.isWide || mediaHeight <= 600)
        bottomPane = Flexible(
          flex: needMaxMap ? 10 : 23,
          child: bottomPaneChild,
        );
      else
        bottomPane = SizedBox(
          height: needMaxMap && mediaHeight < 900 ? 300 : 300,
          child: bottomPaneChild,
        );
    } else if (!widget.isWide) {
      bottomPane = LegendPane();
    } else {
      bottomPane = SizedBox(
        child: SingleChildScrollView(
          child: SafeArea(
            left: false,
            bottom: false,
            right: false,
            child: gNSSPaneBuilder(),
          ),
        ),
        width: 200.0,
      );
    }

    return Flex(
      direction: widget.isWide ? Axis.horizontal : Axis.vertical,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 10,
          child: AmenityMap(
            initialLocation: location,
            amenities: nearestPOI,
            otherObjects: otherPOI,
            controller: mapController,
            onDragEnd: (pos) {
              ref.read(effectiveLocationProvider.notifier).set(pos);
            },
            colorsFromLegend: isMicromapping,
            drawNumbers: !isMicromapping || isZoomedIn,
            drawZoomButtons: isMicromapping || farFromUser,
          ),
        ),
        if (widget.areaStatusPanel != null)
          widget.isWide
              ? RotatedBox(quarterTurns: 3, child: widget.areaStatusPanel!)
              : widget.areaStatusPanel!,
        bottomPane,
      ],
    );
  }

  Widget gNSSPaneBuilder() {
    return StreamBuilder<GnssStatusModel>(
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return _loadingSpinner();
        } else {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              //mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  height: 2,
                ),
                Row(children: [
                  SizedBox(
                    width: 10,
                  ),
                  Center(
                      child: SizedBox(
                    width: 250.0,
                    height: 250.0,
                    child: drawSatellites(snapshot),
                  )),
                  SizedBox(
                    width: 10,
                  ),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text.rich(TextSpan(children: [
                          TextSpan(text: 'GPS: '),
                          WidgetSpan(
                            child: Icon(
                              Icons.square,
                              size: 14,
                              color: Colors.red,
                            ),
                          )
                        ])),
                        Text.rich(TextSpan(children: [
                          TextSpan(text: 'SBAS: '),
                          WidgetSpan(
                            child: Icon(
                              Icons.square,
                              size: 14,
                              color: Colors.yellow,
                            ),
                          )
                        ])),
                        Text.rich(TextSpan(children: [
                          TextSpan(text: 'GLASNOSS: '),
                          WidgetSpan(
                            child: Icon(
                              Icons.square,
                              size: 14,
                              color: Colors.green,
                            ),
                          )
                        ])),
                        Text.rich(TextSpan(children: [
                          TextSpan(text: 'QZSS: '),
                          WidgetSpan(
                            child: Icon(
                              Icons.square,
                              size: 14,
                              color: Colors.cyan,
                            ),
                          )
                        ])),
                        Text.rich(TextSpan(children: [
                          TextSpan(text: 'Beidou: '),
                          WidgetSpan(
                            child: Icon(
                              Icons.square,
                              size: 14,
                              color: Colors.blue,
                            ),
                          )
                        ])),
                        Text.rich(TextSpan(children: [
                          TextSpan(text: 'Galileo: '),
                          WidgetSpan(
                            child: Icon(
                              Icons.square,
                              size: 14,
                              color: Colors.orange,
                            ),
                          )
                        ]))
                      ]),
                ]),
                Row(children: [
                  Text(
                      'Number of Satellites: ${snapshot.data!.satelliteCount}'),
                  TextButton.icon(
                    //TODO: enable/disable this on snapshot availability
                    onPressed: uploadGnssData,
                    icon: const Icon(Icons.upload_outlined),
                    label: const Text('Save GNSS Data'),
                  ),
                ])
              ]);
        }
      },
      stream: _gnss.gnssStatusEvents,
    );
  }
}

Widget drawSatellites(AsyncSnapshot<GnssStatusModel> snapshot) {
  return CustomPaint(
    size: Size(80, 80),
    painter: CirclePainter(snapshot),
  );
}

bool uploadGnssData() {
  return true;
}

class CirclePainter extends CustomPainter {
  final _paint = Paint()
    ..color = Colors.red
    ..strokeWidth = 2
    // Use [PaintingStyle.fill] if you want the circle to be filled.
    ..style = PaintingStyle.stroke;
  late AsyncSnapshot<GnssStatusModel> _snapshot;
  CirclePainter(AsyncSnapshot<GnssStatusModel> snapshot) {
    _snapshot = snapshot;
  }
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawOval(
      Rect.fromLTWH(0, 0, size.width, size.height),
      _paint,
    );
    Offset centre = Offset(0, 0).translate(size.width / 2, size.height / 2);
    List<Offset> points = List<Offset>.empty(growable: true);

    for (int i = 0; i < _snapshot.data!.satelliteCount!; i++) {
      // draw a point in the direction of the satellite with a distance reletated to it's elevation.
      var status = _snapshot.data!.status![i];
      var angle = status.azimuthDegrees! * pi / 180.0;

      var distance =
          (size.width / 2) * cos(status.elevationDegrees! * pi / 180);
      var point = Offset.fromDirection(angle, distance)
          .translate(size.width / 2, size.height / 2);
      points.add(point);
      //print("${status.constellationType} -> ${status.azimuthDegrees} + $point");
      Paint linePaint = Paint();
      /*
      %ConstellationType values are defined in Android HAL Documentation, gps.h,
      %   typedef uint8_t                         GnssConstellationType;
      %   #define GNSS_CONSTELLATION_UNKNOWN      0
      %   #define GNSS_CONSTELLATION_GPS          1
      %   #define GNSS_CONSTELLATION_SBAS         2
      %   #define GNSS_CONSTELLATION_GLONASS      3
      %   #define GNSS_CONSTELLATION_QZSS         4
      %   #define GNSS_CONSTELLATION_BEIDOU       5
      %   #define GNSS_CONSTELLATION_GALILEO      6
       */
      switch (status.constellationType) {
        case 1: // gps
          linePaint.color = Colors.red;
          break;
        case 2: // SBAS
          linePaint.color = Colors.yellow;
          break;
        case 3: //GLONASS
          linePaint.color = Colors.green;
          break;
        case 4: // QZSS
          linePaint.color = Colors.cyan;
          break;
        case 5: //Beidou
          linePaint.color = Colors.blue;
          break;
        case 6: // galileo
          linePaint.color = Colors.orange;
          break;
      }
      if (status.constellationType != 6) {
        canvas.drawLine(centre, point, linePaint);
      }
    }

    //canvas.drawColor(const Color(0xFF000000), BlendMode.color);
    //canvas.drawPoints(PointMode.points, points, _paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}

Widget buildApiStatusPane(BuildContext context, ApiStatus apiStatus) {
  final loc = AppLocalizations.of(context)!;
  return Column(
    mainAxisSize: MainAxisSize.max,
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      CircularProgressIndicator(),
      SizedBox(height: 20.0),
      Text(
        getApiStatusLoc(apiStatus, loc),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 20.0),
      ),
    ],
  );
}
