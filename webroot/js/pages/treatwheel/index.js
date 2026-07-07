import { exec, toast } from '../../kernelsu.js'

const TW_STATE_PATH = '/data/adb/rezygisk/.rz_cfg'

const HidingState = {
  isIgnoring: false,
  isZygoteMountInfoLeakFixing: false,
  isMapsHiding: false,
  isDenylistLogicInversion: false,
  isModuleLoadingTracesHiding: false,
  isFridaTracesHiding: false,
  isEnvSanitization: false
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

  if (ignoreSwitch) ignoreSwitch.checked = HidingState.isIgnoring
  if (zygoteSwitch) zygoteSwitch.checked = HidingState.isZygoteMountInfoLeakFixing
  if (mapsSwitch) mapsSwitch.checked = HidingState.isMapsHiding
  if (denylistSwitch) denylistSwitch.checked = HidingState.isDenylistLogicInversion
  if (moduleSwitch) moduleSwitch.checked = HidingState.isModuleLoadingTracesHiding
  if (fridaSwitch) fridaSwitch.checked = HidingState.isFridaTracesHiding
  if (envSwitch) envSwitch.checked = HidingState.isEnvSanitization
}

function _setupSwitchListeners() {
  const ignoreSwitch = document.getElementById('tw_ignore_switch')
  const zygoteSwitch = document.getElementById('tw_disable_zygote_mountinfo_leak_fixing_switch')
  const mapsSwitch = document.getElementById('tw_disable_maps_hiding_switch')
  const denylistSwitch = document.getElementById('tw_disable_denylist_logic_inversion_switch')
  const moduleSwitch = document.getElementById('tw_disable_module_loading_traces_hiding_switch')
  const fridaSwitch = document.getElementById('tw_disable_frida_traces_hiding_switch')
  const envSwitch = document.getElementById('tw_disable_env_sanitization_switch')

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
}
