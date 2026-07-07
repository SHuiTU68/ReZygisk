import { exec } from '../../kernelsu.js'

const MA_CFG_PATH = '/data/adb/rezygisk/.rz_meta_cfg'
const MA_MODULES_DIR = '/data/adb/modules'

// INFO: MetaMount state. `isMetamodule` is true only when Hrezygisk is the
// active metamodule (/data/adb/metamodule symlink resolves to rezygisk), i.e.
// only on KernelSU/APatch. The other fields mirror .rz_meta_cfg keys that
// metamount.sh sources on every boot.
//
// WHITELIST MODEL: includeModules is a whitelist — a module is mounted ONLY
// if its id is in the list. Default empty = no modules mounted. This is the
// inverse of the old skip_modules blacklist: checking a box in the UI now
// means "mount this module" (intuitive), not "exclude this module".
const MetaMountState = {
  isMetamodule: false,
  metaEnabled: false,
  mountMode: 'auto',
  effectiveMode: '',
  fakeName: 'rezygisk',
  allowedPartitions: [],
  includeModules: [],
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

// INFO: Read runtime status file written by metamount.sh after probe. This
// contains the ACTUAL effective mount mode (e.g. "ext4" when "auto" was
// configured), so the UI can show "auto (ext4)". Also contains the list of
// mounted partitions.
async function _loadMetaStatus() {
  MetaMountState.effectiveMode = ''
  const r = await exec('cat /data/adb/rezygisk/.rz_meta_status 2>/dev/null')
  if (r.errno !== 0) return
  r.stdout.split('\n').forEach((line) => {
    const em = line.match(/^effective_mode=(.+)$/)
    if (em) {
      const v = em[1].trim()
      if (v === 'auto' || v === 'tmpfs' || v === 'ext4' || v === 'direct') {
        MetaMountState.effectiveMode = v
      }
    }
  })
}

// INFO: Read all metamodule config from .rz_meta_cfg. Format (sourced by
// metamount.sh):
//   enabled=true|false
//   mount_mode=auto|tmpfs|ext4|direct
//   fake_mount_name=rezygisk
//   allow_partitions="system vendor product"  (space or comma separated)
//   include_modules="id1 id2 id3"             (whitelist of modules to mount)
// Missing or malformed file => defaults (all disabled for safety).
// For backward compatibility, skip_modules (old blacklist) is parsed and
// inverted into includeModules (all modules EXCEPT those in skip_modules).
async function _loadMetaCfg() {
  MetaMountState.includeModules = []
  MetaMountState.metaEnabled = false
  MetaMountState.mountMode = 'auto'
  MetaMountState.fakeName = 'rezygisk'
  MetaMountState.allowedPartitions = []
  let legacySkipModules = null
  const r = await exec(`cat ${MA_CFG_PATH} 2>/dev/null`)
  if (r.errno !== 0) return
  r.stdout.split('\n').forEach((line) => {
    const im = line.match(/^include_modules="(.*)"$/)
    if (im) {
      MetaMountState.includeModules = im[1].split(/[\s,]+/).filter(Boolean)
      return
    }
    const ap = line.match(/^allow_partitions="(.*)"$/)
    if (ap) {
      MetaMountState.allowedPartitions = ap[1].split(/[\s,]+/).filter(Boolean)
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
    // Legacy: skip_modules blacklist. Collected and inverted into a whitelist
    // after module list is loaded (we need to know all module ids first).
    const sm = line.match(/^skip_modules="(.*)"$/)
    if (sm) {
      legacySkipModules = sm[1].split(/[\s,]+/).filter(Boolean)
    }
  })
  // Stash legacy skip list for inversion during _loadAvailableModules
  MetaMountState._legacySkipModules = legacySkipModules
}

// INFO: Scan /data/adb/modules/* for installed modules (excluding rezygisk
// itself — it is the metamodule, mounting it via itself makes no sense) and
// read each module.prop for display. Also discover which partitions each
// module wants to overlay (top-level dirs under system/).
//
// Legacy migration: if the config used the old skip_modules blacklist (and
// include_modules is empty/absent), invert it into a whitelist: every
// discovered module EXCEPT those in skip_modules becomes included.
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

  // Legacy migration: invert skip_modules blacklist into include_modules
  // whitelist (only if include_modules was empty and skip_modules existed).
  const legacy = MetaMountState._legacySkipModules
  if (legacy && Array.isArray(legacy) && MetaMountState.includeModules.length === 0) {
    MetaMountState.includeModules = MetaMountState.availableModules
      .map((m) => m.id)
      .filter((id) => !legacy.includes(id))
    delete MetaMountState._legacySkipModules
    // Persist the migrated whitelist immediately
    _writeMetaCfg()
  }
}

// INFO: Persist all metamodule config to .rz_meta_cfg. The file is sourced by
// metamount.sh on every boot, so writes take effect on next reboot.
//
// IMPORTANT: KernelSU/APatch exec bridge passes the command as a single string
// and may not handle multi-line here-docs reliably (the heredoc body can be
// truncated or interpreted as separate commands). We therefore build the
// entire file content as a single printf argument with literal \n sequences,
// which the shell expands into newlines. This is a single-line command — robust
// across exec bridges. Each value is sanitized to avoid shell-injection /
// quote-breaking: only safe characters are allowed.
function _writeMetaCfg() {
  const includeList = MetaMountState.includeModules.filter(Boolean).join(' ')
  const allowList = MetaMountState.allowedPartitions.filter(Boolean).join(' ')
  const enabled = MetaMountState.metaEnabled ? 'true' : 'false'
  const mode = MetaMountState.mountMode
  const name = (MetaMountState.fakeName || 'rezygisk').replace(/[^A-Za-z0-9_]/g, '') || 'rezygisk'
  // SAFETY: sanitize list values — only alphanumerics, underscore, hyphen,
  // dot, space (for the space-separated lists). This prevents shell metachar
  // injection and quote-breaking in the printf argument.
  const safeInclude = includeList.replace(/[^A-Za-z0-9_ .\-]/g, '')
  const safeAllow = allowList.replace(/[^A-Za-z0-9_ .\-]/g, '')
  // Build file content with \n that printf '%b' will expand.
  const content = `enabled=${enabled}\\nmount_mode=${mode}\\nfake_mount_name=${name}\\nallow_partitions="${safeAllow}"\\ninclude_modules="${safeInclude}"\\n`
  return exec(`mkdir -p /data/adb/rezygisk && printf '%b' '${content}' > ${MA_CFG_PATH}`)
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

  // INFO: Show the effective mode (actual mode after boot probe) when it
  // differs from the configured mode. E.g. configured "auto" → effective
  // "ext4" displays "auto → ext4".
  const effEl = document.getElementById('ma_effective_mode')
  if (effEl) {
    if (MetaMountState.effectiveMode &&
        MetaMountState.effectiveMode !== MetaMountState.mountMode &&
        MetaMountState.metaEnabled) {
      effEl.style.display = 'block'
      effEl.innerText = `${MetaMountState.mountMode} → ${MetaMountState.effectiveMode}`
    } else {
      effEl.style.display = 'none'
    }
  }
}

// INFO: Build the module list DOM. A checked checkbox means the module IS in
// include_modules (i.e. WILL be mounted by metamount.sh). This is the intuitive
// "select which modules to mount" UX — the inverse of the old exclusion list.
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
    const included = MetaMountState.includeModules.includes(mod.id)
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
    cb.checked = included
    cb.addEventListener('change', () => {
      const id = cb.getAttribute('data-ma-mod-id')
      if (cb.checked) {
        if (!MetaMountState.includeModules.includes(id)) {
          MetaMountState.includeModules.push(id)
        }
      } else {
        MetaMountState.includeModules = MetaMountState.includeModules.filter((x) => x !== id)
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
  await _loadMetaStatus()
  await _loadAvailableModules()
  _syncUI()
  _renderPartitionList()
  _renderModuleList()
  _setupListeners()
}
