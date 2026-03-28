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
      const [status, startedAt, jobJsonRaw] = await Promise.all([
        readFile(`${base}/status`).catch(() => 'unknown'),
        readFile(`${base}/started_at`).catch(() => '—'),
        readFile(`${base}/job.json`).catch(() => null),
      ])
      let jobName = jobId
      let repoCount = '—'
      if (jobJsonRaw) {
        try {
          const j = JSON.parse(jobJsonRaw)
          jobName = j.name || jobId
          repoCount = (j.repos || []).length
        } catch {}
      }
      return { jobId, jobName, status: status.trim(), startedAt: startedAt.trim().slice(0, 16), repoCount }
    }))

    // Newest first
    rows.sort((a, b) => b.jobId.localeCompare(a.jobId))

    tbody.innerHTML = rows.map(r => `
      <tr>
        <td class="mono">${r.jobId}</td>
        <td>${escHtml(r.jobName)}</td>
        <td>${statusBadge(r.status)}</td>
        <td class="mono">${r.startedAt}</td>
        <td>${r.repoCount}</td>
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
async function loadProjects() {
  const tbody = document.getElementById('projects-body')
  tbody.innerHTML = '<tr><td colspan="4" class="empty">Loading…</td></tr>'

  try {
    const home = await homeDir()
    const raw = await readFile(`${home}/.kit-workspace/workspace.json`)
    const ws = JSON.parse(raw)
    const projects = Object.entries(ws.projects || {})
    const apps = ws.apps || {}

    // Render app groups
    const appsSection = document.getElementById('apps-section')
    const appsBody = document.getElementById('apps-body')
    const appEntries = Object.entries(apps)

    if (appEntries.length) {
      appsSection.classList.remove('hidden')
      appsBody.innerHTML = appEntries.map(([appName, projectList]) => `
        <tr>
          <td><strong>${escHtml(appName)}</strong></td>
          <td class="mono">${projectList.map(p => escHtml(p)).join(', ')}</td>
          <td>
            <button class="btn btn-sm btn-primary"
              onclick="openAppFeatureModal('${escHtml(appName)}', ${JSON.stringify(projectList)})">
              + App Feature
            </button>
          </td>
        </tr>`).join('')
    } else {
      appsSection.classList.add('hidden')
    }

    // Collect projects that belong to an app group (to mark them)
    const groupedProjects = new Set(Object.values(apps).flat())

    if (!projects.length) {
      tbody.innerHTML = '<tr><td colspan="4" class="empty">No projects registered yet.</td></tr>'
      return
    }
    tbody.innerHTML = projects.map(([name, p]) => `
      <tr${groupedProjects.has(name) ? ' class="project-in-group"' : ''}>
        <td><strong>${escHtml(name)}</strong></td>
        <td><span class="badge ${p.driver === 'petfi-kit' ? 'badge-running' : 'badge-unknown'}">${p.driver}</span></td>
        <td class="mono">${escHtml(p.path)}</td>
        <td>
          <button class="btn btn-sm btn-primary"
            onclick="openFeatureModal('${escHtml(name)}', '${p.driver}')">
            + New Feature
          </button>
        </td>
      </tr>`).join('')
  } catch (e) {
    tbody.innerHTML = `<tr><td colspan="4" class="empty">${escHtml(String(e))}</td></tr>`
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

// ── New Feature modal ──────────────────────────────────────
let _featureProject = ''
let _featureDriver  = ''

window.openFeatureModal = (projectName, driver) => {
  _featureProject = projectName
  _featureDriver  = driver

  document.getElementById('feature-project-name').textContent = projectName
  document.getElementById('feature-name').value       = ''
  document.getElementById('feature-desc').value       = ''
  document.getElementById('feature-agent-desc').value = ''
  document.getElementById('feature-output').classList.add('hidden')
  document.getElementById('feature-output').textContent = ''

  // Pre-select role based on driver
  const roleSelect = document.getElementById('feature-role')
  roleSelect.value = driver === 'petfi-kit' ? 'frontend' : 'developer'

  document.getElementById('feature-modal').classList.remove('hidden')
  setTimeout(() => document.getElementById('feature-name').focus(), 50)
}

function closeFeatureModal() {
  document.getElementById('feature-modal').classList.add('hidden')
}

async function startFeature() {
  const name       = document.getElementById('feature-name').value.trim().replace(/\s+/g, '-').toLowerCase()
  const desc       = document.getElementById('feature-desc').value.trim()
  const agentDesc  = document.getElementById('feature-agent-desc').value.trim()
  const role       = document.getElementById('feature-role').value
  const mode       = document.getElementById('feature-mode').value
  const refine     = document.getElementById('feature-refine').checked

  if (!name) { document.getElementById('feature-name').focus(); return }

  const output = document.getElementById('feature-output')
  output.classList.remove('hidden')
  output.textContent = 'Creating job…'

  // Build job.json
  const jobId = `job-${new Date().toISOString().replace(/[-:T]/g,'').slice(0,15)}`
  const job = {
    id:          jobId,
    name,
    description: desc,
    repos: [{
      project: _featureProject,
      agents: [{
        role,
        branch:      `feature/${name}`,
        profile:     _featureDriver === 'petfi-kit' ? 'flutter' : 'generic',
        description: agentDesc || desc,
      }]
    }]
  }

  try {
    const home    = await homeDir()
    const jobPath = `${home}/.kit-workspace/jobs/${name}.json`
    await writeFile(jobPath, JSON.stringify(job, null, 2))
    output.textContent = `Job saved: ${jobPath}\nStarting…`

    const runArgs = ['run', jobPath, '--mode', mode]
    if (refine) runArgs.push('--refine')
    const result = await kit(...runArgs)
    const text = (result.stdout + result.stderr).replace(/\x1b\[[0-9;]*m/g, '')
    output.textContent = text

    if (result.success) {
      setTimeout(() => {
        closeFeatureModal()
        switchTab('dashboard')
      }, 1500)
    }
  } catch (e) {
    output.textContent = `Error: ${e}`
  }
}

// ── App Feature modal ───────────────────────────────────────
let _appFeatureName = ''
let _appFeatureProjects = []

window.openAppFeatureModal = (appName, projects) => {
  _appFeatureName = appName
  _appFeatureProjects = projects

  document.getElementById('app-feature-app-name').textContent = appName
  document.getElementById('app-feature-name').value       = ''
  document.getElementById('app-feature-desc').value       = ''
  document.getElementById('app-feature-agent-desc').value = ''
  document.getElementById('app-feature-refine').checked   = false
  document.getElementById('app-feature-output').classList.add('hidden')
  document.getElementById('app-feature-output').textContent = ''

  // Render project checkboxes (all pre-checked)
  const container = document.getElementById('app-feature-projects')
  container.innerHTML = projects.map(p => `
    <label class="checkbox-item">
      <input type="checkbox" name="app-project" value="${escHtml(p)}" checked />
      <span>${escHtml(p)}</span>
    </label>`).join('')

  document.getElementById('app-feature-modal').classList.remove('hidden')
  setTimeout(() => document.getElementById('app-feature-name').focus(), 50)
}

function closeAppFeatureModal() {
  document.getElementById('app-feature-modal').classList.add('hidden')
}

async function startAppFeature() {
  const name      = document.getElementById('app-feature-name').value.trim().replace(/\s+/g, '-').toLowerCase()
  const desc      = document.getElementById('app-feature-desc').value.trim()
  const agentDesc = document.getElementById('app-feature-agent-desc').value.trim()
  const mode      = document.getElementById('app-feature-mode').value
  const refine    = document.getElementById('app-feature-refine').checked

  if (!name) { document.getElementById('app-feature-name').focus(); return }

  // Collect checked projects
  const checked = [...document.querySelectorAll('input[name="app-project"]:checked')].map(el => el.value)
  if (!checked.length) { alert('Select at least one project.'); return }

  const output = document.getElementById('app-feature-output')
  output.classList.remove('hidden')
  output.textContent = 'Creating job…'

  const jobId = `job-${new Date().toISOString().replace(/[-:T]/g,'').slice(0,15)}`
  const job = {
    id:          jobId,
    name,
    description: desc,
    repos: checked.map(project => ({
      project,
      agents: [{
        role:        'developer',
        branch:      `feature/${name}`,
        profile:     'generic',
        description: agentDesc || desc,
      }]
    }))
  }

  try {
    const home    = await homeDir()
    const jobPath = `${home}/.kit-workspace/jobs/${name}.json`
    await writeFile(jobPath, JSON.stringify(job, null, 2))
    output.textContent = `Job saved: ${jobPath}\nStarting…`

    const runArgs = ['run', jobPath, '--mode', mode]
    if (refine) runArgs.push('--refine')
    const result = await kit(...runArgs)
    const text = (result.stdout + result.stderr).replace(/\x1b\[[0-9;]*m/g, '')
    output.textContent = text

    if (result.success) {
      setTimeout(() => {
        closeAppFeatureModal()
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

// ── Boot ───────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  // Tab navigation
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => switchTab(btn.dataset.tab))
  })

  // Refresh button
  document.getElementById('refresh-btn').addEventListener('click', () => loadTab(activeTab))

  // New Feature modal
  document.getElementById('feature-modal-cancel').addEventListener('click', closeFeatureModal)
  document.getElementById('feature-modal-confirm').addEventListener('click', startFeature)
  document.getElementById('feature-modal').addEventListener('click', e => {
    if (e.target === e.currentTarget) closeFeatureModal()
  })

  // App Feature modal
  document.getElementById('app-feature-modal-cancel').addEventListener('click', closeAppFeatureModal)
  document.getElementById('app-feature-modal-confirm').addEventListener('click', startAppFeature)
  document.getElementById('app-feature-modal').addEventListener('click', e => {
    if (e.target === e.currentTarget) closeAppFeatureModal()
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
