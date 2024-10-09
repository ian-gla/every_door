import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final editorModeProvider =
    StateNotifierProvider<EditorModeController, EditorMode>(
        (_) => EditorModeController());

final microZoomedInProvider = StateProvider<LatLngBounds?>((_) => null);
final navigationModeProvider = StateProvider<bool>((ref) => false);

enum EditorMode {
  gnss,

}

const kEditorModeIcons = {
  EditorMode.gnss: Icons.satellite,

};

const kEditorModeIconsOutlined = {
  EditorMode.gnss: Icons.satellite_outlined,

};

const kNextMode = {
  EditorMode.gnss: EditorMode.gnss,
  };

class EditorModeController extends StateNotifier<EditorMode> {
  static const kModeKey = 'micromappingMode';

  EditorModeController() : super(EditorMode.gnss) {
    loadState();
  }

  loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final modes = {for (final m in EditorMode.values) m.name: m};
    state = modes[prefs.getString(kModeKey)] ?? EditorMode.gnss;
  }

  set(EditorMode newValue) async {
    if (state != newValue) {
      state = newValue;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kModeKey, state.name);
    }
  }

  next() async {
    await set(kNextMode[state]!);
  }
}
