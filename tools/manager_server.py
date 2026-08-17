#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
原型管理工具 — 本地后端服务
启动: manager.bat 或 python manager_server.py
界面: http://localhost:8765
"""
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # 发布仓根 (prototype-preview)
BASE = os.path.dirname(REPO)                                          # 项目根 (数熙相关文档)
SCRIPT = os.path.join(REPO, 'tools', 'publish-preview.sh')
PORT = 8765

# Windows 原生 Python 的 PATH 里没有 git-bash，必须用绝对路径调用 bash
BASH = None
for _cand in (shutil.which('bash'),
              r'C:\Program Files\Git\bin\bash.exe',
              r'C:\Program Files\Git\usr\bin\bash.exe',
              r'C:\Program Files (x86)\Git\bin\bash.exe'):
    if _cand and os.path.isfile(_cand):
        BASH = _cand
        break


def run(cmd, cwd=None, timeout=300):
    """运行命令，返回 (returncode, stdout+stderr)"""
    try:
        r = subprocess.run(cmd, shell=False, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', cwd=cwd, timeout=timeout)
        out = (r.stdout or '') + ('\n' + r.stderr if r.stderr else '')
        return r.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return -1, '执行超时'
    except Exception as e:
        return -1, f'执行失败: {e}'


def scan_projects():
    """扫描 BASE/*/publish-config.json -> [{dir, config}]"""
    projects = []
    if not os.path.isdir(BASE):
        return projects
    for d in sorted(os.listdir(BASE)):
        if d.startswith('.'):
            continue
        p = os.path.join(BASE, d)
        cfg_path = os.path.join(p, 'publish-config.json')
        if os.path.isdir(p) and os.path.isfile(cfg_path):
            try:
                cfg = json.load(open(cfg_path, encoding='utf-8'))
                items = cfg.get('prototypes') if isinstance(cfg.get('prototypes'), list) else [cfg]
                projects.append({'dir': d, 'path': p, 'items': items})
            except Exception as e:
                projects.append({'dir': d, 'path': p, 'error': str(e)})
    return projects


def scan_previews():
    """解析发布仓导航页卡片 -> [{slug, name, desc}]"""
    idx = os.path.join(REPO, 'index.html')
    try:
        s = open(idx, encoding='utf-8').read()
    except Exception:
        return []
    cards = []
    for m in re.finditer(
            r'<a class="card" href="([^"]+)/">\s*<div class="name">([^<]+)</div>\s*<div class="desc">([^<]*)</div>',
            s):
        cards.append({'slug': m.group(1), 'name': m.group(2), 'desc': m.group(3)})
    return cards


def git_push(repo):
    """在仓库里 add+commit+push，返回 (ok, msg)"""
    code, out = run(['git', 'add', '-A'], cwd=repo)
    if code != 0:
        return False, out
    code, out = run(['git', 'commit', '-q', '-m', 'manager: update'], cwd=repo)
    if code != 0 and 'nothing to commit' not in out and '无变更' not in out:
        return False, out
    code, out = run(['git', 'push', 'origin', 'HEAD'], cwd=repo)
    if code != 0:
        return False, out
    return True, out


class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, text):
        body = text.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

    # ---------- API ----------
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == '/api/previews':
            self._json({'ok': True, 'previews': scan_previews()})
        elif path == '/api/projects':
            self._json({'ok': True, 'projects': scan_projects()})
        elif path in ('/', '/index.html'):
            self._html(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'manager.html'),
                            encoding='utf-8').read())
        else:
            self._json({'ok': False, 'error': 'not found'}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        try:
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))).decode('utf-8'))
        except Exception:
            body = {}
        if path == '/api/rename':
            self._json(self.cmd_rename(body))
        elif path == '/api/publish':
            self._json(self.cmd_publish(body))
        elif path == '/api/remove':
            self._json(self.cmd_remove(body))
        else:
            self._json({'ok': False, 'error': 'not found'}, 404)

    # ---------- 命令 ----------
    def cmd_rename(self, body):
        """改名/改描述/改浏览器标题：更新发布仓导航页卡片 + 发布仓HTML的<title> + 项目 publish-config.json，然后 push"""
        slug = (body.get('slug') or '').strip()
        name = (body.get('name') or '').strip()
        desc = (body.get('desc') or '').strip()
        title = (body.get('title') or '').strip()
        if not slug or not name:
            return {'ok': False, 'error': 'slug 和 name 必填'}
        msgs = []

        # 1) 更新导航页
        idx = os.path.join(REPO, 'index.html')
        s = open(idx, encoding='utf-8').read()
        pat = re.compile(r'(<a class="card" href="' + re.escape(slug) + r'/">\s*<div class="name">)([^<]*)(</div>\s*<div class="desc">)([^<]*)(</div>)')
        m = pat.search(s)
        if not m:
            return {'ok': False, 'error': f'总览页找不到 slug={slug} 的卡片'}
        s = pat.sub(lambda mm: mm.group(1) + name + mm.group(3) + (desc if desc else mm.group(4)) + mm.group(5), s)
        open(idx, 'w', encoding='utf-8', newline='\n').write(s)
        msgs.append('✅ 总览页卡片名已更新')

        # 2) 浏览器标题：直接改发布仓 HTML 的 <title>（在线立即生效）
        if title:
            html_path = os.path.join(REPO, slug, 'index.html')
            if os.path.isfile(html_path):
                hs = open(html_path, encoding='utf-8').read()
                hs2 = re.sub(r'<title>.*?</title>', f'<title>{title}</title>', hs, count=1, flags=re.S)
                if hs2 != hs:
                    open(html_path, 'w', encoding='utf-8', newline='').write(hs2)
                    msgs.append(f'✅ 浏览器标题已设置: {title}')
                else:
                    msgs.append('⚠️ 发布仓 HTML 未找到 <title>，跳过')
            else:
                msgs.append(f'⚠️ 找不到 {slug}/index.html，标题未改（重新发布后由配置生效）')

        # 3) 更新项目 publish-config.json（按 slug 匹配）
        for proj in scan_projects():
            cfg_path = os.path.join(proj['path'], 'publish-config.json')
            try:
                cfg = json.load(open(cfg_path, encoding='utf-8'))
            except Exception:
                continue
            items = cfg.get('prototypes') if isinstance(cfg.get('prototypes'), list) else [cfg]
            hit = None
            for it in items:
                if it.get('slug') == slug:
                    hit = it
                    break
            if hit:
                hit['name'] = name
                if desc:
                    hit['desc'] = desc
                if title:
                    hit['title'] = title
                json.dump(cfg, open(cfg_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
                ok, out = git_push(proj['path'])
                msgs.append(('✅' if ok else '⚠️') + f' 项目配置 {proj["dir"]} 已更新' + ('' if ok else f'（push: {out[-200:]}）'))

        # 4) push 发布仓
        ok, out = git_push(REPO)
        msgs.append(('✅' if ok else '⚠️') + f' 发布仓已推送' + ('' if ok else f'（{out[-200:]}）'))
        return {'ok': ok, 'msgs': msgs}

    def cmd_publish(self, body):
        """发布：body={project_dir}，跑 publish-preview.sh --project"""
        proj = (body.get('project_dir') or '').strip()
        if not proj or not os.path.isdir(proj):
            return {'ok': False, 'error': 'project_dir 无效'}
        if not BASH:
            return {'ok': False, 'error': '未找到 git-bash (bash.exe)，请安装 Git for Windows 或检查路径'}
        code, out = run([BASH, SCRIPT, '--project', proj])
        return {'ok': code == 0, 'output': out}

    def cmd_remove(self, body):
        """下线：body={slug}，跑 publish-preview.sh --remove"""
        slug = (body.get('slug') or '').strip()
        if not slug:
            return {'ok': False, 'error': 'slug 必填'}
        if not BASH:
            return {'ok': False, 'error': '未找到 git-bash (bash.exe)，请安装 Git for Windows 或检查路径'}
        code, out = run([BASH, SCRIPT, '--remove', slug])
        return {'ok': code == 0, 'output': out}


if __name__ == '__main__':
    print(f'原型管理工具服务已启动: http://localhost:{PORT}')
    print('按 Ctrl+C 停止')
    try:
        HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print('\n已停止')
