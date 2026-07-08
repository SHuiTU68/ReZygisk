import { exec } from '../../kernelsu.js'

const MA_CFG_PATH = '/data/adb/.rz_meta_cfg'
const MA_MODULES_DIR = '/data/adb/modules'
// INFO: mountify config.sh — the file metamount.sh actually sources on boot.
// The WebUI writes mountify_mounts, use_ext4_sparse, enable_lkm_nuke,
// FAKE_MOUNT_NAME, and nuke_mount_point here via sed (same approach as
// mountify's own WebUI).
const MA_MOUNTIFY_CFG = '/data/adb/rezygisk_meta/config.sh'
const MA_STATUS_PATH = '/data/adb/.rz_meta_status'

// INFO: MetaMount state. `isMetamodule` is true only when Hrezygisk is the
// active metamodule (/data/adb/metamodule symlink resolves to rezygisk), i.e.
// only on KernelSU/APatch.
//
// mountify settings (read from config.sh, written via sed):
//   mountifyMounts: 0=disabled, 2=auto (mountify_mounts in config.sh)
//   useExt4Sparse: 0=tmpfs, 1=ext4 (use_ext4_sparse in config.sh)
//   enableLkmNuke: 0=off, 1=on (enable_lkm_nuke in config.sh)
//   fakeName: staging folder name (FAKE_MOUNT_NAME in config.sh)
//   nukeMountPoint: custom ext4 mount to nuke (nuke_mount_point in config.sh)
//
// Runtime status (read from .rz_meta_status):
//   effectiveMode: "auto" or "manual" (what mountify_mounts resolved to)
//   stagingMode: "tmpfs" or "ext4" (actual staging method used)
//   koLoaded: 0 or 1 (whether ko was actually loaded last boot)
//   koMountPoint: the mount point that was nuked
const MetaMountState = {
  isMetamodule: false,
  metaEnabled: false,
  mountMode: 'auto',
  effectiveMode: '',
  stagingMode: '',
  fakeName: 'rezygisk',
  enableLkmNuke: false,
  nukeMountPoint: '',
  koLoaded: 0,
  koMountPoint: '',
  excludedPartitions: [],
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

// INFO: Read runtime status file written by metamount.sh after probe.
// New format (separate fields):
//   effective_mode=auto|manual|disabled
//   staging_mode=tmpfs|ext4
//   ko_enabled=0|1
//   ko_loaded=0|1
//   ko_mount_point=/mnt/...
async function _loadMetaStatus() {
  MetaMountState.effectiveMode = ''
  MetaMountState.stagingMode = ''
  MetaMountState.koLoaded = 0
  MetaMountState.koMountPoint = ''
  const r = await exec(`cat ${MA_STATUS_PATH} 2>/dev/null`)
  if (r.errno !== 0) return
  r.stdout.split('\n').forEach((line) => {
    const em = line.match(/^effective_mode=(.+)$/)
    if (em) {
      const v = em[1].trim()
      if (v === 'auto' || v === 'manual' || v === 'disabled') {
        MetaMountState.effectiveMode = v
      }
    }
    const sm = line.match(/^staging_mode=(.+)$/)
    if (sm) {
      const v = sm[1].trim()
      if (v === 'tmpfs' || v === 'ext4') MetaMountState.stagingMode = v
    }
    const kl = line.match(/^ko_loaded=(.+)$/)
    if (kl) MetaMountState.koLoaded = parseInt(kl[1].trim()) || 0
    const kmp = line.match(/^ko_mount_point=(.+)$/)
    if (kmp) MetaMountState.koMountPoint = kmp[1].trim()
  })
}

// INFO: Read mountify config.sh — the file metamount.sh sources on boot.
// This is the AUTHORITATIVE config for mountify_mounts, use_ext4_sparse,
// enable_lkm_nuke, FAKE_MOUNT_NAME, nuke_mount_point.
// We map these to the WebUI's higher-level concepts:
//   mountify_mounts 0 → disabled, non-0 → enabled
//   use_ext4_sparse 1 → ext4 mode, 0 → auto/tmpfs mode
//   enable_lkm_nuke 1 → ko on
async function _loadMountifyCfg() {
  MetaMountState.metaEnabled = false
  MetaMountState.mountMode = 'auto'
  MetaMountState.fakeName = 'rezygisk'
  MetaMountState.enableLkmNuke = false
  MetaMountState.nukeMountPoint = ''
  const r = await exec(`cat ${MA_MOUNTIFY_CFG} 2>/dev/null`)
  if (r.errno !== 0) return
  let mountifyMounts = 2
  let useExt4Sparse = 0
  r.stdout.split('\n').forEach((line) => {
    const mm = line.match(/^mountify_mounts=(.+)$/)
    if (mm) {
      mountifyMounts = parseInt(mm[1].trim()) || 0
      return
    }
    const ue = line.match(/^use_ext4_sparse=(.+)$/)
    if (ue) {
      useExt4Sparse = parseInt(ue[1].trim()) || 0
      return
    }
    const el = line.match(/^enable_lkm_nuke=(.+)$/)
    if (el) {
      MetaMountState.enableLkmNuke = (parseInt(el[1].trim()) || 0) === 1
      return
    }
    const fn = line.match(/^FAKE_MOUNT_NAME="?(.+?)"?$/)
    if (fn) {
      MetaMountState.fakeName = fn[1].trim() || 'rezygisk'
      return
    }
    const nmp = line.match(/^nuke_mount_point="?(.*?)"?$/)
    if (nmp) {
      MetaMountState.nukeMountPoint = nmp[1].trim()
    }
  })
  // Map mountify values to WebUI concepts
  MetaMountState.metaEnabled = mountifyMounts !== 0
  MetaMountState.mountMode = useExt4Sparse === 1 ? 'ext4' : 'auto'
}

// INFO: Write a single mountify config key to config.sh using sed.
// Uses the same sed approach as mountify's WebUI (file.js).
// Ensures the config dir exists first.
async function _writeMountifyKey(key, value, isString) {
  const safeValue = String(value).replace(/["\\]/g, '')
  if (isString) {
    return exec(`mkdir -p /data/adb/rezygisk_meta && sed -i 's|^${key}=.*|${key}="${safeValue}"|' ${MA_MOUNTIFY_CFG}`)
  }
  return exec(`mkdir -p /data/adb/rezygisk_meta && sed -i 's|^${key}=.*|${key}=${safeValue}|' ${MA_MOUNTIFY_CFG}`)
}

// INFO: Read all metamodule config from .rz_meta_cfg. Format (sourced by
// metamount.sh):
//   enabled=true|false
//   mount_mode=auto|tmpfs|ext4|direct
//   fake_mount_name=rezygisk
//   exclude_partitions="product"             (blacklist; empty = mount all)
//   include_modules="id1 id2 id3"            (whitelist of modules to mount)
// Missing or malformed file => defaults (all disabled for safety).
// For backward compatibility, skip_modules (old blacklist) is parsed and
// inverted into includeModules (all modules EXCEPT those in skip_modules).
// For backward compatibility, allow_partitions (old permit list) is ignored —
// under the new model all partitions mount by default.
async function _loadMetaCfg() {
  MetaMountState.includeModules = []
  MetaMountState.metaEnabled = false
  MetaMountState.mountMode = 'auto'
  MetaMountState.fakeName = 'rezygisk'
  MetaMountState.excludedPartitions = []
  let legacySkipModules = null
  const r = await exec(`cat ${MA_CFG_PATH} 2>/dev/null`)
  if (r.errno !== 0) return
  r.stdout.split('\n').forEach((line) => {
    const im = line.match(/^include_modules="(.*)"$/)
    if (im) {
      MetaMountState.includeModules = im[1].split(/[\s,]+/).filter(Boolean)
      return
    }
    const ep = line.match(/^exclude_partitions="(.*)"$/)
    if (ep) {
      MetaMountState.excludedPartitions = ep[1].split(/[\s,]+/).filter(Boolean)
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
    // NOTE: allow_partitions (old permit list) is intentionally NOT parsed —
    // it no longer has any effect under the auto-mount model.
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
  const excludeList = MetaMountState.excludedPartitions.filter(Boolean).join(' ')
  const enabled = MetaMountState.metaEnabled ? 'true' : 'false'
  const mode = MetaMountState.mountMode
  const name = (MetaMountState.fakeName || 'rezygisk').replace(/[^A-Za-z0-9_]/g, '') || 'rezygisk'
  // SAFETY: sanitize list values — only alphanumerics, underscore, hyphen,
  // dot, space (for the space-separated lists). This prevents shell metachar
  // injection and quote-breaking in the printf argument.
  const safeInclude = includeList.replace(/[^A-Za-z0-9_ .\-]/g, '')
  const safeExclude = excludeList.replace(/[^A-Za-z0-9_ .\-]/g, '')
  // Build file content with \n that printf '%b' will expand.
  const content = `enabled=${enabled}\\nmount_mode=${mode}\\nfake_mount_name=${name}\\nexclude_partitions="${safeExclude}"\\ninclude_modules="${safeInclude}"\\n`
  return exec(`mkdir -p /data/adb && printf '%b' '${content}' > ${MA_CFG_PATH}`)
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
  const lkmCard = document.getElementById('ma_lkm_card')
  const lkmSwitch = document.getElementById('ma_lkm_switch')
  const lkmStatusEl = document.getElementById('ma_lkm_status')
  const lkmMpCard = document.getElementById('ma_lkm_mountpoint_card')
  const lkmMpInput = document.getElementById('ma_lkm_mountpoint_input')

  const active = MetaMountState.isMetamodule
  if (notActiveEl) notActiveEl.style.display = active ? 'none' : 'block'
  if (settingsEl) settingsEl.style.display = active ? 'block' : 'none'
  if (exclusionsEl) exclusionsEl.style.display = active ? 'block' : 'none'
  if (partitionsEl) partitionsEl.style.display = active ? 'block' : 'none'

  if (enabledSwitch) enabledSwitch.checked = MetaMountState.metaEnabled
  if (modeSelect) modeSelect.value = MetaMountState.mountMode
  if (nameInput) nameInput.value = MetaMountState.fakeName

  // INFO: Show the effective mode + staging method after boot probe.
  // E.g. configured "auto" with staging "ext4" shows "auto · ext4".
  const effEl = document.getElementById('ma_effective_mode')
  if (effEl) {
    if (MetaMountState.metaEnabled && MetaMountState.effectiveMode) {
      effEl.style.display = 'block'
      let label = MetaMountState.effectiveMode
      if (MetaMountState.stagingMode) {
        label = `${label} · ${MetaMountState.stagingMode}`
      }
      effEl.innerText = label
    } else {
      effEl.style.display = 'none'
    }
  }

  // INFO: Show ko toggle only when ext4 mode is selected (ko only works
  // with ext4 staging). Also show mount_point input when ko is enabled.
  const isExt4 = MetaMountState.mountMode === 'ext4'
  if (lkmCard) lkmCard.style.display = (active && isExt4) ? 'block' : 'none'
  if (lkmSwitch) lkmSwitch.checked = MetaMountState.enableLkmNuke
  if (lkmMpCard) lkmMpCard.style.display = (active && isExt4 && MetaMountState.enableLkmNuke) ? 'block' : 'none'
  if (lkmMpInput) lkmMpInput.value = MetaMountState.nukeMountPoint

  // INFO: Show ko load status from last boot
  if (lkmStatusEl) {
    if (MetaMountState.enableLkmNuke && MetaMountState.effectiveMode) {
      lkmStatusEl.style.display = 'block'
      let statusText
      if (MetaMountState.koLoaded === 1) {
        statusText = `${strings_cache?.settings?.lkmNuke?.loaded || 'loaded'}`
        if (MetaMountState.koMountPoint) {
          statusText += `: ${MetaMountState.koMountPoint}`
        }
      } else {
        statusText = `${strings_cache?.settings?.lkmNuke?.loadFailed || 'load failed'}`
      }
      lkmStatusEl.innerText = statusText
    } else {
      lkmStatusEl.style.display = 'none'
    }
  }
}

// INFO: Cache strings for use in _syncUI (which is called before strings are
// available in some cases).
let strings_cache = null

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

// INFO: Build the partition list DOM. Each discovered partition gets a toggle.
// CHECKED = will be mounted (default). UNCHECKED = added to exclude_partitions
// blacklist and NOT mounted. This is the inverse of the old allow model: every
// partition a selected module references is mounted by default, and the user
// unchecks only the ones they want to suppress.
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
    const mounted = !MetaMountState.excludedPartitions.includes(part)
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
    cb.checked = mounted
    cb.addEventListener('change', () => {
      const p = cb.getAttribute('data-ma-part')
      if (cb.checked) {
        // remove from exclude blacklist → will be mounted
        MetaMountState.excludedPartitions = MetaMountState.excludedPartitions.filter((x) => x !== p)
      } else {
        // add to exclude blacklist → will NOT be mounted
        if (!MetaMountState.excludedPartitions.includes(p)) {
          MetaMountState.excludedPartitions.push(p)
        }
      }
      _writeMetaCfg()
    })
    listEl.appendChild(card)
  }
}

// INFO: Wire up change listeners for settings controls. Each change updates
// state and persists immediately. Mountify settings (enabled, mode, ko, name,
// mount_point) are written to config.sh via sed. Module/partition lists are
// written to .rz_meta_cfg (legacy, used for display).
function _setupListeners() {
  const enabledSwitch = document.getElementById('ma_enabled_switch')
  const modeSelect = document.getElementById('ma_mode_select')
  const nameInput = document.getElementById('ma_fake_name_input')
  const lkmSwitch = document.getElementById('ma_lkm_switch')
  const lkmMpInput = document.getElementById('ma_lkm_mountpoint_input')

  if (enabledSwitch) {
    enabledSwitch.addEventListener('change', () => {
      MetaMountState.metaEnabled = enabledSwitch.checked
      // Map: enabled → mountify_mounts (0=disabled, 2=auto)
      _writeMountifyKey('mountify_mounts', enabledSwitch.checked ? 2 : 0, false)
      _writeMetaCfg()
      _syncUI()
    })
  }
  if (modeSelect) {
    modeSelect.addEventListener('change', () => {
      MetaMountState.mountMode = modeSelect.value
      // Map: ext4 → use_ext4_sparse=1, auto/tmpfs/direct → use_ext4_sparse=0
      const useExt4 = modeSelect.value === 'ext4' ? 1 : 0
      _writeMountifyKey('use_ext4_sparse', useExt4, false)
      _writeMetaCfg()
      _syncUI()
    })
  }
  if (nameInput) {
    nameInput.addEventListener('change', () => {
      MetaMountState.fakeName = nameInput.value.trim() || 'rezygisk'
      nameInput.value = MetaMountState.fakeName
      _writeMountifyKey('FAKE_MOUNT_NAME', MetaMountState.fakeName, true)
      _writeMetaCfg()
    })
    nameInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        nameInput.blur()
      }
    })
  }
  if (lkmSwitch) {
    lkmSwitch.addEventListener('change', () => {
      MetaMountState.enableLkmNuke = lkmSwitch.checked
      _writeMountifyKey('enable_lkm_nuke', lkmSwitch.checked ? 1 : 0, false)
      _syncUI()
    })
  }
  if (lkmMpInput) {
    lkmMpInput.addEventListener('change', () => {
      MetaMountState.nukeMountPoint = lkmMpInput.value.trim()
      _writeMountifyKey('nuke_mount_point', MetaMountState.nukeMountPoint, true)
    })
    lkmMpInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        lkmMpInput.blur()
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
  await _loadMountifyCfg()
  await _loadMetaCfg()
  await _loadMetaStatus()
  await _loadAvailableModules()
  // Cache strings for _syncUI (used in ko status display)
  try {
    const { getStrings } = await import('../pageLoader.js')
    const { whichCurrentPage } = await import('../navbar.js')
    strings_cache = (await getStrings(whichCurrentPage())) || null
  } catch { strings_cache = null }
  _syncUI()
  _renderPartitionList()
  _renderModuleList()
  _setupListeners()
}
