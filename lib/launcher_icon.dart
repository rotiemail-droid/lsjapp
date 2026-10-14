import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_build.dart';

/// 真果鉴安装即以真果鉴入口出现；启动时调用一次，把旧版本设备上遗留的
/// 绿果鉴入口纠正过来。绿果鉴不支持切换，桌面入口始终是绿果鉴。
class LauncherIcon {
  static const _channel = MethodChannel('duanju/device');

  static bool get supported =>
      allSourcesEnabled && !kIsWeb && Platform.isAndroid;

  static Future<void> apply(bool full) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('setLauncherEdition', {'full': full});
    } catch (_) {
      // 切换失败时保留当前入口：桌面图标属于系统状态，不影响应用内功能。
    }
  }
}
