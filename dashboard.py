#!/usr/bin/env python3
"""Lieutenant — local web UI for monitoring tmux-based Claude agents."""

import http.server
import json
import os
import subprocess
import re
import time
import glob as globmod
from pathlib import Path
from urllib.parse import urlparse, parse_qs

SWARM_BASE = Path.home() / ".micolash" / "swarm"
CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"
CLAUDE_SESSIONS = Path.home() / ".claude" / "sessions"
CAGES_DIR = Path.home() / ".micolash" / "cages"
PORT = 7777

# In-memory history of agents we've seen, so completed ones persist after tmux window closes
_agent_history = {}  # id -> {name, phase, last_line, session_id, window, finished_at}


# ─── tmux helpers ───────────────────────────────────────────────────────────

def tmux_windows():
    try:
        out = subprocess.check_output(
            ["tmux", "list-windows", "-t", "swarm", "-F",
             "#{window_index}|#{window_name}|#{window_active}|#{pane_pid}"],
            text=True, stderr=subprocess.DEVNULL
        )
        windows = []
        for line in out.strip().splitlines():
            parts = line.split("|")
            idx, name, active = parts[0], parts[1], parts[2]
            pane_pid = parts[3] if len(parts) > 3 else ""
            windows.append({
                "index": int(idx), "name": name,
                "active": active == "1", "pane_pid": pane_pid
            })
        return windows
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []


def tmux_capture(window_name, lines=80):
    try:
        out = subprocess.check_output(
            ["tmux", "capture-pane", "-t", f"swarm:{window_name}",
             "-p", "-S", f"-{lines}"],
            text=True, stderr=subprocess.DEVNULL
        )
        return out
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def tmux_send(window_name, message):
    try:
        subprocess.check_call(
            ["tmux", "send-keys", "-t", f"swarm:{window_name}", message, "Enter"],
            stderr=subprocess.DEVNULL
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


# ─── Claude transcript helpers ──────────────────────────────────────────────

def find_session_for_pid(pid):
    try:
        for session_file in CLAUDE_SESSIONS.glob("*.json"):
            data = json.loads(session_file.read_text())
            if str(data.get("pid")) == str(pid):
                return data.get("sessionId")
    except (json.JSONDecodeError, OSError):
        pass
    return None


def find_session_for_pane(pane_pid):
    if not pane_pid:
        return None
    try:
        out = subprocess.check_output(
            ["pgrep", "-P", str(pane_pid)],
            text=True, stderr=subprocess.DEVNULL
        )
        for child_pid in out.strip().splitlines():
            session_id = find_session_for_pid(child_pid.strip())
            if session_id:
                return session_id
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return None


def find_transcript_file(session_id):
    if not session_id:
        return None
    for project_dir in CLAUDE_PROJECTS.iterdir():
        if not project_dir.is_dir():
            continue
        candidate = project_dir / f"{session_id}.jsonl"
        if candidate.exists():
            return candidate
    return None


def read_transcript(session_id, last_n=50):
    path = find_transcript_file(session_id)
    if not path:
        return []
    messages = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    messages.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        return []
    return messages[-last_n:]


def detect_phase_from_transcript(messages):
    if not messages:
        return "starting"
    for msg in reversed(messages[-5:]):
        message = msg.get("message", {})
        content = message.get("content", [])
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    name = block.get("name", "")
                    if name in ("Edit", "Write", "NotebookEdit"):
                        return "implementing"
                    if name == "Bash":
                        cmd = block.get("input", {}).get("command", "")
                        if "test" in cmd or "jest" in cmd or "pytest" in cmd:
                            return "testing"
                        if "git push" in cmd:
                            return "pushing"
                        if "gh pr create" in cmd:
                            return "done-pr"
                        return "executing"
                    if name in ("Read", "Grep", "Glob"):
                        return "analyzing"
                if block.get("type") == "text":
                    text = block.get("text", "").lower()
                    if "error" in text or "failed" in text:
                        return "error"
                    if "pr created" in text:
                        return "done-pr"
    return "working"


def detect_phase_from_tmux(text):
    recent = text[-3000:] if len(text) > 3000 else text
    lower = recent.lower()
    if "pr created" in lower or "gh pr create" in lower:
        return "done-pr"
    if "git push" in lower:
        return "pushing"
    last_500 = lower[-500:]
    if "error" in last_500 or "failed" in last_500:
        return "error"
    if "yarn test" in lower or "jest" in lower or "pytest" in lower:
        return "testing"
    if "edit(" in lower or "write(" in lower:
        return "implementing"
    if "grep" in lower or "glob" in lower or "read(" in lower:
        return "analyzing"
    return "working"


def detect_validator_phase(text):
    lower = text[-2000:].lower() if len(text) > 2000 else text.lower()
    if "verdict:" in lower or "summary" in lower:
        if "block" in lower:
            return "verdict-block"
        if "pass" in lower:
            return "verdict-pass"
        if "review" in lower:
            return "verdict-review"
        return "verdict"
    if "challenge:" in lower or "[wrong]" in lower or "[unverified]" in lower:
        return "attacking"
    if "grep" in lower or "read(" in lower or "bash" in lower:
        return "investigating"
    return "analyzing"


# ─── HTML ───────────────────────────────────────────────────────────────────

DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lieutenant</title>
<style>
  :root {
    --bg: #0d1117; --surface: #161b22; --surface2: #21262d;
    --border: #30363d; --text: #e6edf3; --text-dim: #8b949e;
    --accent: #58a6ff; --green: #3fb950; --yellow: #d29922;
    --red: #f85149; --purple: #bc8cff; --orange: #f0883e; --cyan: #39d2c0;
  }
  * { margin:0; padding:0; box-sizing:border-box; }
  body {
    font-family: 'SF Mono','Fira Code','Cascadia Code',monospace;
    background: var(--bg); color: var(--text);
    height: 100vh; display: flex; flex-direction: column; overflow: hidden;
  }

  .topbar {
    background: var(--surface); border-bottom: 1px solid var(--border);
    padding: 8px 16px; display: flex; align-items: center; justify-content: space-between;
    flex-shrink: 0;
  }
  .topbar h1 { font-size: 13px; font-weight: 600; color: var(--accent); letter-spacing: 0.5px; }
  .topbar .meta { font-size: 11px; color: var(--text-dim); display: flex; gap: 14px; align-items: center; }

  .main { display: flex; flex: 1; overflow: hidden; }

  /* ── Sidebar ── */
  .sidebar {
    width: 220px; background: var(--surface); border-right: 1px solid var(--border);
    display: flex; flex-direction: column; flex-shrink: 0; overflow-y: auto;
  }
  .sb-section { border-bottom: 1px solid var(--border); }
  .sb-header {
    padding: 6px 12px; font-size: 9px; text-transform: uppercase;
    letter-spacing: 1.2px; color: var(--text-dim); background: var(--surface2);
  }
  .card {
    padding: 8px 12px; border-bottom: 1px solid var(--border);
    cursor: pointer; transition: background 0.1s;
  }
  .card:hover { background: var(--surface2); }
  .card.selected { background: var(--surface2); border-left: 3px solid var(--accent); padding-left: 9px; }
  .card .name { font-size: 11px; font-weight: 600; display: flex; align-items: center; gap: 6px; }
  .card .detail { font-size: 9px; color: var(--text-dim); margin-top: 2px;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  .dot {
    width: 6px; height: 6px; border-radius: 50%; display: inline-block; flex-shrink: 0;
  }
  .dot.starting { background: var(--text-dim); animation: pulse 1.5s infinite; }
  .dot.setup,.dot.analyzing { background: var(--accent); }
  .dot.implementing,.dot.executing { background: var(--yellow); }
  .dot.testing { background: var(--orange); }
  .dot.pushing { background: var(--green); animation: pulse 1s infinite; }
  .dot.done-pr { background: var(--green); }
  .dot.done { background: var(--green); }
  .dot.error { background: var(--red); animation: pulse 0.5s infinite; }
  .dot.working { background: var(--text-dim); }
  .dot.orchestrator { background: var(--cyan); animation: pulse 2s infinite; }
  /* Validator dots */
  .dot.investigating { background: var(--purple); }
  .dot.attacking { background: var(--red); animation: pulse 0.8s infinite; }
  .dot.verdict { background: var(--yellow); }
  .dot.verdict-pass { background: var(--green); }
  .dot.verdict-block { background: var(--red); }
  .dot.verdict-review { background: var(--orange); }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.3} }

  /* ── Panels ── */
  .panels { flex: 1; display: flex; overflow: hidden; }

  .panel {
    flex: 1; display: flex; flex-direction: column; overflow: hidden;
    border-right: 1px solid var(--border);
  }
  .panel:last-child { border-right: none; }
  .panel-header {
    padding: 6px 12px; background: var(--surface); border-bottom: 1px solid var(--border);
    display: flex; align-items: center; justify-content: space-between; flex-shrink: 0;
  }
  .panel-header h2 { font-size: 11px; font-weight: 600; }
  .panel-header .tag {
    font-size: 9px; padding: 1px 6px; border-radius: 3px;
    text-transform: uppercase; letter-spacing: 0.5px;
  }
  .tag.se { background: rgba(88,166,255,0.15); color: var(--accent); }
  .tag.val { background: rgba(248,81,73,0.15); color: var(--red); }
  .panel-header .btns { display: flex; gap: 4px; }
  .panel-header .btns button {
    background: var(--surface2); border: 1px solid var(--border); color: var(--text);
    padding: 2px 8px; border-radius: 3px; font-size: 9px; font-family: inherit; cursor: pointer;
  }
  .panel-header .btns button:hover { background: var(--border); }
  .panel-header .btns button.active { background: var(--accent); color: var(--bg); border-color: var(--accent); }
  .panel-header .btns button.danger { border-color: var(--red); color: var(--red); }

  .panel-body {
    flex: 1; overflow-y: auto; padding: 10px 12px;
    font-size: 11px; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word;
  }

  .cmd-bar {
    background: var(--surface); border-top: 1px solid var(--border);
    padding: 6px 12px; display: flex; gap: 4px; flex-shrink: 0;
  }
  .cmd-bar input {
    flex: 1; background: var(--surface2); border: 1px solid var(--border);
    color: var(--text); padding: 5px 8px; border-radius: 4px;
    font-family: inherit; font-size: 11px; outline: none;
  }
  .cmd-bar input:focus { border-color: var(--accent); }
  .cmd-bar button {
    background: var(--accent); color: var(--bg); border: none;
    padding: 5px 10px; border-radius: 4px; font-family: inherit;
    font-size: 11px; font-weight: 600; cursor: pointer;
  }

  .empty {
    flex: 1; display: flex; align-items: center; justify-content: center;
    color: var(--text-dim); font-size: 11px; text-align: center; padding: 20px;
  }

  /* Message blocks */
  .mb { margin-bottom: 6px; }
  .mb-user { border-left: 2px solid var(--yellow); padding-left: 8px; }
  .mb-user .ml { color: var(--yellow); font-weight: 600; font-size: 9px; margin-bottom: 1px; }
  .mb-agent { border-left: 2px solid var(--accent); padding-left: 8px; }
  .mb-agent .ml { color: var(--accent); font-weight: 600; font-size: 9px; margin-bottom: 1px; }
  .mb-tool { color: var(--purple); font-size: 9px; opacity: 0.8; }
  /* Validator-specific message styles */
  .mb-challenge { border-left: 2px solid var(--red); padding-left: 8px; margin: 4px 0; }
  .mb-challenge .ml { color: var(--red); font-weight: 600; font-size: 9px; }
  .mb-verdict-pass { border-left: 2px solid var(--green); padding-left: 8px; }
  .mb-verdict-pass .ml { color: var(--green); font-weight: 600; font-size: 9px; }
  .mb-verdict-block { border-left: 2px solid var(--red); padding-left: 8px; background: rgba(248,81,73,0.05); }
  .mb-verdict-block .ml { color: var(--red); font-weight: 600; font-size: 9px; }
  .c-red { color: var(--red); }
  .c-green { color: var(--green); }
  .c-yellow { color: var(--yellow); }
  .c-purple { color: var(--purple); }
  .c-dim { color: var(--text-dim); }

  ::-webkit-scrollbar { width: 4px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }
</style>
</head>
<body>

<div class="topbar">
  <h1>LIEUTENANT</h1>
  <div class="meta" id="topMeta"></div>
</div>

<div class="main">
  <div class="sidebar" id="sidebar">
    <div class="sb-section">
      <div class="sb-header">Orchestrator</div>
      <div id="orchSlot"></div>
    </div>
    <div class="sb-section">
      <div class="sb-header">SE Agents</div>
      <div id="seList"></div>
    </div>
    <div class="sb-section">
      <div class="sb-header">Validators</div>
      <div id="valList"></div>
    </div>
  </div>

  <div class="panels" id="panels">
    <!-- SE Panel -->
    <div class="panel" id="sePanel">
      <div class="panel-header" id="seHeader" style="display:none">
        <div style="display:flex;align-items:center;gap:8px">
          <span class="tag se">SE</span>
          <h2 id="seTitle"></h2>
        </div>
        <div class="btns">
          <button class="active" onclick="setSeView('transcript')">Transcript</button>
          <button onclick="setSeView('tmux')">Terminal</button>
          <button onclick="setSeView('diff')">Diff</button>
          <button onclick="setSeView('artifacts')">Artifacts</button>
          <button onclick="focusWindow(selectedSe)">Focus</button>
          <button class="danger" onclick="killWindow(selectedSe)">Kill</button>
        </div>
      </div>
      <div class="panel-body" id="seBody">
        <div class="empty">Select an agent to view its conversation</div>
      </div>
      <div class="cmd-bar" id="seCmdBar" style="display:none">
        <input id="seInput" placeholder="Send to SE agent..." onkeydown="if(event.key==='Enter')sendToSe()">
        <button onclick="sendToSe()">Send</button>
      </div>
    </div>

    <!-- Validation Panel -->
    <div class="panel" id="valPanel">
      <div class="panel-header" id="valHeader" style="display:none">
        <div style="display:flex;align-items:center;gap:8px">
          <span class="tag val">VALIDATOR</span>
          <h2 id="valTitle"></h2>
        </div>
        <div class="btns">
          <button class="active" onclick="setValView('transcript')">Challenges</button>
          <button onclick="setValView('tmux')">Terminal</button>
          <button onclick="focusWindow(selectedVal)">Focus</button>
        </div>
      </div>
      <div class="panel-body" id="valBody">
        <div class="empty">
          Validator appears when an SE agent's work is challenged.<br><br>
          The validator attacks claims, greps for evidence,<br>
          and issues verdicts: CONFIRMED / WRONG / UNVERIFIED.
        </div>
      </div>
    </div>
  </div>
</div>

<script>
let selectedSe = null;   // {id, window, session_id}
let selectedVal = null;   // {id, window, session_id}
let agents = {};          // se agents
let validators = {};      // val agents
let seView = 'transcript';
let valView = 'transcript';
let autoScrollSe = true, autoScrollVal = true;

const $ = s => document.querySelector(s);
const api = async p => (await fetch('/api'+p)).json();
const apiPost = async (p,b) => (await fetch('/api'+p,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)})).json();
function esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

function card(id, name, phase, detail, sel, alive) {
  const s = sel === id ? 'selected' : '';
  const dead = alive === false ? ' style="opacity:0.5"' : '';
  const label = alive === false ? (phase === 'done-pr' ? 'done (PR)' : phase === 'done' ? 'done' : phase === 'error' ? 'error' : 'finished') : phase;
  return `<div class="card ${s}"${dead} onclick="selectItem('${id}')">
    <div class="name"><span class="dot ${phase}"></span>${esc(name)}<span style="margin-left:auto;font-size:8px;color:${alive===false?'var(--green)':'var(--text-dim)'};text-transform:uppercase">${esc(label)}</span></div>
    <div class="detail">${detail?esc(detail):''}</div>
  </div>`;
}

async function refresh() {
  const data = await api('/agents');
  const wins = data.windows || [];
  agents = {}; validators = {};

  // Orchestrator
  const orch = wins.find(w => w.name === 'orchestrator');
  if (orch) {
    $('#orchSlot').innerHTML = card('orch:orchestrator','orchestrator','orchestrator',
      orch.session_id?'claude':'shell', selectedSe?.id);
    agents['orch:orchestrator'] = {window:'orchestrator', session_id:orch.session_id, phase:'orchestrator'};
  }

  // SE agents — show all (alive first, then finished)
  const seWins = wins.filter(w => w.name.startsWith('se/'));
  const seAlive = seWins.filter(w => w.alive !== false);
  const seDone = seWins.filter(w => w.alive === false);
  const seAll = [...seAlive, ...seDone];
  if (!seAll.length) {
    $('#seList').innerHTML = '<div style="padding:10px 12px;font-size:10px;color:var(--text-dim)">No agents</div>';
  } else {
    $('#seList').innerHTML = seAll.map(w => {
      const ticket = w.name.replace('se/','');
      const id = 'se:'+ticket;
      agents[id] = {window:w.name, session_id:w.session_id, phase:w.phase||'working', last_line:w.last_line||'', alive:w.alive!==false};
      return card(id, ticket, w.phase||'working', w.last_line||'', selectedSe?.id, w.alive!==false);
    }).join('');
  }

  // Validators — show all (alive first, then finished)
  const valWins = wins.filter(w => w.name.startsWith('val/'));
  const valAlive = valWins.filter(w => w.alive !== false);
  const valDone = valWins.filter(w => w.alive === false);
  const valAll = [...valAlive, ...valDone];
  if (!valAll.length) {
    $('#valList').innerHTML = '<div style="padding:10px 12px;font-size:10px;color:var(--text-dim)">No validators</div>';
  } else {
    $('#valList').innerHTML = valAll.map(w => {
      const ticket = w.name.replace('val/','');
      const id = 'val:'+ticket;
      validators[id] = {window:w.name, session_id:w.session_id, phase:w.val_phase||'analyzing', last_line:w.last_line||'', alive:w.alive!==false};
      return card(id, ticket, w.val_phase||'analyzing', w.last_line||'', selectedVal?.id, w.alive!==false);
    }).join('');
  }

  // Top bar summary
  const seCount = seAll.length, seWorkingCount = seAlive.length, seDoneCount = seDone.length;
  const valCount = valAll.length;
  const phases = seAll.map(w => w.phase||'working');
  const counts = {}; phases.forEach(p => counts[p]=(counts[p]||0)+1);
  const phaseStr = Object.entries(counts).map(([p,c]) => `${c} ${p}`).join(', ');
  const valPhases = valAll.map(w => w.val_phase||'analyzing');
  const vCounts = {}; valPhases.forEach(p => vCounts[p]=(vCounts[p]||0)+1);
  const vStr = Object.entries(vCounts).map(([p,c]) => `${c} ${p}`).join(', ');
  $('#topMeta').innerHTML = `${seCount} agents (${seWorkingCount} working, ${seDoneCount} done)${phaseStr?' — '+phaseStr:''}` +
    (valCount ? ` &mdash; ${valCount} validators${vStr?' ('+vStr+')':''}` : '');

  // Refresh panels
  if (selectedSe) await refreshSePanel();
  if (selectedVal) await refreshValPanel();
}

function selectItem(id) {
  const [type] = id.split(':');
  if (type === 'se' || type === 'orch') {
    const info = agents[id];
    if (!info) return;
    selectedSe = {id, ...info};
    $('#seHeader').style.display = 'flex';
    $('#seCmdBar').style.display = info.alive !== false ? 'flex' : 'none';
    $('#seTitle').textContent = id.replace('se:','').replace('orch:','') + (info.alive === false ? ' (finished)' : '');
    refreshSePanel();

    // Auto-select matching validator if exists
    const ticket = id.split(':')[1];
    const valId = 'val:'+ticket;
    if (validators[valId]) {
      selectedVal = {id:valId, ...validators[valId]};
      $('#valHeader').style.display = 'flex';
      $('#valTitle').textContent = ticket;
      refreshValPanel();
    }
  } else if (type === 'val') {
    const info = validators[id];
    if (!info) return;
    selectedVal = {id, ...info};
    $('#valHeader').style.display = 'flex';
    $('#valTitle').textContent = id.replace('val:','');
    refreshValPanel();
  }
  refresh(); // re-render sidebar for selection
}

function setSeView(v) { seView = v; refreshSePanel();
  const map = {'transcript':'transcript','tmux':'terminal','diff':'diff','artifacts':'artifacts'};
  document.querySelectorAll('#seHeader .btns button').forEach(b =>
    b.classList.toggle('active', b.textContent.toLowerCase() === (map[v]||v))); }
function setValView(v) { valView = v; refreshValPanel();
  document.querySelectorAll('#valHeader .btns button').forEach(b =>
    b.classList.toggle('active', b.textContent.toLowerCase().includes(v==='transcript'?'challeng':v))); }

async function refreshSePanel() {
  if (!selectedSe) return;
  const el = $('#seBody');
  if (seView === 'transcript') {
    if (selectedSe.session_id) {
      const data = await api(`/transcript/${selectedSe.session_id}?last=60`);
      el.innerHTML = data.formatted || '<span class="c-dim">(no transcript yet)</span>';
    } else {
      const data = await api(`/capture/${selectedSe.window}`);
      el.innerHTML = `<span class="c-dim">${esc(data.content||'(empty)')}</span>`;
    }
  } else if (seView === 'tmux') {
    const data = await api(`/capture/${selectedSe.window}`);
    el.innerHTML = esc(data.content||'(empty)');
  } else if (seView === 'diff') {
    const ticket = selectedSe.id.split(':')[1];
    const data = await api(`/diff/${ticket}`);
    el.innerHTML = colorizeDiff(data.diff||'(no changes)');
  } else if (seView === 'artifacts') {
    const ticket = selectedSe.id.split(':')[1];
    const data = await api(`/artifacts/${ticket}`);
    el.innerHTML = renderArtifacts(data);
  }
  if (autoScrollSe) el.scrollTop = el.scrollHeight;
}

function renderArtifacts(data) {
  let html = '';
  // Status section
  html += '<div style="margin-bottom:12px">';
  html += '<div style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;margin-bottom:4px">Status</div>';
  html += `<div style="font-size:11px">${esc(data.status||'unknown')}</div>`;
  html += '</div>';
  // Commit log
  if (data.commits && data.commits.length) {
    html += '<div style="margin-bottom:12px">';
    html += '<div style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;margin-bottom:4px">Commits</div>';
    data.commits.forEach(c => {
      html += `<div style="margin-bottom:4px"><span class="c-yellow">${esc(c.hash)}</span> ${esc(c.message)}</div>`;
    });
    html += '</div>';
  }
  // Files changed
  if (data.files_changed) {
    html += '<div style="margin-bottom:12px">';
    html += '<div style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;margin-bottom:4px">Files Changed</div>';
    html += `<div>${esc(data.files_changed)}</div>`;
    html += '</div>';
  }
  // Diff stat
  if (data.diff_stat) {
    html += '<div style="margin-bottom:12px">';
    html += '<div style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;margin-bottom:4px">Diff Summary</div>';
    html += `<div>${colorizeDiff(data.diff_stat)}</div>`;
    html += '</div>';
  }
  // Full diff (collapsible)
  if (data.diff) {
    html += '<div style="margin-bottom:12px">';
    html += '<details><summary style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;cursor:pointer;margin-bottom:4px">Full Diff</summary>';
    html += `<div style="margin-top:4px">${colorizeDiff(data.diff)}</div>`;
    html += '</details></div>';
  }
  if (!html) html = '<span class="c-dim">(no artifacts yet)</span>';
  return html;
}

async function refreshValPanel() {
  if (!selectedVal) return;
  const el = $('#valBody');
  if (valView === 'transcript') {
    if (selectedVal.session_id) {
      const data = await api(`/transcript/${selectedVal.session_id}?last=60&validator=1`);
      el.innerHTML = data.formatted || '<span class="c-dim">(validator not started yet)</span>';
    } else {
      const data = await api(`/capture/${selectedVal.window}`);
      el.innerHTML = colorizeValidator(data.content||'(empty)');
    }
  } else if (valView === 'tmux') {
    const data = await api(`/capture/${selectedVal.window}`);
    el.innerHTML = esc(data.content||'(empty)');
  }
  if (autoScrollVal) el.scrollTop = el.scrollHeight;
}

function colorizeDiff(text) {
  return text.split('\n').map(l => {
    if (l.startsWith('+') && !l.startsWith('+++')) return `<span class="c-green">${esc(l)}</span>`;
    if (l.startsWith('-') && !l.startsWith('---')) return `<span class="c-red">${esc(l)}</span>`;
    if (l.startsWith('@@')) return `<span class="c-purple">${esc(l)}</span>`;
    if (l.startsWith('diff ') || l.startsWith('index ')) return `<span class="c-dim">${esc(l)}</span>`;
    return esc(l);
  }).join('\n');
}

function colorizeValidator(text) {
  return text.split('\n').map(l => {
    const lt = l.trim();
    if (/^\[WRONG\]/i.test(lt)) return `<span class="c-red" style="font-weight:600">${esc(l)}</span>`;
    if (/^\[UNVERIFIED\]/i.test(lt)) return `<span class="c-yellow" style="font-weight:600">${esc(l)}</span>`;
    if (/^\[SUSPICIOUS\]/i.test(lt)) return `<span class="c-yellow">${esc(l)}</span>`;
    if (/^\[CONFIRMED\]/i.test(lt)) return `<span class="c-green">${esc(l)}</span>`;
    if (/^CHALLENGE:/i.test(lt)) return `<span class="c-red" style="font-weight:600">${esc(l)}</span>`;
    if (/^VERDICT:/i.test(lt)) return `<span style="font-weight:600">${esc(l)}</span>`;
    if (/^BLOCK/i.test(lt)) return `<span class="c-red" style="font-weight:700;font-size:13px">${esc(l)}</span>`;
    if (/^PASS/i.test(lt)) return `<span class="c-green" style="font-weight:700;font-size:13px">${esc(l)}</span>`;
    if (/^REVIEW/i.test(lt)) return `<span class="c-yellow" style="font-weight:700;font-size:13px">${esc(l)}</span>`;
    if (/^(FILE|CLAIM|ACTION|EVIDENCE):/i.test(lt)) return `<span class="c-dim">${esc(l)}</span>`;
    return esc(l);
  }).join('\n');
}

async function sendToSe() {
  if (!selectedSe) return;
  const inp = $('#seInput'); const msg = inp.value.trim(); if (!msg) return;
  await apiPost(`/send/${selectedSe.window}`, {message:msg});
  inp.value = ''; setTimeout(refreshSePanel, 1500);
}

function focusWindow(sel) {
  if (!sel) return;
  fetch(`/api/focus/${sel.window}`, {method:'POST'});
}

async function killWindow(sel) {
  if (!sel || sel.id.startsWith('orch:')) return;
  if (!confirm(`Kill ${sel.id}?`)) return;
  await apiPost(`/kill/${sel.window}`, {});
  if (sel === selectedSe) { selectedSe=null; $('#seHeader').style.display='none'; $('#seCmdBar').style.display='none';
    $('#seBody').innerHTML='<div class="empty">Agent terminated</div>'; }
  refresh();
}

$('#seBody').addEventListener('scroll', function() {
  autoScrollSe = (this.scrollHeight - this.scrollTop - this.clientHeight) < 50; });
$('#valBody').addEventListener('scroll', function() {
  autoScrollVal = (this.scrollHeight - this.scrollTop - this.clientHeight) < 50; });

refresh();
setInterval(refresh, 4000);
</script>
</body>
</html>"""


# ─── Artifact collection ────────────────────────────────────────────────────

def _find_cage_workspace(ticket):
    """Find cage workspace for a ticket — try exact match, then glob."""
    exact = CAGES_DIR / ticket / "workspace"
    if exact.is_dir():
        return exact
    for cage_dir in CAGES_DIR.iterdir():
        if ticket.lower() in cage_dir.name.lower() and (cage_dir / "workspace").is_dir():
            return cage_dir / "workspace"
    return None


def collect_artifacts(ticket):
    """Gather commits, diff stat, files changed, and full diff for a ticket."""
    result = {"status": "unknown", "commits": [], "files_changed": "", "diff_stat": "", "diff": ""}

    workspace = _find_cage_workspace(ticket)
    if not workspace:
        result["status"] = "no cage found"
        return result

    def _git(args, **kwargs):
        return subprocess.check_output(
            ["git", "-C", str(workspace)] + args,
            text=True, stderr=subprocess.DEVNULL, timeout=10, **kwargs
        )

    try:
        # Branch name
        branch = _git(["branch", "--show-current"]).strip()
        result["status"] = f"branch: {branch}" if branch else "detached HEAD"

        # Commits on this branch (since it diverged from main/master)
        for base in ("main", "master", "development"):
            try:
                log = _git(["log", f"{base}..HEAD", "--oneline", "--no-decorate"])
                if log.strip():
                    result["commits"] = [
                        {"hash": line[:7], "message": line[8:]}
                        for line in log.strip().splitlines()[:20]
                    ]
                break
            except Exception:
                continue

        # Diff stat (committed changes vs base)
        for base in ("main", "master", "development"):
            try:
                stat = _git(["diff", "--stat", f"{base}..HEAD"])
                if stat.strip():
                    result["diff_stat"] = stat.strip()
                break
            except Exception:
                continue

        # Files changed
        for base in ("main", "master", "development"):
            try:
                files = _git(["diff", "--name-only", f"{base}..HEAD"])
                if files.strip():
                    result["files_changed"] = files.strip()
                break
            except Exception:
                continue

        # Full diff (committed + uncommitted)
        for base in ("main", "master", "development"):
            try:
                diff = _git(["diff", f"{base}..HEAD"])
                # Also append any uncommitted changes
                uncommitted = _git(["diff"])
                if uncommitted.strip():
                    diff += "\n# --- Uncommitted changes ---\n" + uncommitted
                if diff.strip():
                    result["diff"] = diff.strip()
                break
            except Exception:
                continue

    except Exception as e:
        result["status"] = f"error: {e}"

    return result


# ─── HTTP Server ────────────────────────────────────────────────────────────

class DashboardHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _html(self, content):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(content.encode())

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/" or path == "":
            self._html(DASHBOARD_HTML)
            return

        if path == "/api/agents":
            windows = tmux_windows()
            live_ids = set()
            for w in windows:
                w["session_id"] = find_session_for_pane(w.get("pane_pid"))

                if w["name"].startswith("se/"):
                    agent_id = "se:" + w["name"].replace("se/", "")
                    live_ids.add(agent_id)
                    if w["session_id"]:
                        msgs = read_transcript(w["session_id"], last_n=8)
                        w["phase"] = detect_phase_from_transcript(msgs)
                    else:
                        content = tmux_capture(w["name"], 30)
                        w["phase"] = detect_phase_from_tmux(content)
                    content = tmux_capture(w["name"], 5)
                    lines = [l for l in content.strip().splitlines() if l.strip()]
                    w["last_line"] = lines[-1][:80] if lines else ""
                    w["alive"] = True
                    # Track in history
                    _agent_history[agent_id] = {
                        "name": w["name"], "phase": w["phase"],
                        "last_line": w.get("last_line", ""),
                        "session_id": w.get("session_id"),
                        "window": w["name"], "alive": True,
                    }

                elif w["name"].startswith("val/"):
                    val_id = "val:" + w["name"].replace("val/", "")
                    live_ids.add(val_id)
                    content = tmux_capture(w["name"], 30)
                    w["val_phase"] = detect_validator_phase(content)
                    lines = [l for l in content.strip().splitlines() if l.strip()]
                    w["last_line"] = lines[-1][:80] if lines else ""
                    w["alive"] = True
                    _agent_history[val_id] = {
                        "name": w["name"], "val_phase": w.get("val_phase", "analyzing"),
                        "last_line": w.get("last_line", ""),
                        "session_id": w.get("session_id"),
                        "window": w["name"], "alive": True,
                    }

            # Mark agents no longer in tmux as finished
            for aid, info in _agent_history.items():
                if aid not in live_ids and info.get("alive"):
                    info["alive"] = False
                    info["finished_at"] = time.time()
                    # Terminal phase: done-pr if it was pushing, otherwise done
                    if info.get("phase") in ("pushing", "done-pr"):
                        info["phase"] = "done-pr"
                    elif info.get("phase") != "error":
                        info["phase"] = "done"

            # Inject finished agents as synthetic windows so the UI sees them
            for aid, info in _agent_history.items():
                if aid not in live_ids:
                    windows.append({
                        "index": -1, "name": info["name"],
                        "active": False, "pane_pid": "",
                        "session_id": info.get("session_id"),
                        "phase": info.get("phase", "done"),
                        "val_phase": info.get("val_phase", "done"),
                        "last_line": info.get("last_line", ""),
                        "alive": False,
                    })

            self._json({"windows": windows})
            return

        m = re.match(r"/api/transcript/(.+)", path)
        if m:
            session_id = m.group(1)
            last_n = int(params.get("last", [50])[0])
            is_validator = "1" in params.get("validator", ["0"])
            messages = read_transcript(session_id, last_n)
            if is_validator:
                formatted = format_validator_html(messages)
            else:
                formatted = format_transcript_html(messages)
            self._json({"formatted": formatted, "count": len(messages)})
            return

        m = re.match(r"/api/capture/(.+)", path)
        if m:
            content = tmux_capture(m.group(1), 200)
            self._json({"content": content})
            return

        m = re.match(r"/api/diff/(.+)", path)
        if m:
            ticket = m.group(1)
            try:
                stat = subprocess.check_output(
                    ["cage", "exec", ticket, "--", "git", "diff", "--stat"],
                    text=True, stderr=subprocess.DEVNULL, timeout=10)
                diff = subprocess.check_output(
                    ["cage", "exec", ticket, "--", "git", "diff"],
                    text=True, stderr=subprocess.DEVNULL, timeout=10)
                result = stat + "\n" + diff
            except Exception:
                result = "(could not get diff — cage may not exist)"
            self._json({"diff": result})
            return

        m = re.match(r"/api/artifacts/(.+)", path)
        if m:
            ticket = m.group(1)
            result = collect_artifacts(ticket)
            self._json(result)
            return

        self.send_error(404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        cl = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(cl)) if cl else {}

        m = re.match(r"/api/send/(.+)", path)
        if m:
            ok = tmux_send(m.group(1), body.get("message", ""))
            self._json({"ok": ok})
            return

        m = re.match(r"/api/focus/(.+)", path)
        if m:
            try:
                subprocess.check_call(["tmux", "select-window", "-t", f"swarm:{m.group(1)}"], stderr=subprocess.DEVNULL)
                self._json({"ok": True})
            except Exception:
                self._json({"ok": False})
            return

        m = re.match(r"/api/kill/(.+)", path)
        if m:
            wn = m.group(1)
            try:
                subprocess.call(["tmux", "send-keys", "-t", f"swarm:{wn}", "C-c", ""], stderr=subprocess.DEVNULL)
                time.sleep(0.5)
                subprocess.call(["tmux", "send-keys", "-t", f"swarm:{wn}", "/exit", "Enter"], stderr=subprocess.DEVNULL)
                time.sleep(1.5)
                subprocess.call(["tmux", "kill-window", "-t", f"swarm:{wn}"], stderr=subprocess.DEVNULL)
                self._json({"ok": True})
            except Exception:
                self._json({"ok": False})
            return

        self.send_error(404)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()


def esc_html(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def summarize_tool(name, inp):
    if name == "Read": return inp.get("file_path", "?")
    if name in ("Edit", "Write"): return inp.get("file_path", "?")
    if name == "Bash":
        cmd = inp.get("command", "?")
        return cmd[:140] + "..." if len(cmd) > 140 else cmd
    if name == "Grep": return f'pattern="{inp.get("pattern", "?")}"'
    if name == "Glob": return inp.get("pattern", "?")
    return str(inp)[:100]


def format_transcript_html(messages):
    parts = []
    for msg in messages:
        msg_type = msg.get("type")
        message = msg.get("message", {})

        if msg_type == "user":
            content = message.get("content", "")
            text = ""
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                text = "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
            if text.strip():
                if len(text) > 500: text = text[:500] + "\n... (truncated)"
                parts.append(f'<div class="mb mb-user"><div class="ml">USER</div>{esc_html(text)}</div>')
            continue

        if message.get("role") == "assistant":
            content = message.get("content", [])
            if isinstance(content, list):
                text_parts, tool_parts = [], []
                for block in content:
                    if not isinstance(block, dict): continue
                    bt = block.get("type")
                    if bt == "text":
                        t = block.get("text", "")
                        if t.strip(): text_parts.append(t)
                    elif bt == "tool_use":
                        name = block.get("name", "?")
                        summary = summarize_tool(name, block.get("input", {}))
                        tool_parts.append(f'<div class="mb-tool">[{esc_html(name)}] {esc_html(summary)}</div>')
                combined = ""
                if text_parts: combined += esc_html("\n".join(text_parts))
                if tool_parts: combined += "\n".join(tool_parts)
                if combined.strip():
                    parts.append(f'<div class="mb mb-agent"><div class="ml">AGENT</div>{combined}</div>')
    return "\n".join(parts) if parts else ""


def format_validator_html(messages):
    """Format validator transcript with challenge/verdict highlighting."""
    parts = []
    for msg in messages:
        msg_type = msg.get("type")
        message = msg.get("message", {})

        if msg_type == "user":
            content = message.get("content", "")
            text = content if isinstance(content, str) else ""
            if isinstance(content, list):
                text = "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
            if text.strip():
                if len(text) > 300: text = text[:300] + "\n... (truncated)"
                parts.append(f'<div class="mb mb-user"><div class="ml">PROMPT</div>{esc_html(text)}</div>')
            continue

        if message.get("role") == "assistant":
            content = message.get("content", [])
            if isinstance(content, list):
                text_parts, tool_parts = [], []
                for block in content:
                    if not isinstance(block, dict): continue
                    bt = block.get("type")
                    if bt == "text":
                        t = block.get("text", "")
                        if t.strip():
                            # Colorize validator-specific patterns
                            colored = colorize_validator_text(t)
                            text_parts.append(colored)
                    elif bt == "tool_use":
                        name = block.get("name", "?")
                        summary = summarize_tool(name, block.get("input", {}))
                        tool_parts.append(f'<div class="mb-tool">[{esc_html(name)}] {esc_html(summary)}</div>')
                combined = ""
                if text_parts: combined += "\n".join(text_parts)
                if tool_parts: combined += "\n".join(tool_parts)
                if combined.strip():
                    parts.append(f'<div class="mb mb-agent"><div class="ml">VALIDATOR</div>{combined}</div>')
    return "\n".join(parts) if parts else ""


def colorize_validator_text(text):
    """Apply color to validator output patterns."""
    lines = []
    for line in text.split("\n"):
        lt = line.strip()
        if lt.startswith("[WRONG]") or lt.startswith("WRONG"):
            lines.append(f'<span class="c-red" style="font-weight:600">{esc_html(line)}</span>')
        elif lt.startswith("[UNVERIFIED]") or lt.startswith("UNVERIFIED"):
            lines.append(f'<span class="c-yellow" style="font-weight:600">{esc_html(line)}</span>')
        elif lt.startswith("[SUSPICIOUS]"):
            lines.append(f'<span class="c-yellow">{esc_html(line)}</span>')
        elif lt.startswith("[CONFIRMED]") or lt.startswith("CONFIRMED"):
            lines.append(f'<span class="c-green">{esc_html(line)}</span>')
        elif lt.startswith("CHALLENGE:"):
            lines.append(f'<span class="c-red" style="font-weight:600">{esc_html(line)}</span>')
        elif lt.startswith("VERDICT:") or lt.startswith("Risk assessment:"):
            lines.append(f'<span style="font-weight:700">{esc_html(line)}</span>')
        elif lt.startswith("BLOCK"):
            lines.append(f'<span class="c-red" style="font-weight:700;font-size:13px">{esc_html(line)}</span>')
        elif lt.startswith("PASS"):
            lines.append(f'<span class="c-green" style="font-weight:700;font-size:13px">{esc_html(line)}</span>')
        elif lt.startswith("REVIEW"):
            lines.append(f'<span class="c-yellow" style="font-weight:700;font-size:13px">{esc_html(line)}</span>')
        elif any(lt.startswith(p) for p in ("FILE:", "CLAIM:", "ACTION:", "QUANTITATIVE EVIDENCE:", "QUALITATIVE NOTE:")):
            lines.append(f'<span class="c-dim">{esc_html(line)}</span>')
        elif lt.startswith("[TIER"):
            lines.append(f'<span class="c-purple" style="font-weight:600">{esc_html(line)}</span>')
        else:
            lines.append(esc_html(line))
    return "\n".join(lines)


def main():
    import socketserver
    socketserver.TCPServer.allow_reuse_address = True
    server = http.server.HTTPServer(("127.0.0.1", PORT), DashboardHandler)
    server.allow_reuse_address = True
    print(f"Lieutenant → http://localhost:{PORT}")
    print(f"Watching tmux session: swarm")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
