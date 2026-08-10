#!/usr/bin/env bash
# ============================================================
# 原型在线预览发布脚本 (GitHub Pages)
#
# 用法 A（推荐，项目目录模式）:
#   publish-preview.sh --project <项目目录>
#   自动读取 <项目目录>/publish-config.json:
#     {"slug":"topic-mgmt-v2","name":"主题管理V2","desc":"...","dist_glob":"prototype/dist/*.html","assets_dir":"prototype/assets"}
#   自动选 dist 下最新修改的产物(排除*标注*)、复制 assets、替换路径、更新导航页、push
#
# 用法 B（直接指定）:
#   publish-preview.sh <slug> <dist产物路径> <显示名称> [描述]
#
# 效果: 约 1 分钟后 https://kinger-han.github.io/prototype-preview/<slug>/ 生效
# ============================================================
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

if [ "$1" = "--project" ]; then
  PROJECT="$2"
  [ -d "$PROJECT" ] || { echo "❌ 项目目录不存在: $PROJECT"; exit 1; }
  [ -f "$PROJECT/publish-config.json" ] || { echo "❌ 缺少 $PROJECT/publish-config.json（见脚本头注释格式）"; exit 1; }
  # python 解析配置 + 找最新产物，输出 slug|name|desc|dist绝对路径|assets绝对路径
  INFO=$(python - "$PROJECT" <<'PYEOF'
import sys, json, glob, os
proj = sys.argv[1]
cfg = json.load(open(os.path.join(proj, 'publish-config.json'), encoding='utf-8'))
files = glob.glob(os.path.join(proj, cfg.get('dist_glob', 'prototype/dist/*.html')))
files = [f for f in files if '标注' not in os.path.basename(f)]
if not files:
    print('ERROR|no dist html found'); sys.exit(1)
dist = max(files, key=os.path.getmtime)
assets = os.path.join(proj, cfg.get('assets_dir', 'prototype/assets'))
print('|'.join([cfg['slug'], cfg['name'], cfg.get('desc', ''), os.path.abspath(dist), os.path.abspath(assets)]))
PYEOF
)
  if [ "${INFO%%|*}" = "ERROR" ]; then echo "❌ $INFO"; exit 1; fi
  SLUG=$(echo "$INFO" | cut -d'|' -f1)
  NAME=$(echo "$INFO" | cut -d'|' -f2)
  DESC=$(echo "$INFO" | cut -d'|' -f3)
  SRC=$(echo "$INFO" | cut -d'|' -f4)
  ASSETS_DIR=$(echo "$INFO" | cut -d'|' -f5)
else
  SLUG="$1"; SRC="$2"; NAME="$3"; DESC="${4:-}"
  [ -z "$SLUG" ] || [ -z "$SRC" ] || [ -z "$NAME" ] && { echo "用法: $0 --project <目录>  或  $0 <slug> <dist路径> <名称> [描述]"; exit 1; }
  ASSETS_DIR=""
fi
[ -f "$SRC" ] || { echo "❌ 产物不存在: $SRC"; exit 1; }

# 同步远端最新
git fetch origin --quiet 2>/dev/null || true
git pull --quiet origin main 2>/dev/null || echo "⚠️ pull 失败(可能本地有未推送改动)，继续"

mkdir -p "$SLUG"
cp "$SRC" "$SLUG/index.html"

# assets 处理：复制资源目录 + 替换 HTML 内 ../assets/ -> assets/
if [ -n "$ASSETS_DIR" ] && [ -d "$ASSETS_DIR" ]; then
  echo "📦 复制资源目录 -> $SLUG/assets ($(du -sh "$ASSETS_DIR" | cut -f1))"
  rm -rf "$SLUG/assets"
  cp -r "$ASSETS_DIR" "$SLUG/assets"
  python - "$SLUG/index.html" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
n = s.count('../assets/')
s = s.replace('../assets/', 'assets/')
open(p, 'w', encoding='utf-8', newline='').write(s)
print(f"🔗 路径替换 {n} 处: ../assets/ -> assets/")
PYEOF
else
  echo "ℹ️ 无 assets 目录（或未配置），跳过资源处理"
fi

# 更新导航页（已存在则跳过）
python - "$SLUG" "$NAME" "$DESC" <<'PYEOF'
import sys, html
slug, name, desc = sys.argv[1], sys.argv[2], sys.argv[3]
path = 'index.html'
s = open(path, encoding='utf-8').read()
if f'href="{slug}/"' in s:
    print("ℹ️ 导航页已有该原型，跳过")
else:
    card = (f'    <a class="card" href="{slug}/">\n'
            f'      <div class="name">{html.escape(name)}</div>\n'
            f'      <div class="desc">{html.escape(desc)}</div>\n'
            f'    </a>\n')
    if '  </div>\n  <div class="footer">' in s:
        s = s.replace('  </div>\n  <div class="footer">', card + '  </div>\n  <div class="footer">', 1)
    else:
        s = s.replace('</div>\n  <div class="footer">', card + '</div>\n  <div class="footer">', 1)
    open(path, 'w', encoding='utf-8', newline='\n').write(s)
    print("✅ 导航页已更新")
PYEOF

git add -A
git commit -q -m "Publish $SLUG preview" || echo "ℹ️ 无变更可提交"
git push origin main
echo ""
echo "🎉 发布完成: https://kinger-han.github.io/prototype-preview/$SLUG/"
echo "   约 1 分钟后生效，可先在浏览器强刷(Ctrl+F5)验证"
