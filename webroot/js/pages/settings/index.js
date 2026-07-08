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

// INFO: Apply iOS Liquid Glass effect globally. When enabled, adds backdrop-filter
// blur + translucent overlay to cards, navbar, and headers. The blur intensity
// is controlled separately via applyBlurIntensity(). Called on settings load
// and on toggle change.
export function applyLiquidGlass(enabled) {
  let tag = document.getElementById('liquid-glass-tag')
  if (!enabled) {
    if (tag) tag.remove()
    document.body.classList.remove('rz-liquid-glass')
    return
  }
  if (!tag) {
    tag = document.createElement('style')
    tag.id = 'liquid-glass-tag'
    document.getElementsByTagName('head')[0].appendChild(tag)
  }
  // The actual blur value is set by applyBlurIntensity via CSS variable.
  tag.innerHTML = `
    body.rz-liquid-glass {
      --glass-blur: 12px;
    }
    body.rz-liquid-glass .card,
    body.rz-liquid-glass .small_card,
    body.rz-liquid-glass .miuix-group,
    body.rz-liquid-glass #navbar {
      background-color: color-mix(in srgb, var(--surface) 65%, transparent) !important;
      backdrop-filter: blur(var(--glass-blur, 12px)) saturate(1.5);
      -webkit-backdrop-filter: blur(var(--glass-blur, 12px)) saturate(1.5);
      border: 1px solid color-mix(in srgb, var(--on-surface) 8%, transparent);
      box-shadow: 0 2px 16px rgba(0, 0, 0, 0.08), inset 0 1px 0 color-mix(in srgb, var(--on-surface) 6%, transparent);
    }
    body.rz-liquid-glass .header {
      background-color: color-mix(in srgb, var(--background) 70%, transparent) !important;
      backdrop-filter: blur(var(--glass-blur, 12px)) saturate(1.3);
      -webkit-backdrop-filter: blur(var(--glass-blur, 12px)) saturate(1.3);
    }
    body.rz-liquid-glass .ma-item {
      background-color: color-mix(in srgb, var(--surface) 50%, transparent) !important;
    }
  `
  document.body.classList.add('rz-liquid-glass')
}

// INFO: Apply blur intensity. Updates the --glass-blur CSS variable that the
// liquid glass styles reference. Only has visible effect when liquid glass
// is enabled.
export function applyBlurIntensity(px) {
  document.body.style.setProperty('--glass-blur', `${px}px`)
}

// INFO: Restore all visual prefs at boot (font, liquid glass, blur).
export function restoreVisualPrefs() {
  let cfg = {}
  try {
    cfg = JSON.parse(localStorage.getItem('/Hrezygisk/webui_config') || '{}')
  } catch { cfg = {} }
  applyFontPrefs(cfg.fontSize || 16, cfg.fontWeight || 400)
  applyLiquidGlass(cfg.liquidGlass === true)
  applyBlurIntensity(cfg.blurIntensity || 12)
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
    fontWeight: 400,
    liquidGlass: false,
    blurIntensity: 12
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
          --font-family: system-ui, -apple-system, BlinkMacSystemFont, 'HarmonyOS Sans SC', 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif
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

  // INFO: iOS Liquid Glass toggle. When on, cards/navbar get translucent
  // backdrop-filter blur. The blur intensity is controlled separately.
  const rz_liquid_glass_switch = document.getElementById('rz_liquid_glass_switch')
  const rz_blur_card = document.getElementById('rz_blur_card')
  const rz_blur_intensity_range = document.getElementById('rz_blur_intensity_range')
  const rz_blur_intensity_value = document.getElementById('rz_blur_intensity_value')

  if (ConfigState.liquidGlass) rz_liquid_glass_switch.checked = true
  // Show/hide blur intensity card based on liquid glass state
  rz_blur_card.style.opacity = ConfigState.liquidGlass ? '1' : '0.4'
  rz_blur_card.style.pointerEvents = ConfigState.liquidGlass ? 'auto' : 'none'

  utils.addListener(rz_liquid_glass_switch, 'click', () => {
    ConfigState.liquidGlass = !ConfigState.liquidGlass
    applyLiquidGlass(ConfigState.liquidGlass)
    applyBlurIntensity(ConfigState.blurIntensity || 12)
    rz_blur_card.style.opacity = ConfigState.liquidGlass ? '1' : '0.4'
    rz_blur_card.style.pointerEvents = ConfigState.liquidGlass ? 'auto' : 'none'
    _writeState(ConfigState)
  })

  // INFO: Blur intensity slider. Live-updates the preview label and applies
  // immediately so the user sees the effect while dragging.
  if (ConfigState.blurIntensity) rz_blur_intensity_range.value = ConfigState.blurIntensity
  rz_blur_intensity_value.innerText = `${rz_blur_intensity_range.value}px`

  utils.addListener(rz_blur_intensity_range, 'input', () => {
    rz_blur_intensity_value.innerText = `${rz_blur_intensity_range.value}px`
    applyBlurIntensity(Number(rz_blur_intensity_range.value))
  })
  utils.addListener(rz_blur_intensity_range, 'change', () => {
    ConfigState.blurIntensity = Number(rz_blur_intensity_range.value)
    _writeState(ConfigState)
  })

  // INFO: Apply any saved font prefs now (in case settings is opened before
  // the boot-time restore, or prefs changed elsewhere).
  applyFontPrefs(ConfigState.fontSize || 16, ConfigState.fontWeight || 400)
  applyLiquidGlass(ConfigState.liquidGlass === true)
  applyBlurIntensity(ConfigState.blurIntensity || 12)
}
