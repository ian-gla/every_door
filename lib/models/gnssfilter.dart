import 'amenity.dart';
import 'floor.dart';
import 'address.dart';

class GNSSFilter {
  static const nullFloor = Floor(floor: 'null', level: 0.123456);
  static const nullAddress = StreetAddress(housenumber: 'null', street: 'null');

  final Floor? floor;
  final StreetAddress? address;
  final bool includeNoData; // TODO: what does this even mean
  final bool notChecked;

  GNSSFilter(
      {this.floor,
      this.address,
      this.includeNoData = true,
      this.notChecked = false});

  GNSSFilter copyWith(
      {Floor? floor,
      StreetAddress? address,
      bool? includeNoData,
      bool? notChecked}) {
    return GNSSFilter(
      floor: floor == nullFloor ? null : (floor ?? this.floor),
      address: address == nullAddress ? null : address ?? this.address,
      includeNoData: includeNoData ?? this.includeNoData,
      notChecked: notChecked ?? this.notChecked,
    );
  }

  bool get isEmpty => floor == null && address == null && !notChecked;
  bool get isNotEmpty => floor != null || address != null || notChecked;

  bool matches(OsmChange amenity) {
    if (notChecked && !amenity.isOld) return false;
    final tags = amenity.getFullTags();
    bool matchesAddr =
        address == null || address == StreetAddress.fromTags(tags);
    final floors = MultiFloor.fromTags(tags);
    bool matchesFloor = floor == null ||
        ((floor?.isEmpty ?? true)
            ? floors.isEmpty
            : floors.floors.contains(floor));
    return matchesAddr && matchesFloor;
  }

  @override
  String toString() => 'GNSSFilter(address: $address, floor: $floor)';
}
