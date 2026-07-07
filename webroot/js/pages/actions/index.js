import { whichCurrentPage } from '../navbar.js'
import { getStrings } from '../pageLoader.js'
import { exec, toast } from '../../kernelsu.js'

const TW_STATE_PATH = '/data/adb/rezygisk/tw_state'

async function _getMonitorState() {
  const stateCmd = await exec('/system/bin/cat /data/adb/rezygisk/state.json')
  if (stateCmd.errno !== 0) {
    toast('Error getting state of ReZygisk!')

    return;
  }

  try {
    const ReZygiskState = JSON.parse(stateCmd.stdout)
    return ReZygiskState.monitor.state
  } catch {
    return null;
  }
}

async function _updateDynamicElement() {
  const monitor_status = document.getElementById('monitor_status')
  const strings = await getStrings(whichCurrentPage())
  const monitorState = await _getMonitorState()

  if (monitorState == null) return;

  switch (monitorState) {
    case '0': monitor_status.innerHTML = strings.monitor.status.tracing; break;
    case '1': monitor_status.innerHTML = strings.monitor.status.stopping; break;
    case '2': monitor_status.innerHTML = strings.monitor.status.stopped; break;
    case '3': monitor_status.innerHTML = strings.monitor.status.exiting; break;
    default: monitor_status.innerHTML = strings.monitor.status.unknown;
  }
}

/* INFO: Treat Wheel state helpers */

const HidingState = {
  isIgnoring: false,
  isZygoteMountInfoLeakFixing: false,
  isMapsHiding: false,
  isDenylistLogicInversion: false,
  isModuleLoadingTracesHiding: false,
  isFridaTracesHiding: false
}

function _writeState() {
  let state = ''
  if (HidingState.isIgnoring) state += 'ignoring=true\n'
  if (!HidingState.isZygoteMountInfoLeakFixing) state += 'disable_zygote_mountinfo_leak_fixing=true\n'
  if (!HidingState.isMapsHiding) state += 'disable_maps_hiding=true\n'
  if (!HidingState.isDenylistLogicInversion) state += 'disable_denylist_logic_inversion=true\n'
  if (!HidingState.isModuleLoadingTracesHiding) state += 'disable_module_loading_traces_hiding=true\n'
  if (!HidingState.isFridaTracesHiding) state += 'disable_frida_traces_hiding=true\n'
  return exec(`mkdir -p /data/adb/rezygisk && echo "${state}" > ${TW_STATE_PATH}`)
}

async function _loadState() {
  const state = await exec(`cat ${TW_STATE_PATH}`)
  if (state.errno !== 0) {
    /* INFO: State file may not exist yet, default to all enabled (safe defaults) */
    HidingState.isIgnoring = false
    HidingState.isZygoteMountInfoLeakFixing = true
    HidingState.isMapsHiding = true
    HidingState.isDenylistLogicInversion = true
    HidingState.isModuleLoadingTracesHiding = true
    HidingState.isFridaTracesHiding = true
    return
  }

  state.stdout.split('\n').forEach((line) => {
    if (line.startsWith('ignoring=')) HidingState.isIgnoring = line.split('=')[1] === 'true'
    if (line.startsWith('disable_zygote_mountinfo_leak_fixing=')) HidingState.isZygoteMountInfoLeakFixing = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_maps_hiding=')) HidingState.isMapsHiding = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_denylist_logic_inversion=')) HidingState.isDenylistLogicInversion = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_module_loading_traces_hiding=')) HidingState.isModuleLoadingTracesHiding = line.split('=')[1] !== 'true'
    if (line.startsWith('disable_frida_traces_hiding=')) HidingState.isFridaTracesHiding = line.split('=')[1] !== 'true'
  })
}

function _syncSwitches() {
  const ignoreSwitch = document.getElementById('tw_ignore_switch')
  const zygoteSwitch = document.getElementById('tw_disable_zygote_mountinfo_leak_fixing_switch')
  const mapsSwitch = document.getElementById('tw_disable_maps_hiding_switch')
  const denylistSwitch = document.getElementById('tw_disable_denylist_logic_inversion_switch')
  const moduleSwitch = document.getElementById('tw_disable_module_loading_traces_hiding_switch')
  const fridaSwitch = document.getElementById('tw_disable_frida_traces_hiding_switch')

  if (ignoreSwitch) ignoreSwitch.checked = HidingState.isIgnoring
  if (zygoteSwitch) zygoteSwitch.checked = HidingState.isZygoteMountInfoLeakFixing
  if (mapsSwitch) mapsSwitch.checked = HidingState.isMapsHiding
  if (denylistSwitch) denylistSwitch.checked = HidingState.isDenylistLogicInversion
  if (moduleSwitch) moduleSwitch.checked = HidingState.isModuleLoadingTracesHiding
  if (fridaSwitch) fridaSwitch.checked = HidingState.isFridaTracesHiding
}

function _setupSwitchListeners() {
  const ignoreSwitch = document.getElementById('tw_ignore_switch')
  const zygoteSwitch = document.getElementById('tw_disable_zygote_mountinfo_leak_fixing_switch')
  const mapsSwitch = document.getElementById('tw_disable_maps_hiding_switch')
  const denylistSwitch = document.getElementById('tw_disable_denylist_logic_inversion_switch')
  const moduleSwitch = document.getElementById('tw_disable_module_loading_traces_hiding_switch')
  const fridaSwitch = document.getElementById('tw_disable_frida_traces_hiding_switch')

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
}

export async function loadOnce() {

}

export async function loadOnceView() {
  _updateDynamicElement()
}

export async function onceViewAfterUpdate() {
  _updateDynamicElement()
}

export async function load() {
  const monitor_start = document.getElementById('monitor_start_button')
  const monitor_stop = document.getElementById('monitor_stop_button')
  const monitor_pause = document.getElementById('monitor_pause_button')
  const monitor_status = document.getElementById('monitor_status')
  const strings = await getStrings(whichCurrentPage())

  monitor_start.addEventListener('click', () => {
    if (![ strings.monitor.status.tracing, strings.monitor.status.stopping, strings.monitor.status.stopped ].includes(monitor_status.innerHTML)) return;
    monitor_status.innerHTML = strings.monitor.status.tracing
    exec('/data/adb/modules/rezygisk/bin/zygisk-ptrace64 ctl start')
  })

  monitor_stop.addEventListener('click', () => {
    monitor_status.innerHTML = strings.monitor.status.exiting
    exec('/data/adb/modules/rezygisk/bin/zygisk-ptrace64 ctl exit')
  })

  monitor_pause.addEventListener('click', () => {
    if (![ strings.monitor.status.tracing, strings.monitor.status.stopping, strings.monitor.status.stopped ].includes(monitor_status.innerHTML)) return;
    monitor_status.innerHTML = strings.monitor.status.stopped
    exec('/data/adb/modules/rezygisk/bin/zygisk-ptrace64 ctl stop')
  })

  /* INFO: Load and setup Treat Wheel switches */
  await _loadState()
  _syncSwitches()
  _setupSwitchListeners()

  return;
}
