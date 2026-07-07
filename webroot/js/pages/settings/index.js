import { loadPage } from '../pageLoader.js'
import utils from '../utils.js'
import { fullScreen } from '../../kernelsu.js'

function _writeState(ConfigState) {
  return localStorage.setItem('/Hrezygisk/webui_config', JSON.stringify(ConfigState))
}

// INFO: Apply font size + weight globally via a single style tag. Called on
// settings load (to restore saved prefs) and on every change. Sets the root
// font-size (scales all em/rem units) and a body font-weight (inherited).
export function applyFontPrefs(fontSize, fontWeight) {
  let tag = document.getElementById('font-prefs-tag')
  if (!tag) {
    tag = document.createElement('style')
    tag.id = 'font-prefs-tag'
    document.getElementsByTagName('head')[0].appendChild(tag)
  }
  tag.innerHTML = `
    html { font-size: ${fontSize}px; }
    body { font-weight: ${fontWeight}; }
  `
}

// INFO: Read saved font prefs (or defaults) and apply them. Called once during
// WebUI boot so the user's font preference is visible immediately, before the
// settings page is opened.
export function restoreFontPrefs() {
  let cfg = {}
  try {
    cfg = JSON.parse(localStorage.getItem('/Hrezygisk/webui_config') || '{}')
  } catch { cfg = {} }
  const fontSize = cfg.fontSize || 16
  const fontWeight = cfg.fontWeight || 400
  applyFontPrefs(fontSize, fontWeight)
}

export async function loadOnce() {

}

export async function loadOnceView() {

}

export async function onceViewAfterUpdate() {

}

export async function load() {
  let ConfigState = {
    disableFullscreen: false,
    enableSystemFont: false,
    fontSize: 16,
    fontWeight: 400
  }

  let webui_config = localStorage.getItem('/Hrezygisk/webui_config')

  if (!webui_config) {
    localStorage.setItem('/Hrezygisk/webui_config', JSON.stringify(ConfigState))
  } else {
    ConfigState = JSON.parse(webui_config)
  }

  utils.addListener(document.getElementById('lang_page_toggle'), 'click', () => {
    loadPage('mini_settings_language')
  })

  utils.addListener(document.getElementById('theme_page_toggle'), 'click', () => {
    loadPage('mini_settings_theme')
  })

  const rz_webui_fullscreen_switch = document.getElementById('rz_webui_fullscreen_switch')
  if (ConfigState.disableFullscreen) rz_webui_fullscreen_switch.checked = true

  utils.addListener(rz_webui_fullscreen_switch, 'click', () => {
    /* INFO: This is swapped, as it meant to disable the fullscreen */
    ConfigState.disableFullscreen = !ConfigState.disableFullscreen
    _writeState(ConfigState)

    fullScreen(!ConfigState.disableFullscreen)
  })

  const rz_webui_font_switch = document.getElementById('rz_webui_font_switch')
  if (ConfigState.enableSystemFont) rz_webui_font_switch.checked = true

  utils.addListener(rz_webui_font_switch, 'click', () => {
    /* INFO: This is swapped, as it meant to enable the system font */
    ConfigState.enableSystemFont = !ConfigState.enableSystemFont

    if (ConfigState.enableSystemFont) {
      const headTag = document.getElementsByTagName('head')[0]
      const styleTag = document.createElement('style')

      styleTag.id = 'font-tag'
      headTag.appendChild(styleTag)
      styleTag.innerHTML = `
        :root {
          --font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif
        }`
    } else {
      const fontTag = document.getElementById('font-tag')
      if (fontTag) fontTag.remove()
    }

    _writeState(ConfigState)
  })

  // INFO: Font size slider. Live-updates the preview label and applies
  // immediately so the user sees the effect while dragging.
  const rz_font_size_range = document.getElementById('rz_font_size_range')
  const rz_font_size_value = document.getElementById('rz_font_size_value')
  if (ConfigState.fontSize) rz_font_size_range.value = ConfigState.fontSize
  rz_font_size_value.innerText = `${rz_font_size_range.value}px`

  utils.addListener(rz_font_size_range, 'input', () => {
    rz_font_size_value.innerText = `${rz_font_size_range.value}px`
    applyFontPrefs(rz_font_size_range.value, ConfigState.fontWeight || 400)
  })
  utils.addListener(rz_font_size_range, 'change', () => {
    ConfigState.fontSize = Number(rz_font_size_range.value)
    _writeState(ConfigState)
  })

  // INFO: Font weight select. Applies immediately.
  const rz_font_weight_select = document.getElementById('rz_font_weight_select')
  if (ConfigState.fontWeight) rz_font_weight_select.value = String(ConfigState.fontWeight)

  utils.addListener(rz_font_weight_select, 'change', () => {
    ConfigState.fontWeight = Number(rz_font_weight_select.value)
    applyFontPrefs(ConfigState.fontSize || 16, ConfigState.fontWeight)
    _writeState(ConfigState)
  })

  // INFO: Apply any saved font prefs now (in case settings is opened before
  // the boot-time restore, or prefs changed elsewhere).
  applyFontPrefs(ConfigState.fontSize || 16, ConfigState.fontWeight || 400)
}
