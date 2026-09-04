#!/usr/bin/env bash
#
# matrix-android-apk 兼容性冒烟测试
# 验证 2.0.8 apk 在目标设备（尤其 Android 15/16）上的基础存活 + 触摸注入 hidden-API 风险。
#
# 用法：./scripts/compat-smoke.sh <device-serial> [apk路径]
#   例：./scripts/compat-smoke.sh 10.0.155.203:54949
# 默认 apk 取 matrix-agent/plugins/sonic-android-apk.apk（2.0.8）。
#
set -uo pipefail

DEV="${1:?用法: $0 <device-serial> [apk]}"
APK="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../matrix-agent" 2>/dev/null && pwd)/plugins/sonic-android-apk.apk}"
PKG="org.cloud.sonic.android"

adb -s "$DEV" get-state >/dev/null 2>&1 || { echo "❌ 设备不在线: $DEV"; exit 1; }
[ -f "$APK" ] || { echo "❌ 找不到 apk: $APK"; exit 1; }

echo "=== 1. 安装 + 版本（期望 versionName=2.0.8）==="
adb -s "$DEV" install -r "$APK" 2>&1 | tail -1
VN="$(adb -s "$DEV" shell dumpsys package $PKG 2>/dev/null | grep -m1 versionName | tr -d ' \r')"
echo "  → $VN"
echo "$VN" | grep -q "2.0.8" && echo "  ✅ 版本正确" || echo "  ⚠️ 版本非 2.0.8"

echo "=== 2. Activity 启动存活（MainActivity / SearchActivity）==="
for act in ".MainActivity" ".plugin.activityPlugin.SearchActivity"; do
  adb -s "$DEV" shell am start -n "$PKG$act" >/dev/null 2>&1
  sleep 2
  if adb -s "$DEV" shell "dumpsys activity 2>/dev/null" | grep -q "org.cloud.sonic.android/.*\(Exception\|crash\)"; then
    echo "  ❌ $act 启动后崩溃"
  else
    echo "  ✅ $act 可启动"
  fi
done
echo "  —— crash 日志（如为空则无崩溃）："
adb -s "$DEV" logcat -d -b crash 2>/dev/null | grep -A4 "org.cloud.sonic.android" | tail -8

echo "=== 3. 前台服务 SonicManagerServiceV2（Android 14+ FGS type）==="
adb -s "$DEV" shell am startservice "$PKG/.service.SonicManagerServiceV2" 2>&1 | tail -1
sleep 1
adb -s "$DEV" shell "dumpsys activity services $PKG 2>/dev/null" | grep -i "SonicManagerServiceV2\|foreground" | head -2

echo "=== 4. 自定义输入法 SonicKeyboard ==="
adb -s "$DEV" shell ime enable "$PKG/.keyboard.SonicKeyboard" 2>&1 | head -1
adb -s "$DEV" shell ime set "$PKG/.keyboard.SonicKeyboard" 2>&1 | head -1
adb -s "$DEV" shell ime list -s 2>/dev/null | grep -i sonic && echo "  ✅ 输入法已启用" || echo "  ⚠️ 输入法未出现在列表"

echo "=== 5. 触摸注入（app_process + hidden-API 探针）==="
APKPATH="$(adb -s "$DEV" shell pm path $PKG 2>/dev/null | sed 's/package://;s/\r//')"
echo "  apk path = $APKPATH"
# 冷启动 touch service（同 agent 的做法：app_process shell uid）
adb -s "$DEV" logcat -c 2>/dev/null
( adb -s "$DEV" shell "CLASSPATH=$APKPATH exec app_process /system/bin $PKG.plugin.SonicPluginTouchService" >/tmp/touch-service.log 2>&1 & )
sleep 3
echo "  —— touch service 启动输出（Couldn't get screen resolution = 反射被拦/失败）："
cat /tmp/touch-service.log 2>/dev/null | head -6

# forward + 发协议命令
adb -s "$DEV" forward tcp:16990 localabstract:sonictouchservice 2>/dev/null
python3 - <<'PY'
import socket,time
try:
    s=socket.create_connection(('localhost',16990),timeout=5)
    for c in (b'down 300 500\n', b'move 350 550\n', b'up\n'):
        s.sendall(c); time.sleep(0.4)
    s.sendall(b'release\n'); s.close()
    print("  ✅ 已发送 down/move/up 协议命令")
except Exception as e:
    print("  ❌ 连接 touch 服务失败:", e)
PY
sleep 1
echo "  —— logcat 里 hidden-API / 注入相关（空=无报错，往往即注入正常）："
adb -s "$DEV" logcat -d 2>/dev/null | grep -iE "hiddenapi|hidden api|not allowed|IllegalAccess|SecurityException|sonictouch|Denied blocking|injectInputEvent" | tail -8

adbd_cleanup() { adb -s "$DEV" forward --remove tcp:16990 >/dev/null 2>&1; adb -s "$DEV" shell "pidof $PKG.plugin.SonicPluginTouchService" 2>/dev/null | xargs -r adb -s "$DEV" shell kill; }
adbd_cleanup
echo "=== 完成 ==="