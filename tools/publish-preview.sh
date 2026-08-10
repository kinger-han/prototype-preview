#!/usr/bin/env bash
# ============================================================
# 原型在线预览发布脚本 (GitHub Pages)
#
# 用法 A（推荐，项目目录模式，支持单原型/多原型）:
#   publish-preview.sh --project <项目目录>
#   自动读 <项目目录>/publish-config.json，两种格式：
#     单原型: {"slug":"topic-mgmt-v2","name":"资源管理","desc":"...","dist_glob":"prototype/dist/*.html","assets_dir":"prototype/assets"}
#     多原型: {"prototypes":[{"slug":"smart-guide-pc",...},{"slug":"smart-guide-mobile",...}]}
#   自动选 dist 最新产物(排除*标注*)、复制 assets 并压缩大图(>300KB→WebP 1080px q82)、
#   替换 HTML 路径、更新导航页(自动去重)、一次 commit+push
#
# 用法 B（直接指定，无 assets 处理）:
#   publish-preview.sh <slug> <dist产物路径> <显示名称> [描述]
#
# 效果: 约 1 分钟后 https://kinger-han.github.io/prototype-preview/<slug>/ 生效
# ============================================================
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# ---------- 解析任务列表 ----------
if [ "$1" = "--project" ]; then
  PROJECT="$2"
  [ -d "$PROJECT" ] || { echo "❌ 项目目录不存在: $PROJECT"; exit 1; }
  [ -f "$PROJECT/publish-config.json" ] || { echo "❌ 缺少 $PROJECT/publish-config.json（见脚本头注释格式）"; exit 1; }
  TASKS=$(python - "$PROJECT" <<'PYEOF'
import sys, json, glob, os
proj = sys.argv[1]
cfg = json.load(open(os.path.join(proj, 'publish-config.json'), encoding='utf-8'))
items = cfg.get('prototypes') if isinstance(cfg.get('prototypes'), list) else [cfg]
for c in items:
    files = glob.glob(os.path.join(proj, c.get('dist_glob', 'prototype/dist/*.html')))
    files = [f for f in files if '标注' not in os.path.basename(f)]
    if not files:
        print('ERROR|' + c.get('slug', '?') + '|no dist html found')
        continue
    dist = max(files, key=os.path.getmtime)
    assets = os.path.join(proj, c.get('assets_dir', 'prototype/assets'))
    print('|'.join([c['slug'], c['name'], c.get('desc', ''), os.path.abspath(dist), os.path.abspath(assets)]))
PYEOF
)
  [ -n "$TASKS" ] || { echo "❌ 没有可发布任务"; exit 1; }
else
  SLUG="$1"; SRC="$2"; NAME="$3"; DESC="${4:-}"
  if [ -z "$SLUG" ] || [ -z "$SRC" ] || [ -z "$NAME" ]; then
    echo "用法: $0 --project <目录>  或  $0 <slug> <dist路径> <名称> [描述]"; exit 1
  fi
  SRC_ABS="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
  TASKS="$SLUG|$NAME|$DESC|$SRC_ABS|"
fi

# ---------- 同步远端最新 ----------
git fetch origin --quiet 2>/dev/null || true
git pull --quiet origin main 2>/dev/null || echo "⚠️ pull 失败(可能本地有未推送改动)，继续"

# ---------- 逐个发布 ----------
ANY=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if [ "${line%%|*}" = "ERROR" ]; then echo "❌ $line"; continue; fi
  SLUG=$(echo "$line" | cut -d'|' -f1)
  NAME=$(echo "$line" | cut -d'|' -f2)
  DESC=$(echo "$line" | cut -d'|' -f3)
  SRC=$(echo "$line" | cut -d'|' -f4)
  ASSETS_DIR=$(echo "$line" | cut -d'|' -f5)
  [ -f "$SRC" ] || { echo "❌ 产物不存在: $SRC"; continue; }

  echo "===== 发布: $NAME -> $SLUG ====="
  mkdir -p "$SLUG"
  cp "$SRC" "$SLUG/index.html"

  # assets 处理：复制 + 自动压缩大图(>300KB 缩放1080px 转WebP q82) + HTML 文件名/路径替换
  if [ -n "$ASSETS_DIR" ] && [ -d "$ASSETS_DIR" ]; then
    echo "📦 复制资源目录 -> $SLUG/assets ($(du -sh "$ASSETS_DIR" | cut -f1))"
    rm -rf "$SLUG/assets"
    cp -r "$ASSETS_DIR" "$SLUG/assets"
    python - "$SLUG/index.html" "$SLUG/assets" <<'PYEOF'
import sys, os
from PIL import Image
html_path, assets_root = sys.argv[1], sys.argv[2]
mapping = {}
for dirpath, dirnames, filenames in os.walk(assets_root):
    for fn in filenames:
        if fn.lower().endswith(('.png', '.jpg', '.jpeg')):
            src = os.path.join(dirpath, fn)
            size = os.path.getsize(src)
            if size < 300 * 1024:
                continue
            try:
                im = Image.open(src); im.load()
                w, h = im.size
                maxside = 1080
                if max(w, h) > maxside:
                    if w >= h:
                        im = im.resize((maxside, int(h * maxside / w)), Image.LANCZOS)
                    else:
                        im = im.resize((int(w * maxside / h), maxside), Image.LANCZOS)
                newfn = os.path.splitext(fn)[0] + '.webp'
                newpath = os.path.join(dirpath, newfn)
                im.save(newpath, 'WEBP', quality=82, method=6)
                os.remove(src)
                mapping[fn] = newfn
                print(f"🖼️ {fn} -> {newfn} ({size//1024}KB -> {os.path.getsize(newpath)//1024}KB)")
            except Exception as e:
                print(f"⚠️ {fn} 压缩失败: {e}")
if mapping:
    s = open(html_path, encoding='utf-8').read()
    for old, new in mapping.items():
        n = s.count(old)
        if n:
            s = s.replace(old, new)
            print(f"🔗 HTML 替换 {n} 处: {old} -> {new}")
    open(html_path, 'w', encoding='utf-8', newline='').write(s)
s = open(html_path, encoding='utf-8').read()
n = s.count('../assets/')
if n:
    s = s.replace('../assets/', 'assets/')
    open(html_path, 'w', encoding='utf-8', newline='').write(s)
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
  ANY=1
done <<< "$TASKS"

# ---------- 统一提交推送 ----------
[ "$ANY" = "0" ] && { echo "❌ 所有任务失败，未发布"; exit 1; }
git add -A
git commit -q -m "Publish previews" || echo "ℹ️ 无变更可提交"
git push origin main
echo ""
echo "🎉 发布完成，约 1 分钟后生效："
echo "   总览: https://kinger-han.github.io/prototype-preview/"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  [ "${line%%|*}" = "ERROR" ] && continue
  SLUG=$(echo "$line" | cut -d'|' -f1)
  echo "   https://kinger-han.github.io/prototype-preview/$SLUG/"
done <<< "$TASKS"
