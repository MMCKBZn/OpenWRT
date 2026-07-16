# 加入NSS 状态页面
echo ">>> 集成 NSS 状态页面到 LuCI"

# 1. 清理旧菜单的 uci-defaults 脚本（首次启动执行）
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-nss-clean << 'CLEAN_EOF'
#!/bin/sh
rm -f /usr/share/luci/menu.d/60_nss_status.json
while uci show luci 2>/dev/null | grep -q "nss_status"; do
  idx=$(uci show luci | grep "nss_status" | head -1 | cut -d'[' -f2 | cut -d']' -f1)
  uci delete luci.@entry[$idx] 2>/dev/null
done
uci commit luci 2>/dev/null

/etc/init.d/uhttpd restart 2>/dev/null
rm -rf /tmp/luci-*
exit 0
CLEAN_EOF
chmod +x files/etc/uci-defaults/99-nss-clean

# 2. LuCI 控制器（重定向到 CGI）
mkdir -p files/usr/lib/lua/luci/controller
cat > files/usr/lib/lua/luci/controller/nss_status.lua << 'LUA_EOF'
module("luci.controller.nss_status", package.seeall)
function index()
    entry({"admin", "nss_status"}, call("action_redirect"), _("NSS 状态"), 60).leaf = true
end
function action_redirect()
    luci.http.redirect("/cgi-bin/nss_status")
end
LUA_EOF

# 3. CGI 状态页脚本
mkdir -p files/www/cgi-bin
cat > files/www/cgi-bin/nss_status << 'CGI_EOF'
#!/bin/sh
echo "Content-type: text/html; charset=utf-8"
echo ""
FW_VER=""
if command -v nss_diag >/dev/null 2>&1; then
  RAW=$(nss_diag 2>&1)
  FW_VER=$(echo "$RAW" | grep -i "NSS FW:" | head -1 | sed 's/.*NSS FW: *//; s/ .*//')
  STATS="$RAW"
  STATS_SRC="nss_diag"
else
  STATS="无法获取统计信息。"
  STATS_SRC="无可用命令"
fi
[ -z "$FW_VER" ] && FW_VER="未检测到"
if lsmod | grep -q nss_core; then
  ENGINE="已启用"
elif [ -d /proc/sys/dev/nss ]; then
  ENGINE="已加载"
else
  ENGINE="未检测到"
fi
cat <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NSS 状态</title>
<style>
  body { background: #f4f6f9; padding: 20px; }
  .container { max-width: 960px; margin: 0 auto; }
  .card { background: white; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.06);
          padding: 24px; margin-bottom: 24px; }
  h1 { margin-top: 0; }
  h2 { border-bottom: 2px solid #0078d4; padding-bottom: 8px; color: #0078d4; }
  .row { display: flex; padding: 10px 0; border-bottom: 1px solid #f0f0f0; }
  .row:last-child { border-bottom: none; }
  .label { width: 140px; font-weight: 600; color: #555; }
  .badge { padding: 4px 12px; border-radius: 20px; font-size: 14px; }
  .on { background: #d2f5d2; color: #1e7b1e; }
  .off { background: #ffe3e3; color: #b30000; }
  pre { background: #f5f5f5; padding: 16px; border-radius: 6px; overflow-x: auto; white-space: pre-wrap;
        border: 1px solid #e0e0e0; margin: 0; }
  .src { font-size: 13px; color: #888; margin-top: 8px; }
  .refresh { text-align: right; margin-top: 16px; }
  a { color: #0078d4; text-decoration: none; }
</style>
</head>
<body>
<div class="container">
<h1>NSS 状态信息</h1>
<div class="card">
  <h2>NSS 引擎状态</h2>
  <div class="row">
    <span class="label">引擎状态</span>
    <span class="value"><span class="badge $( [ "$ENGINE" = "已启用" ] && echo on || echo off )">${ENGINE}</span></span>
  </div>
</div>
<div class="card">
  <h2>NSS 固件版本</h2>
  <div class="row">
    <span class="label">NSS FW 版本</span>
    <span class="value">${FW_VER}</span>
  </div>
</div>
<div class="card">
  <h2>NSS 负载 / 流量统计</h2>
  <pre>${STATS}</pre>
  <div class="src">数据源: ${STATS_SRC}</div>
</div>
<div class="refresh">
  <a href="javascript:location.reload();">🔄 手动刷新</a> &nbsp;|&nbsp;
  <a href="/cgi-bin/nss_status">直接访问</a>
  <br><small>页面生成: $(date '+%Y-%m-%d %H:%M:%S')</small>
</div>
</div>
</body>
</html>
EOF
CGI_EOF
chmod +x files/www/cgi-bin/nss_status

echo ">>> NSS 状态页面集成完毕"
