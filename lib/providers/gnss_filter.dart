import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/gnssfilter.dart';

final GNSSFilterProvider = StateProvider<GNSSFilter>((ref) => GNSSFilter());
