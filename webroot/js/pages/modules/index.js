import { exec, toast } from '../../kernelsu.js'

import { whichCurrentPage } from '../navbar.js'
import { getStrings } from '../pageLoader.js'

/* PERF: Share the state.json cache with home page via a module-level cache.
 * This avoids re-reading state.json when the user navigates between pages. */
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

async function _getModuleNames(modules) {
  /* PERF: Read all module.prop files with a single shell invocation using a
   * for-loop, instead of one grep+cut pipeline per module joined by ';'.
   * Each join in the old code spawned multiple subprocesses; this version
   * spawns one subshell that reads the name= line directly. */
  const idsArg = modules.map((m) => m.id).join(' ')
  const script = `for id in ${idsArg}; do
    f="/data/adb/modules/$id/module.prop"
    if [ -f "$f" ]; then
      while IFS= read -r line; do
        case "$line" in name=*) printf '%s\\n' "\${line#name=}"; break;; esac
      done < "$f"
    else
      printf '\\n'
    fi
  done`

  const result = await exec(script)
  if (result.errno !== 0) {
    setError('getModuleNames', 'Failed to execute command to retrieve module list names')

    return null
  }

  return result.stdout.split('\n')
}

async function _updateDynamicElement() {
  /* PERF: Fetch state and strings in parallel. */
  const [ReZygiskState, strings] = await Promise.all([
    _getReZygiskState(),
    getStrings(whichCurrentPage())
  ])
  const all_modules = []

  if (ReZygiskState.rezygiskd) Object.keys(ReZygiskState.rezygiskd).forEach((daemon_bit) => {
    const daemon = ReZygiskState.rezygiskd[daemon_bit]

    if (daemon.modules && daemon.modules.length > 0) {
      daemon.modules.forEach((module_id) => {
        const module = all_modules.find((mod) => mod.id === module_id)
        if (module) {
          module.bitsUsed.push(daemon_bit)
        } else {
          all_modules.push({
            id: module_id,
            name: null,
            bitsUsed: [ daemon_bit ]
          })
        }
      })
    }
  })

  if (all_modules.length !== 0) {
    const modules_list = document.getElementById('modules_list')
    modules_list.innerHTML = `
      <div id="modules_list_not_avaliable" class="not_avaliable">
        ${strings.notAvaliable}
      </div>
    `
    document.getElementById('modules_list_not_avaliable').style.display = 'none'

    const module_names = await _getModuleNames(all_modules)
    module_names.forEach((module_name, i) => all_modules[i].name = module_name)

    all_modules.forEach((module) => {
      modules_list.innerHTML +=
        `<div class="dim card" style="padding: 25px 15px; cursor: pointer;">
          <div class="dimc" style="font-size: 1.1em;">${module.name}</div>
          <div class="dimc desc" style="font-size: 0.9em; margin-top: 3px; white-space: nowrap; align-items: center; display: flex;">
            <div class="dimc arch_desc">${strings.arch}</div>
            <div class="dimc" style="margin-left: 5px;">${module.bitsUsed.join(' / ')}</div>
          </div>
        </div>`
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

}
