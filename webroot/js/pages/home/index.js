import { exec, toast } from '../../kernelsu.js'

import { whichCurrentPage } from '../navbar.js'
import { getStrings } from '../pageLoader.js'

let rzState = {
  actuallyWorking: 0,
  expectedWorking: 0
}

/* PERF: Cache state.json result with a short TTL. The home page is re-rendered
 * on multiple occasions (loadOnceView + onceViewAfterUpdate), and each render
 * previously issued a separate cat of state.json. Reuse the result for 1.5s. */
let _stateCache = null
let _stateCacheTs = 0
const _STATE_TTL_MS = 1500

async function _getReZygiskState() {
  const now = Date.now()
  if (_stateCache && (now - _stateCacheTs) < _STATE_TTL_MS) return _stateCache

  let stateCmd = await exec('/system/bin/cat /data/adb/rezygisk/state.json')
  if (stateCmd.errno !== 0) {
    toast('Error getting state of ReZygisk!')

    return;
  }

  try {
    _stateCache = JSON.parse(stateCmd.stdout)
    _stateCacheTs = now
    return _stateCache
  } catch {
    return null;
  }
}

/* PERF: Static device info (kernel, android version, module version) rarely
 * changes during a WebUI session. Cache it for the lifetime of the page. */
let _staticInfoCache = null
async function _getStaticInfo() {
  if (_staticInfoCache) return _staticInfoCache
  const [moduleProp, unameCmd, androidVersionCmd] = await Promise.all([
    exec('cat /data/adb/modules/rezygisk/module.prop'),
    exec('/system/bin/uname -r'),
    exec('/system/bin/getprop ro.build.version.release')
  ])

  let version = '???'
  if (moduleProp.errno === 0) {
    moduleProp.stdout.split('\n').forEach((line) => {
      if (line.startsWith('version=')) version = line.split('=')[1]
    })
  } else {
    toast('Error getting state of ReZygisk!')
  }

  const kernelVersion = (unameCmd.errno === 0 && unameCmd.stdout && unameCmd.stdout.length !== 0)
    ? unameCmd.stdout.trim() : '???'

  const androidVersion = (androidVersionCmd.errno === 0 && androidVersionCmd.stdout && androidVersionCmd.stdout.length !== 0)
    ? androidVersionCmd.stdout : '???'

  _staticInfoCache = { version, kernelVersion, androidVersion }
  return _staticInfoCache
}

// INFO: Detect metamodule activation + read mountify config.sh (user intent)
// and .rz_meta_status (actual effective mode + staging method after probe) to
// show the current mount mode on the home page.
//
// We read from mountify's config.sh (the file metamount.sh actually sources)
// rather than the old .rz_meta_cfg, so the displayed mode matches what the
// boot script will actually use.
//
// Status file format (written by metamount.sh):
//   effective_mode=auto|manual|disabled
//   staging_mode=tmpfs|ext4
//   ko_loaded=0|1
let _metaMountCache = null
async function _getMetaMountInfo() {
  if (_metaMountCache) return _metaMountCache
  const [linkR, cfgR, statusR] = await Promise.all([
    exec('readlink /data/adb/metamodule 2>/dev/null'),
    exec('cat /data/adb/rezygisk_meta/config.sh 2>/dev/null'),
    exec('cat /data/adb/.rz_meta_status 2>/dev/null')
  ])
  const active = (linkR.errno === 0 && /rezygisk$/.test(linkR.stdout.trim()))
  let enabled = false
  let mode = 'auto'
  // Parse mountify config.sh: mountify_mounts (0=disabled, 2=auto),
  // use_ext4_sparse (0=tmpfs, 1=ext4)
  if (cfgR.errno === 0) {
    let mountifyMounts = 2
    let useExt4Sparse = 0
    cfgR.stdout.split('\n').forEach((line) => {
      const mm = line.match(/^mountify_mounts=(.+)$/)
      if (mm) mountifyMounts = parseInt(mm[1].trim()) || 0
      const ue = line.match(/^use_ext4_sparse=(.+)$/)
      if (ue) useExt4Sparse = parseInt(ue[1].trim()) || 0
    })
    enabled = mountifyMounts !== 0
    mode = useExt4Sparse === 1 ? 'ext4' : 'auto'
  }
  // Parse status file: effective_mode + staging_mode (separate fields)
  let effectiveMode = ''
  let stagingMode = ''
  if (statusR.errno === 0) {
    statusR.stdout.split('\n').forEach((line) => {
      const em = line.match(/^effective_mode=(.+)$/)
      if (em) {
        const v = em[1].trim()
        if (v === 'auto' || v === 'manual' || v === 'disabled') effectiveMode = v
      }
      const sm = line.match(/^staging_mode=(.+)$/)
      if (sm) {
        const v = sm[1].trim()
        if (v === 'tmpfs' || v === 'ext4') stagingMode = v
      }
    })
  }
  _metaMountCache = { active, enabled, mode, effectiveMode, stagingMode }
  return _metaMountCache
}

async function _updateDynamicElement(firstRun, ReZygiskState, strings) {
  const rootCss = document.querySelector(':root')
  const rz_state = document.getElementById('rz_state')
  const rz_icon_state = document.getElementById('rz_icon_state')

  const zygote_divs = [
    document.getElementById('zygote64'),
    document.getElementById('zygote32')
  ]

  const zygote_status_divs = [
    document.getElementById('zygote64_status'),
    document.getElementById('zygote32_status')
  ]

  /* INFO: Just ensure that they won't appear unless there's info */
  zygote_divs.forEach((zygote_div) => {
    zygote_div.style.display = 'none'
  })

  if (ReZygiskState == null) {
    rz_state.innerHTML = strings.unknown
    rz_icon_state.innerHTML = '<img class="brightc" src="assets/mark.svg">'
    document.getElementById('zygote_class').style.display = 'none'
    /* INFO: This hides the throbber screen */
    loading_screen.style.display = 'none'
    return;
  }

  if (firstRun) {
    rzState.expectedWorking = ReZygiskState.zygote === undefined ? 0 : (ReZygiskState.zygote['64'] !== undefined ? 1 : 0) + (ReZygiskState.zygote['32'] !== undefined ? 1 : 0)
  }

  if (ReZygiskState.zygote['64'] && ReZygiskState.zygote !== undefined) {
    const zygote64 = ReZygiskState.zygote['64']

    zygote_divs[0].style.display = 'block'

    switch (zygote64) {
      case 1: {
        zygote_status_divs[0].innerHTML = strings.info.zygote.injected

        if (firstRun) rzState.actuallyWorking++

        break
      }
      case 0: zygote_status_divs[0].innerHTML = strings.info.zygote.notInjected; break
      default: zygote_status_divs[0].innerHTML = strings.info.zygote.unknown
    }
  }

  if (ReZygiskState.zygote && ReZygiskState.zygote['32'] !== undefined) {
    const zygote32 = ReZygiskState.zygote['32']

    zygote_divs[1].style.display = 'block'

    switch (zygote32) {
      case 1: {
        zygote_status_divs[1].innerHTML = strings.info.zygote.injected

        if (firstRun) rzState.actuallyWorking++

        break
      }
      case 0: zygote_status_divs[1].innerHTML = strings.info.zygote.notInjected; break
      default: zygote_status_divs[1].innerHTML = strings.info.zygote.unknown
    }
  }

  if (rzState.expectedWorking === 0 || rzState.actuallyWorking === 0) {
    rz_state.innerHTML = strings.status.notWorking
    document.getElementById('zygote_class').style.display = 'none'
  } else if (rzState.expectedWorking === rzState.actuallyWorking) {
    rz_state.innerHTML = strings.status.ok

    rootCss.style.setProperty('--bright', '#545454')
    rz_icon_state.innerHTML = '<img class="brightc" src="assets/tick.svg">'
  } else {
    rz_state.innerHTML = strings.status.partially

    rootCss.style.setProperty('--bright', '#766000')
    rz_icon_state.innerHTML = '<img class="brightc" src="assets/warn.svg">'
  }

  if (ReZygiskState.zygote === undefined) {
    document.getElementById('zygote_class').style.display = 'none'
  }
}

export async function loadOnce() {

}

export async function loadOnceView() {
  /* PERF: Parallelize static info fetch with state and strings fetch, instead
   * of awaiting three sequential exec() calls. */
  const [staticInfo, ReZygiskState, strings, metaMount] = await Promise.all([
    _getStaticInfo(),
    _getReZygiskState(),
    getStrings(whichCurrentPage()),
    _getMetaMountInfo()
  ])

  document.getElementById('version_code').innerHTML = staticInfo.version
  document.getElementById('kernel_version_div').innerHTML = staticInfo.kernelVersion
  document.getElementById('android_version_div').innerHTML = staticInfo.androidVersion

  let root_impl = ReZygiskState ? ReZygiskState.root : null
  if (!root_impl) root_impl = strings.unknown
  if (root_impl === 'Multiple') root_impl = strings.rootImpls.multiple

  document.getElementById('root_impl').innerHTML = root_impl

  // INFO: Show meta mount mode row only when metamodule is active.
  // Display format: "已启用 · auto · ext4" — showing both the effective mode
  // (auto/manual) and the actual staging method (tmpfs/ext4) from the last
  // boot. If no status file yet (first boot), show configured mode only.
  const metaClassEl = document.getElementById('meta_mount_class')
  const metaRowEl = document.getElementById('meta_mount_row')
  const metaStatusEl = document.getElementById('meta_mount_status')
  if (metaMount && metaMount.active && metaClassEl && metaRowEl) {
    metaClassEl.style.display = 'block'
    metaRowEl.style.display = 'block'
    if (metaStatusEl) {
      if (!metaMount.enabled) {
        metaStatusEl.innerHTML = strings.info.metaMount.disabled
      } else {
        // Build label: effective mode + staging method
        // e.g. "auto · ext4" or "auto · tmpfs"
        let modeLabel
        if (metaMount.effectiveMode && metaMount.stagingMode) {
          // Has runtime status — show actual values
          modeLabel = `${metaMount.effectiveMode} · ${metaMount.stagingMode}`
        } else {
          // No status yet (first boot or not run) — show configured mode
          const configuredLabel = strings.info.metaMount.modes[metaMount.mode] || metaMount.mode
          modeLabel = configuredLabel
        }
        metaStatusEl.innerHTML = `${strings.info.metaMount.enabled} · ${modeLabel}`
      }
    }
  }

  _updateDynamicElement(true, ReZygiskState, strings)

  /* INFO: This hides the throbber screen */
  loading_screen.style.display = 'none'
}

export async function onceViewAfterUpdate() {
  const ReZygiskState = await _getReZygiskState()
  const strings = await getStrings(whichCurrentPage())
  _updateDynamicElement(false, ReZygiskState, strings)
}

export async function load() {

}
