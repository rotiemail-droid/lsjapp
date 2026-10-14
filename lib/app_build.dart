const allSourcesEnabled = bool.fromEnvironment('ALL_SOURCES');

/// 真果鉴（全站源版）安装即以「真果鉴」名称出现，分级限制开关常驻设置页；
/// 绿果鉴恒为绿色版本，没有分级限制入口。
const appName = allSourcesEnabled ? '真果鉴' : '绿果鉴';
const appSlug = allSourcesEnabled ? 'zhenguojian' : 'lvguojian';
