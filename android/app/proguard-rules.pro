# OpenList-Encrypt ProGuard / R8 规则
# 关键：R8 在 release 构建会误删 configureFlutterEngine 等嵌入生命周期 override
# （判定为未被调用的死代码），导致 Pigeon 通道不注册、Dart 侧报 channel-error。
# 这里显式保住 MainActivity 的全部成员与 Pigeon 生成代码/桥接实现。

# 保住 MainActivity 全部成员（含 configureFlutterEngine 及通道注册代码）
-keep class com.openlist.mobile.MainActivity { *; }

# 保住 Pigeon 生成代码
-keep class com.openlist.pigeon.** { *; }

# 保住桥接实现类
-keep class com.openlist.mobile.bridge.** { *; }

# 保住 Pigeon HostApi / FlutterApi 实现（防止接口实现被摇掉）
-keep class * implements com.openlist.pigeon.GeneratedApi$EncryptProxy { *; }
-keep class * implements com.openlist.pigeon.GeneratedApi$AppConfig { *; }
-keep class * implements com.openlist.pigeon.GeneratedApi$Android { *; }
-keep class * implements com.openlist.pigeon.GeneratedApi$NativeCommon { *; }
-keep class * implements com.openlist.pigeon.GeneratedApi$Event { *; }
