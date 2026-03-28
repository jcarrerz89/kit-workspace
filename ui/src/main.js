import { invoke } from '@tauri-apps/api/core'

async function writeFile(path, content) {
  return invoke('write_file', { path, content })
}

// ── Settings ───────────────────────────────────────────────
const settings = {
  kwsPath: localStorage.getItem('kwsPath') || '',
  kwsDir:  localStorage.getItem('kwsDir')  || '',
}

function saveSettings() {
  settings.kwsPath = document.getElementById('kws-path').value.trim()
  settings.kwsDir  = document.getElementById('kws-dir').value.trim()
  localStorage.setItem('kwsPath', settings.kwsPath)
  localStorage.setItem('kwsDir',  settings.kwsDir)
  const status = document.getElementById('settings-status')
  status.textContent = 'Saved.'
  setTimeout(() => { status.textContent = '' }, 2000)
}

// ── Kit command runner ─────────────────────────────────────
async function kit(...args) {
  if (!settings.kwsPath) return { stdout: '', stderr: 'kit-workspace path not set. Go to Settings.', success: false }
  return invoke('run_kit_command', { kwsPath: settings.kwsPath, args })
}

async function readFile(path) {
  return invoke('read_file', { path })
}

async function listDir(path) {
  return invoke('list_dir', { path }).catch(() => [])
}

async function homeDir() {
  return invoke('home_dir')
}

// ── Tab routing ────────────────────────────────────────────
let activeTab = 'dashboard'
let logRefreshTimer = null

function switchTab(name) {
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === name))
  document.querySelectorAll('.tab-content').forEach(s => s.classList.toggle('active', s.id === `tab-${name}`))
  activeTab = name
  clearInterval(logRefreshTimer)
  loadTab(name)
}

async function loadTab(name) {
  if (name === 'dashboard') await loadDashboard()
  if (name === 'projects')  await loadProjects()
  if (name === 'history')   await loadHistory()
  if (name === 'logs')      await loadLogs()
  if (name === 'settings')  loadSettingsForm()
}

// ── Dashboard ──────────────────────────────────────────────
async function loadDashboard() {
  const tbody = document.getElementById('jobs-body')
  tbody.innerHTML = '<tr><td colspan="6" class="empty">Loading…</td></tr>'

  try {
    const home = await homeDir()
    const stateDir = `${home}/.kit-workspace/state`
    const jobDirs = await listDir(stateDir)

    if (!jobDirs.length) {
      tbody.innerHTML = '<tr><td colspan="6" class="empty">No jobs yet. Click <strong>+ Run Job</strong> to start.</td></tr>'
      return
    }

    const rows = await Promise.all(jobDirs.map(async jobId => {
      const base = `${stateDir}/${jobId}`
      const [status, startedAt, jobJsonRaw, sessionType] = await Promise.all([
        readFile(`${base}/status`).catch(() => 'unknown'),
        readFile(`${base}/started_at`).catch(() => '—'),
        readFile(`${base}/job.json`).catch(() => null),
        readFile(`${base}/type`).catch(() => ''),
      ])
      let jobName = jobId
      if (jobJsonRaw) {
        try { jobName = JSON.parse(jobJsonRaw).name || jobId } catch {}
      }
      return {
        jobId,
        jobName,
        status:      status.trim(),
        startedAt:   startedAt.trim().slice(0, 16),
        sessionType: sessionType.trim(),
      }
    }))

    rows.sort((a, b) => b.jobId.localeCompare(a.jobId))

    tbody.innerHTML = rows.map(r => `
      <tr>
        <td class="mono">${r.jobId}</td>
        <td>${escHtml(r.jobName)}</td>
        <td>${statusBadge(r.status)}</td>
        <td>${r.sessionType ? typeBadge(r.sessionType) : '<span class="type-pending">—</span>'}</td>
        <td class="mono">${r.startedAt}</td>
        <td>
          <div style="display:flex;gap:6px">
            ${r.status === 'completed' ? `<button class="btn btn-sm btn-primary" onclick="mergeJob('${r.jobId}')">Merge</button>` : ''}
            ${r.status === 'running'   ? `<button class="btn btn-sm btn-danger"  onclick="stopJob('${r.jobId}')">Stop</button>` : ''}
            <button class="btn btn-sm" onclick="viewLogs('${r.jobId}')">Logs</button>
          </div>
        </td>
      </tr>`).join('')
  } catch (e) {
    tbody.innerHTML = `<tr><td colspan="6" class="empty">${escHtml(String(e))}</td></tr>`
  }
}

// ── Projects ───────────────────────────────────────────────
function _projectRow(name, p, indent) {
  const driverBadge = p.driver === 'petfi-kit'
    ? '<span class="badge badge-running">petfi-kit</span>'
    : '<span class="badge badge-unknown">generic</span>'
  return `
    <div class="proj-row${indent ? ' proj-row-nested' : ''}">
      <div class="proj-row-name">
        ${indent ? '<span class="proj-tree-branch"></span>' : ''}
        <strong>${escHtml(name)}</strong>
      </div>
      <div class="proj-row-driver">${driverBadge}</div>
      <div class="proj-row-path mono">${escHtml(p.path)}</div>
      <div class="proj-row-actions">
        <button class="btn btn-sm btn-primary"
          onclick="openSessionModal('${escHtml(name)}', ${JSON.stringify([name])})">
          + Session
        </button>
      </div>
    </div>`
}

async function loadProjects() {
  const tree = document.getElementById('projects-tree')
  tree.innerHTML = '<div class="empty">Loading…</div>'

  try {
    const home = await homeDir()
    const raw = await readFile(`${home}/.kit-workspace/workspace.json`)
    const ws = JSON.parse(raw)
    const projects = ws.projects || {}
    const apps = ws.apps || {}

    const appEntries = Object.entries(apps)
    const groupedProjects = new Set(Object.values(apps).flat())
    const standaloneProjects = Object.entries(projects).filter(([n]) => !groupedProjects.has(n))

    const html = []

    // ── App groups ──────────────────────────────────────────
    for (const [appName, projectList] of appEntries) {
      html.push(`
        <div class="app-group">
          <div class="app-group-header">
            <div class="app-group-title">
              <span class="app-group-icon">⬡</span>
              <strong>${escHtml(appName)}</strong>
              <span class="app-group-count">${projectList.length} project${projectList.length !== 1 ? 's' : ''}</span>
            </div>
            <button class="btn btn-sm btn-primary"
              onclick="openSessionModal('${escHtml(appName)}', ${JSON.stringify(projectList)})">
              + Session
            </button>
          </div>
          <div class="app-group-children">`)

      for (const pName of projectList) {
        const p = projects[pName]
        if (p) html.push(_projectRow(pName, p, true))
      }

      html.push('</div></div>')
    }

    // ── Standalone projects ─────────────────────────────────
    if (standaloneProjects.length) {
      if (appEntries.length) {
        html.push('<div class="standalone-label">Standalone projects</div>')
      }
      for (const [name, p] of standaloneProjects) {
        html.push(_projectRow(name, p, false))
      }
    }

    if (!html.length) {
      tree.innerHTML = '<div class="empty">No projects registered yet.</div>'
      return
    }

    tree.innerHTML = html.join('')
  } catch (e) {
    tree.innerHTML = `<div class="empty">${escHtml(String(e))}</div>`
  }
}

// ── History ────────────────────────────────────────────────
async function loadHistory() {
  const container = document.getElementById('history-list')
  container.innerHTML = '<p class="empty">Loading…</p>'

  try {
    if (!settings.kwsDir) {
      container.innerHTML = '<p class="empty">Set the kit-workspace directory in Settings.</p>'
      return
    }
    const raw = await readFile(`${settings.kwsDir}/history.json`)
    const entries = JSON.parse(raw)

    if (!entries.length) {
      container.innerHTML = '<p class="empty">No history yet. Merge a job to start tracking.</p>'
      return
    }

    container.innerHTML = [...entries].reverse().map(e => `
      <div class="history-card">
        <div class="history-card-header">
          <div class="history-card-title">${escHtml(e.name)}</div>
          <div class="history-card-date">${(e.merged_at || '').slice(0, 10)}</div>
        </div>
        <div class="history-card-desc">${escHtml(e.description || '')}</div>
        <div class="history-card-meta">
          <span>⬡ ${escHtml((e.repos || []).map(r => r.project).join(', '))}</span>
          <span class="mono">${escHtml(e.id)}</span>
        </div>
      </div>`).join('')
  } catch (e) {
    container.innerHTML = `<p class="empty">${escHtml(String(e))}</p>`
  }
}

// ── Logs ───────────────────────────────────────────────────
async function loadLogs() {
  const select = document.getElementById('log-job-select')

  try {
    const home = await homeDir()
    const stateDir = `${home}/.kit-workspace/state`
    const jobDirs = await listDir(stateDir)
    select.innerHTML = '<option value="">— select job —</option>' +
      [...jobDirs].reverse().map(j => `<option value="${j}">${j}</option>`).join('')
  } catch {}
}

async function showLog(jobId) {
  const output = document.getElementById('log-output')
  if (!jobId) { output.textContent = 'Select a job to view logs.'; return }

  try {
    const home = await homeDir()
    const logPath = `${home}/.kit-workspace/state/${jobId}/${jobId}.log`
    const content = await readFile(logPath)
    // Strip ANSI escape codes for clean display
    output.textContent = content.replace(/\x1b\[[0-9;]*m/g, '')
    output.scrollTop = output.scrollHeight
  } catch (e) {
    output.textContent = `Could not read log: ${e}`
  }
}

function viewLogs(jobId) {
  switchTab('logs')
  setTimeout(() => {
    const select = document.getElementById('log-job-select')
    select.value = jobId
    showLog(jobId)
  }, 100)
}

// ── Settings form ──────────────────────────────────────────
function loadSettingsForm() {
  document.getElementById('kws-path').value = settings.kwsPath
  document.getElementById('kws-dir').value  = settings.kwsDir
}

// ── Actions ────────────────────────────────────────────────
window.mergeJob = async (jobId) => {
  if (!confirm(`Merge job ${jobId} into main?`)) return

  // Show a temporary status in the table row
  const btn = document.querySelector(`button[onclick="mergeJob('${jobId}')"]`)
  if (btn) { btn.textContent = 'Merging…'; btn.disabled = true }

  const result = await kit('merge', jobId)
  const text = (result.stdout + result.stderr).replace(/\x1b\[[0-9;]*m/g, '').trim()

  if (result.success) {
    loadDashboard()
  } else {
    // Re-enable button and show error in a modal-style overlay
    if (btn) { btn.textContent = 'Merge'; btn.disabled = false }
    const output = document.getElementById('run-output')
    const modal  = document.getElementById('run-modal')
    document.getElementById('job-path-input').value = jobId
    output.textContent = text || 'Merge failed — no output captured.'
    output.classList.remove('hidden')
    modal.classList.remove('hidden')
  }
}

window.stopJob = async (jobId) => {
  if (!confirm(`Stop job ${jobId}?`)) return
  await kit('stop', jobId)
  loadDashboard()
}

// ── Session modal ───────────────────────────────────────────
let _sessionTarget   = ''
let _sessionProjects = []

window.openSessionModal = (target, projects) => {
  _sessionTarget   = target
  _sessionProjects = projects

  document.getElementById('session-target-display').textContent = target
  document.getElementById('session-name').value  = ''
  document.getElementById('session-desc').value  = ''
  document.getElementById('session-refine').checked = false
  document.getElementById('session-output').classList.add('hidden')
  document.getElementById('session-output').textContent = ''

  document.getElementById('session-modal').classList.remove('hidden')
  setTimeout(() => document.getElementById('session-name').focus(), 50)
}

function closeSessionModal() {
  document.getElementById('session-modal').classList.add('hidden')
}

async function startSession() {
  const name   = document.getElementById('session-name').value.trim().replace(/\s+/g, '-').toLowerCase()
  const desc   = document.getElementById('session-desc').value.trim()
  const mode   = document.getElementById('session-mode').value
  const refine = document.getElementById('session-refine').checked

  if (!name)  { document.getElementById('session-name').focus(); return }
  if (!desc)  { document.getElementById('session-desc').focus(); return }

  const output = document.getElementById('session-output')
  output.classList.remove('hidden')
  output.textContent = 'Starting session…'

  const args = ['session', 'start', _sessionTarget, name, desc, '--mode', mode]
  if (refine) args.push('--refine')

  try {
    const result = await kit(...args)
    const text = (result.stdout + result.stderr).replace(/\x1b\[[0-9;]*m/g, '')
    output.textContent = text || (result.success ? 'Session started.' : 'Failed — no output captured.')

    if (result.success) {
      setTimeout(() => {
        closeSessionModal()
        switchTab('dashboard')
      }, 1500)
    }
  } catch (e) {
    output.textContent = `Error: ${e}`
  }
}

// ── Run Job modal ──────────────────────────────────────────
function openRunModal() {
  document.getElementById('run-modal').classList.remove('hidden')
  document.getElementById('run-output').classList.add('hidden')
  document.getElementById('run-output').textContent = ''
}
function closeRunModal() {
  document.getElementById('run-modal').classList.add('hidden')
}

async function runJob() {
  const jobPath = document.getElementById('job-path-input').value.trim()
  const mode    = document.getElementById('job-mode-select').value
  if (!jobPath) return

  const output = document.getElementById('run-output')
  output.classList.remove('hidden')
  output.textContent = 'Starting…'

  const result = await kit('run', jobPath, '--mode', mode)
  output.textContent = (result.stdout + result.stderr).replace(/\x1b\[[0-9;]*m/g, '')
  if (result.success) setTimeout(() => { closeRunModal(); loadDashboard() }, 1500)
}

// ── Helpers ────────────────────────────────────────────────
function escHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
}

function statusBadge(status) {
  const map = { running:'running', completed:'completed', failed:'failed', stopped:'stopped' }
  const cls = map[status] || 'unknown'
  return `<span class="badge badge-${cls}">${status}</span>`
}

function typeBadge(type) {
  const map = { feature:'feature', fix:'fix', refactor:'refactor', chore:'chore', research:'research' }
  const cls = map[type] || 'unknown'
  return `<span class="badge badge-type-${cls}">${type}</span>`
}

// ── Boot ───────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  // Tab navigation
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => switchTab(btn.dataset.tab))
  })

  // Refresh button
  document.getElementById('refresh-btn').addEventListener('click', () => loadTab(activeTab))

  // Session modal
  document.getElementById('session-modal-cancel').addEventListener('click', closeSessionModal)
  document.getElementById('session-modal-confirm').addEventListener('click', startSession)
  document.getElementById('session-modal').addEventListener('click', e => {
    if (e.target === e.currentTarget) closeSessionModal()
  })

  // Run job modal
  document.getElementById('run-job-btn').addEventListener('click', openRunModal)
  document.getElementById('run-modal-cancel').addEventListener('click', closeRunModal)
  document.getElementById('run-modal-confirm').addEventListener('click', runJob)

  // Log auto-refresh
  document.getElementById('log-job-select').addEventListener('change', e => showLog(e.target.value))
  document.getElementById('log-follow').addEventListener('change', e => {
    clearInterval(logRefreshTimer)
    if (e.target.checked) {
      logRefreshTimer = setInterval(() => showLog(document.getElementById('log-job-select').value), 3000)
    }
  })

  // Settings
  document.getElementById('save-settings-btn').addEventListener('click', saveSettings)

  // Initial load
  if (!settings.kwsPath) {
    switchTab('settings')
  } else {
    loadDashboard()
  }

  // Auto-refresh dashboard every 10s when on dashboard tab
  setInterval(() => { if (activeTab === 'dashboard') loadDashboard() }, 10000)
})
