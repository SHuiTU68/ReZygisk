import { exec } from '../../kernelsu.js'

const MA_CFG_PATH = '/data/adb/rezygisk/.rz_meta_cfg'
const MA_MODULES_DIR = '/data/adb/modules'

// INFO: MetaMount state. `isMetamodule` is true only when Hrezygisk is the
// active metamodule (/data/adb/metamodule symlink resolves to rezygisk), i.e.
// only on KernelSU/APatch. The other fields mirror .rz_meta_cfg keys that
// metamount.sh sources on every boot.
const MetaMountState = {
  isMetamodule: false,
  metaEnabled: false,
  mountMode: 'auto',
  fakeName: 'rezygisk',
  allowedPartitions: [],
  skipModules: [],
  availableModules: [],
  discoveredPartitions: []
}

// INFO: Detect whether Hrezygisk is the active metamodule. KSU/APatch maintain
// /data/adb/metamodule as a symlink to the active metamodule's directory; on
// Magisk this path does not exist.
async function _loadMetamoduleStatus() {
  const r = await exec('readlink /data/adb/metamodule 2>/dev/null')
  MetaMountState.isMetamodule = (r.errno === 0 && /rezygisk$/.test(r.stdout.trim()))
}

// INFO: Read all metamodule config from .rz_meta_cfg. Format (sourced by
// metamount.sh):
//   enabled=true|false
//   mount_mode=auto|tmpfs|ext4|direct
//   fake_mount_name=rezygisk
//   allow_partitions="system vendor product"  (space or comma separated)
//   skip_modules="id1 id2 id3"
// Missing or malformed file => defaults (all disabled for safety).
// For backward compatibility, allow_system=true is parsed as allow_partitions+=system.
async function _loadMetaCfg() {
  MetaMountState.skipModules = []
  MetaMountState.metaEnabled = false
  MetaMountState.mountMode = 'auto'
  MetaMountState.fakeName = 'rezygisk'
  MetaMountState.allowedPartitions = []
  const r = await exec(`cat ${MA_CFG_PATH} 2>/dev/null`)
  if (r.errno !== 0) return
  r.stdout.split('\n').forEach((line) => {
    const sm = line.match(/^skip_modules="(.*)"$/)
    if (sm) {
      MetaMountState.skipModules = sm[1].split(/\s+/).filter(Boolean)
      return
    }
    const em = line.match(/^enabled=(.+)$/)
    if (em) {
      MetaMountState.metaEnabled = em[1].trim() === 'true'
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
      return
    }
    const ap = line.match(/^allow_partitions="(.*)"$/)
    if (ap) {
      MetaMountState.allowedPartitions = ap[1].split(/[\s,]+/).filter(Boolean)
      return
    }
    // Legacy: allow_system=true => allow system partition
    const as = line.match(/^allow_system=(.+)$/)
    if (as && as[1].trim() === 'true') {
      if (!MetaMountState.allowedPartitions.includes('system')) {
        MetaMountState.allowedPartitions.push('system')
      }
    }
  })
}

// INFO: Scan /data/adb/modules/* for installed modules (excluding rezygisk
// itself — it is the metamodule, mounting it via itself makes no sense) and
// read each module.prop for display. Also discover which partitions each
// module wants to overlay (top-level dirs under system/).
async function _loadAvailableModules() {
  MetaMountState.availableModules = []
  MetaMountState.discoveredPartitions = []
  const r = await exec(`ls -1 ${MA_MODULES_DIR} 2>/dev/null`)
  if (r.errno !== 0) return
  const ids = r.stdout.split('\n').filter(Boolean)
  for (const id of ids) {
    if (id === 'rezygisk') continue
    const propR = await exec(`cat ${MA_MODULES_DIR}/${id}/module.prop 2>/dev/null`)
    if (propR.errno !== 0) continue
    let name = id
    let version = ''
    propR.stdout.split('\n').forEach((line) => {
      if (line.startsWith('name=')) name = line.split('=').slice(1).join('=') || id
      if (line.startsWith('version=')) version = line.split('=').slice(1).join('=')
    })
    MetaMountState.availableModules.push({ id, name, version })
  }
  // Discover partitions from all modules' system/ directories
  const partR = await exec(
    `for m in ${MA_MODULES_DIR}/*/system; do [ -d "$m" ] || continue; ` +
    `ls -1 "$m" 2>/dev/null; done | sort -u`
  )
  if (partR.errno === 0) {
    MetaMountState.discoveredPartitions = partR.stdout.split('\n').filter(Boolean)
  }
}

// INFO: Persist all metamodule config to .rz_meta_cfg. The file is sourced by
// metamount.sh on every boot, so writes take effect on next reboot.
function _writeMetaCfg() {
  const skipList = MetaMountState.skipModules.filter(Boolean).join(' ')
  const allowList = MetaMountState.allowedPartitions.filter(Boolean).join(' ')
  const enabled = MetaMountState.metaEnabled ? 'true' : 'false'
  const mode = MetaMountState.mountMode
  const name = (MetaMountState.fakeName || 'rezygisk').replace(/[^A-Za-z0-9_]/g, '') || 'rezygisk'
  return exec(`mkdir -p /data/adb/rezygisk && cat > ${MA_CFG_PATH} <<'RZMETACFG'
enabled=${enabled}
mount_mode=${mode}
fake_mount_name=${name}
allow_partitions="${allowList}"
skip_modules="${skipList}"
RZMETACFG`)
}

// INFO: Sync all UI controls from MetaMountState.
function _syncUI() {
  const notActiveEl = document.getElementById('ma_not_active')
  const settingsEl = document.getElementById('ma_settings')
  const exclusionsEl = document.getElementById('ma_exclusions')
  const partitionsEl = document.getElementById('ma_partitions')
  const enabledSwitch = document.getElementById('ma_enabled_switch')
  const modeSelect = document.getElementById('ma_mode_select')
  const nameInput = document.getElementById('ma_fake_name_input')

  const active = MetaMountState.isMetamodule
  if (notActiveEl) notActiveEl.style.display = active ? 'none' : 'block'
  if (settingsEl) settingsEl.style.display = active ? 'block' : 'none'
  if (exclusionsEl) exclusionsEl.style.display = active ? 'block' : 'none'
  if (partitionsEl) partitionsEl.style.display = active ? 'block' : 'none'

  if (enabledSwitch) enabledSwitch.checked = MetaMountState.metaEnabled
  if (modeSelect) modeSelect.value = MetaMountState.mountMode
  if (nameInput) nameInput.value = MetaMountState.fakeName
}

// INFO: Build the exclusion list DOM. A checked checkbox means the module IS
// in skip_modules (i.e. NOT mounted by metamount.sh).
function _renderModuleList() {
  const listEl = document.getElementById('ma_module_list')
  const noModulesEl = document.getElementById('ma_no_modules')
  if (!listEl) return

  listEl.innerHTML = ''

  if (!MetaMountState.isMetamodule) {
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
        <input type="checkbox" data-ma-mod-id="${mod.id}">
        <span class="slider"></span>
      </label>
    `
    const cb = card.querySelector('input[type="checkbox"]')
    cb.checked = excluded
    cb.addEventListener('change', () => {
      const id = cb.getAttribute('data-ma-mod-id')
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

// INFO: Build the partition allow list DOM. Each discovered partition gets a
// toggle. A checked toggle means the partition IS in allow_partitions (i.e.
// explicitly allowed to be overlaid despite being dangerous).
function _renderPartitionList() {
  const listEl = document.getElementById('ma_partition_list')
  const noPartEl = document.getElementById('ma_no_partitions')
  if (!listEl) return

  listEl.innerHTML = ''

  if (!MetaMountState.isMetamodule) {
    if (noPartEl) noPartEl.style.display = 'none'
    return
  }

  if (MetaMountState.discoveredPartitions.length === 0) {
    if (noPartEl) noPartEl.style.display = 'block'
    return
  }
  if (noPartEl) noPartEl.style.display = 'none'

  for (const part of MetaMountState.discoveredPartitions) {
    const allowed = MetaMountState.allowedPartitions.includes(part)
    const card = document.createElement('div')
    card.className = 'small_card dimc'
    card.style.marginBottom = '0'
    card.innerHTML = `
      <div class="action_card">
        <div class="dimc content action_card_title">${part}</div>
        <div class="dimc desc action_card_description">/${part}</div>
      </div>
      <label class="switch dimc">
        <input type="checkbox" data-ma-part="${part}">
        <span class="slider"></span>
      </label>
    `
    const cb = card.querySelector('input[type="checkbox"]')
    cb.checked = allowed
    cb.addEventListener('change', () => {
      const p = cb.getAttribute('data-ma-part')
      if (cb.checked) {
        if (!MetaMountState.allowedPartitions.includes(p)) {
          MetaMountState.allowedPartitions.push(p)
        }
      } else {
        MetaMountState.allowedPartitions = MetaMountState.allowedPartitions.filter((x) => x !== p)
      }
      _writeMetaCfg()
    })
    listEl.appendChild(card)
  }
}

// INFO: Wire up change listeners for settings controls. Each change updates
// state and persists immediately.
function _setupListeners() {
  const enabledSwitch = document.getElementById('ma_enabled_switch')
  const modeSelect = document.getElementById('ma_mode_select')
  const nameInput = document.getElementById('ma_fake_name_input')

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

export async function loadOnce() {

}

export async function loadOnceView() {

}

export async function onceViewAfterUpdate() {

}

export async function load() {
  await _loadMetamoduleStatus()
  await _loadMetaCfg()
  await _loadAvailableModules()
  _syncUI()
  _renderPartitionList()
  _renderModuleList()
  _setupListeners()
}
