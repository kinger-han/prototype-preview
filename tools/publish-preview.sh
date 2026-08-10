#!/usr/bin/env bash
# ============================================================
# 原型在线预览发布脚本 (GitHub Pages)
# 用法: publish-preview.sh <slug> <dist产物路径> <显示名称> [描述]
# 示例: publish-preview.sh topic-mgmt-v2 "D:/hpy/桌面/数熙相关文档/主题管理/prototype/dist/主题管理V2-pc-原型.html" "主题管理V2" "智融平台 - 主题管理V2 原型"
# 效果: 复制产物到 prototype-preview/<slug>/index.html + 更新导航页 + push
#       约 1 分钟后 https://kinger-han.github.io/prototype-preview/<slug>/ 生效
# ============================================================
set -e

SLUG="$1"; SRC="$2"; NAME="$3"; DESC="${4:-}"
if [ -z "$SLUG" ] || [ -z "$SRC" ] || [ -z "$NAME" ]; then
  echo "用法: $0 <slug> <dist产物路径> <显示名称> [描述]"
  exit 1
fi
[ -f "$SRC" ] || { echo "❌ 产物不存在: $SRC"; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# 同步远端最新（首次 clone 后；有本地未推送改动时跳过 pull）
git fetch origin --quiet 2>/dev/null || true
git pull --quiet origin main 2>/dev/null || echo "⚠️ pull 失败(可能本地有未推送改动)，继续"

mkdir -p "$SLUG"
cp "$SRC" "$SLUG/index.html"
echo "✅ 已复制产物 -> $SLUG/index.html"

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
