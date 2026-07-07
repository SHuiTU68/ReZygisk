import { exec, toast } from '../../kernelsu.js'

const TW_STATE_PATH = '/data/adb/rezygisk/.rz_cfg'
const TW_META_CFG_PATH = '/data/adb/rezygisk/.rz_meta_cfg'
const TW_MODULES_DIR = '/data/adb/modules'

const HidingState = {
  isIgnoring: false,
  isZygoteMountInfoLeakFixing: false,
  isMapsHiding: false,
  isDenylistLogicInversion: false,
  isModuleLoadingTracesHiding: false,
  isFridaTracesHiding: false,
  isEnvSanitization: false,
  isMetaMountHiding: false
}

// INFO: MetaMount state. `isEnabled` is true only when Hrezygisk is the active
// metamodule (/data/adb/metamodule symlink resolves to rezygisk), i.e. only on
// KernelSU/APatch. `skipModules` mirrors the skip_modules= entry in .rz_meta_cfg
// that metamount.sh sources. `availableModules` is the live list scanned from
// /data/adb/modules/* (excluding rezygisk itself).
// `metaEnabled` / `mountMode` / `fakeName` mirror the other .rz_meta_cfg keys.
const MetaMountState = {
  isEnabled: false,
  metaEnabled: false,
  mountMode: 'auto',
  fakeName: 'rezygisk',
  skipModules: [],
  availableModules: []
}

function _writeState() {
  let state = ''
  if (HidingState.isIgnoring) state += 'ignoring=true\n'
  if (!HidingState.isZygoteMountInfoLeakFixing) state += 'disable_zygote_mountinfo_leak_fixing=true\n'
  if (!HidingState.isMapsHiding) state += 'disable_maps_hiding=true\n'
  if (!HidingState.isDenylistLogicInversion) state += 'disable_denylist_logic_inversion=true\n'
  if (!HidingState.isModuleLoadingTracesHiding) state += 'disable_module_loading_traces_hiding=true\n'
  if (!HidingState.isFridaTracesHiding) state += 'disable_frida_traces_hiding=true\n'
  if (!HidingState.isEnvSanitization) state += 'disable_env_sanitization=true\n'
  if (!HidingState.isMetaMountHiding) state += 'disable_meta_mount_hiding=true\n'
  return exec(`mkdir -p /data/adb/rezygisk && echo "${state}" > ${TW_STATE_PATH}`)
}

async function _loadState() {
  const state = await exec(`cat ${TW_STATE_PATH}`)
  if (state.errno !== 0) {
    HidingState.isIgnoring = false
    HidingState.isZygoteMountInfoLeakFixing = true
    HidingState.isMapsHiding = true
    HidingState.isDenylistLogicInversion = true
    HidingState.isModuleLoadingTracesHiding = true
    HidingState.isFridaTracesHiding = true
    HidingState.isEnvSanitization = true
    HidingState.isMetaMountHiding = true
    return
  }

  state.stdout.split('\n').forEach((line) => {
    if (line.startsWith('ignoring=')) HidingState.isIgnoring = line.split('=')[1] === 'true'
    if (line.startsWith('disable_zygote_mountinfo_leak_fixing=')) HidingState.isZygoteMountInfoLeakFixing = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_maps_hiding=')) HidingState.isMapsHiding = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_denylist_logic_inversion=')) HidingState.isDenylistLogicInversion = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_module_loading_traces_hiding=')) HidingState.isModuleLoadingTracesHiding = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_frida_traces_hiding=')) HidingState.isFridaTracesHiding = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_env_sanitization=')) HidingState.isEnvSanitization = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_meta_mount_hiding=')) HidingState.isMetaMountHiding = line.split('=')[1] !== 'true'
  })
}

function _syncSwitches() {
  const ignoreSwitch = document.getElementById('tw_ignore_switch')
  const zygoteSwitch = document.getElementById('tw_disable_zygote_mountinfo_leak_fixing_switch')
  const mapsSwitch = document.getElementById('tw_disable_maps_hiding_switch')
  const denylistSwitch = document.getElementById('tw_disable_denylist_logic_inversion_switch')
  const moduleSwitch = document.getElementById('tw_disable_module_loading_traces_hiding_switch')
  const fridaSwitch = document.getElementById('tw_disable_frida_traces_hiding_switch')
  const envSwitch = document.getElementById('tw_disable_env_sanitization_switch')
  const metaMountSwitch = document.getElementById('tw_disable_meta_mount_hiding_switch')

  if (ignoreSwitch) ignoreSwitch.checked = HidingState.isIgnoring
  if (zygoteSwitch) zygoteSwitch.checked = HidingState.isZygoteMountInfoLeakFixing
  if (mapsSwitch) mapsSwitch.checked = HidingState.isMapsHiding
  if (denylistSwitch) denylistSwitch.checked = HidingState.isDenylistLogicInversion
  if (moduleSwitch) moduleSwitch.checked = HidingState.isModuleLoadingTracesHiding
  if (fridaSwitch) fridaSwitch.checked = HidingState.isFridaTracesHiding
  if (envSwitch) envSwitch.checked = HidingState.isEnvSanitization
  if (metaMountSwitch) metaMountSwitch.checked = HidingState.isMetaMountHiding
}

function _setupSwitchListeners() {
  const ignoreSwitch = document.getElementById('tw_ignore_switch')
  const zygoteSwitch = document.getElementById('tw_disable_zygote_mountinfo_leak_fixing_switch')
  const mapsSwitch = document.getElementById('tw_disable_maps_hiding_switch')
  const denylistSwitch = document.getElementById('tw_disable_denylist_logic_inversion_switch')
  const moduleSwitch = document.getElementById('tw_disable_module_loading_traces_hiding_switch')
  const fridaSwitch = document.getElementById('tw_disable_frida_traces_hiding_switch')
  const envSwitch = document.getElementById('tw_disable_env_sanitization_switch')
  const metaMountSwitch = document.getElementById('tw_disable_meta_mount_hiding_switch')

  if (ignoreSwitch) {
    ignoreSwitch.addEventListener('change', () => {
      HidingState.isIgnoring = ignoreSwitch.checked
      _writeState()
    })
  }
  if (zygoteSwitch) {
    zygoteSwitch.addEventListener('change', () => {
      HidingState.isZygoteMountInfoLeakFixing = zygoteSwitch.checked
      _writeState()
    })
  }
  if (mapsSwitch) {
    mapsSwitch.addEventListener('change', () => {
      HidingState.isMapsHiding = mapsSwitch.checked
      _writeState()
    })
  }
  if (denylistSwitch) {
    denylistSwitch.addEventListener('change', () => {
      HidingState.isDenylistLogicInversion = denylistSwitch.checked
      _writeState()
    })
  }
  if (moduleSwitch) {
    moduleSwitch.addEventListener('change', () => {
      HidingState.isModuleLoadingTracesHiding = moduleSwitch.checked
      _writeState()
    })
  }
  if (fridaSwitch) {
    fridaSwitch.addEventListener('change', () => {
      HidingState.isFridaTracesHiding = fridaSwitch.checked
      _writeState()
    })
  }
  if (envSwitch) {
    envSwitch.addEventListener('change', () => {
      HidingState.isEnvSanitization = envSwitch.checked
      _writeState()
    })
  }
  if (metaMountSwitch) {
    metaMountSwitch.addEventListener('change', () => {
      HidingState.isMetaMountHiding = metaMountSwitch.checked
      _writeState()
    })
  }
}

// INFO: Detect whether Hrezygisk is the active metamodule. KSU/APatch maintain
// /data/adb/metamodule as a symlink to the active metamodule's directory; on
// Magisk this path does not exist, so isEnabled stays false and the UI shows
// the "not active" notice instead of the module list.
async function _loadMetaEnabled() {
  const r = await exec('readlink /data/adb/metamodule 2>/dev/null')
  MetaMountState.isEnabled = (r.errno === 0 && /rezygisk$/.test(r.stdout.trim()))
}

// INFO: Read all metamodule config from .rz_meta_cfg. Format (sourced by
// metamount.sh):
//   enabled=true|false
//   mount_mode=auto|tmpfs|ext4|direct
//   fake_mount_name=rezygisk
//   skip_modules="id1 id2 id3"
// Missing or malformed file => defaults.
async function _loadMetaCfg() {
  MetaMountState.skipModules = []
  MetaMountState.metaEnabled = false
  MetaMountState.mountMode = 'auto'
  MetaMountState.fakeName = 'rezygisk'
  const r = await exec(`cat ${TW_META_CFG_PATH} 2>/dev/null`)
  if (r.errno !== 0) return
  r.stdout.split('\n').forEach((line) => {
    const sm = line.match(/^skip_modules="(.*)"$/)
    if (sm) {
      MetaMountState.skipModules = sm[1].split(/\s+/).filter(Boolean)
      return
    }
    const em = line.match(/^enabled=(.+)$/)
    if (em) {
      MetaMountState.metaEnabled = em[1].trim() !== 'false'
      return
    }
    const mm = line.match(/^mount_mode=(.+)$/)
    if (mm) {
      const v = mm[1].trim()
      if (v === 'auto' || v === 'tmpfs' || v === 'ext4' || v === 'direct') {
        MetaMountState.mountMode = v
      }
      return
    }
    const fm = line.match(/^fake_mount_name=(.+)$/)
    if (fm) {
      MetaMountState.fakeName = fm[1].trim() || 'rezygisk'
    }
  })
}

// INFO: Scan installed modules for the exclusion list. We exclude rezygisk
// itself (it is the metamodule, mounting it via itself makes no sense) and read
// each module.prop for a friendly name + version to display.
async function _loadAvailableModules() {
  MetaMountState.availableModules = []
  const r = await exec(`ls -1 ${TW_MODULES_DIR} 2>/dev/null`)
  if (r.errno !== 0) return
  const ids = r.stdout.split('\n').filter(Boolean).filter((id) => id !== 'rezygisk')
  for (const id of ids) {
    let name = id
    let version = ''
    const pr = await exec(`cat ${TW_MODULES_DIR}/${id}/module.prop 2>/dev/null`)
    if (pr.errno === 0) {
      pr.stdout.split('\n').forEach((line) => {
        if (line.startsWith('name=')) name = line.slice(5)
        if (line.startsWith('version=')) version = line.slice(8)
      })
    }
    MetaMountState.availableModules.push({ id, name, version })
  }
}

// INFO: Persist all metamodule config to .rz_meta_cfg. The file is sourced by
// metamount.sh on every boot, so writes take effect on next reboot. We use a
// quoted heredoc delimiter so shell doesn't expand $ in the content — the JS
// template literal already substituted the values before the command runs.
function _writeMetaCfg() {
  const skipList = MetaMountState.skipModules.filter(Boolean).join(' ')
  const enabled = MetaMountState.metaEnabled ? 'true' : 'false'
  const mode = MetaMountState.mountMode
  const name = (MetaMountState.fakeName || 'rezygisk').replace(/[^A-Za-z0-9_]/g, '') || 'rezygisk'
  return exec(`mkdir -p /data/adb/rezygisk && cat > ${TW_META_CFG_PATH} <<'RZMETACFG'
enabled=${enabled}
mount_mode=${mode}
fake_mount_name=${name}
skip_modules="${skipList}"
RZMETACFG`)
}

// INFO: Sync the meta settings controls (enable switch, mode select, name
// input) from MetaMountState. Called after loading config and after rendering.
function _syncMetaSettings() {
  const settingsEl = document.getElementById('tw_meta_settings')
  const enabledSwitch = document.getElementById('tw_meta_enabled_switch')
  const modeSelect = document.getElementById('tw_meta_mode_select')
  const nameInput = document.getElementById('tw_meta_fake_name_input')

  if (settingsEl) settingsEl.style.display = MetaMountState.isEnabled ? 'block' : 'none'
  if (enabledSwitch) enabledSwitch.checked = MetaMountState.metaEnabled
  if (modeSelect) modeSelect.value = MetaMountState.mountMode
  if (nameInput) nameInput.value = MetaMountState.fakeName
}

// INFO: Wire up change listeners for the settings controls. Called once during
// load(). Each change updates MetaMountState and persists immediately.
function _setupMetaSettingsListeners() {
  const enabledSwitch = document.getElementById('tw_meta_enabled_switch')
  const modeSelect = document.getElementById('tw_meta_mode_select')
  const nameInput = document.getElementById('tw_meta_fake_name_input')

  if (enabledSwitch) {
    enabledSwitch.addEventListener('change', () => {
      MetaMountState.metaEnabled = enabledSwitch.checked
      _writeMetaCfg()
    })
  }
  if (modeSelect) {
    modeSelect.addEventListener('change', () => {
      MetaMountState.mountMode = modeSelect.value
      _writeMetaCfg()
    })
  }
  if (nameInput) {
    // INFO: Debounce text input — only persist on blur or Enter to avoid
    // writing the config file on every keystroke.
    nameInput.addEventListener('change', () => {
      MetaMountState.fakeName = nameInput.value.trim() || 'rezygisk'
      nameInput.value = MetaMountState.fakeName
      _writeMetaCfg()
    })
    nameInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        nameInput.blur()
      }
    })
  }
}

// INFO: Build the exclusion list DOM. A checked checkbox means the module IS
// in skip_modules (i.e. NOT mounted by metamount.sh). Toggling updates state
// and persists immediately — no separate save button needed.
function _renderModuleList() {
  const listEl = document.getElementById('tw_meta_module_list')
  const noModulesEl = document.getElementById('tw_meta_no_modules')
  const notActiveEl = document.getElementById('tw_meta_not_active')
  if (!listEl) return

  if (notActiveEl) notActiveEl.style.display = MetaMountState.isEnabled ? 'none' : 'block'

  // INFO: Show/hide the settings panel (switch, mode, name) based on whether
  // Hrezygisk is the active metamodule.
  _syncMetaSettings()

  listEl.innerHTML = ''

  if (!MetaMountState.isEnabled) {
    if (noModulesEl) noModulesEl.style.display = 'none'
    return
  }

  if (MetaMountState.availableModules.length === 0) {
    if (noModulesEl) noModulesEl.style.display = 'block'
    return
  }
  if (noModulesEl) noModulesEl.style.display = 'none'

  for (const mod of MetaMountState.availableModules) {
    const excluded = MetaMountState.skipModules.includes(mod.id)
    const card = document.createElement('div')
    card.className = 'small_card dimc'
    card.style.marginBottom = '0'
    const subtitle = mod.version ? `${mod.id} · ${mod.version}` : mod.id
    card.innerHTML = `
      <div class="action_card">
        <div class="dimc content action_card_title">${mod.name}</div>
        <div class="dimc desc action_card_description">${subtitle}</div>
      </div>
      <label class="switch dimc">
        <input type="checkbox" data-meta-mod-id="${mod.id}">
        <span class="slider"></span>
      </label>
    `
    const cb = card.querySelector('input[type="checkbox"]')
    cb.checked = excluded
    cb.addEventListener('change', () => {
      const id = cb.getAttribute('data-meta-mod-id')
      if (cb.checked) {
        if (!MetaMountState.skipModules.includes(id)) MetaMountState.skipModules.push(id)
      } else {
        MetaMountState.skipModules = MetaMountState.skipModules.filter((x) => x !== id)
      }
      _writeMetaCfg()
    })
    listEl.appendChild(card)
  }
}

export async function loadOnce() {

}

export async function loadOnceView() {

}

export async function onceViewAfterUpdate() {

}

export async function load() {
  await _loadState()
  _syncSwitches()
  _setupSwitchListeners()
  await _loadMetaEnabled()
  await _loadMetaCfg()
  await _loadAvailableModules()
  _renderModuleList()
  _setupMetaSettingsListeners()
}
