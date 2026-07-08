import { exec, fullScreen } from './kernelsu.js'
import { setDark } from './themes/dark.js'
import { setThemeData, themeList } from './themes/main.js'
import { setLight } from './themes/light.js'
import { loadPage } from './pages/pageLoader.js'

/* INFO: Unified localStorage prefix to match pageLoader.js (Hrezygisk). The
 * previous '/ReZygisk/' prefix caused theme/config to be lost after the
 * module rename. Migrate old keys on first load. */
const LS_PREFIX = '/Hrezygisk/'
function _migrateLsKey(oldKey, newKey) {
  const v = localStorage.getItem(oldKey)
  if (v !== null && localStorage.getItem(newKey) === null) {
    localStorage.setItem(newKey, v)
    localStorage.removeItem(oldKey)
  }
}
_migrateLsKey('/ReZygisk/theme', `${LS_PREFIX}theme`)
_migrateLsKey('/ReZygisk/webui_config', `${LS_PREFIX}webui_config`)

/* INFO: This sets the default theme to system if not set */
let sys_theme = localStorage.getItem(`${LS_PREFIX}theme`)
if (!sys_theme) sys_theme = setThemeData('system')
themeList[sys_theme](true)

const ConfigState = JSON.parse(localStorage.getItem(`${LS_PREFIX}webui_config`) || '{}')

if (!ConfigState.disableFullscreen) fullScreen(true)

if (ConfigState.enableSystemFont) {
  const headTag = document.getElementsByTagName('head')[0]
  const styleTag = document.createElement('style')
  styleTag.id = 'font-tag'
  headTag.appendChild(styleTag)
  styleTag.innerHTML = `
    :root {
      --font-family: system-ui, -apple-system, BlinkMacSystemFont, 'HarmonyOS Sans SC', 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif
    }`
}

/* INFO: Apply saved font size + weight at boot so the user's preference is
 * visible immediately. Settings page re-applies on change. */
{
  const headTag = document.getElementsByTagName('head')[0]
  const styleTag = document.createElement('style')
  styleTag.id = 'font-prefs-tag'
  headTag.appendChild(styleTag)
  const _fs = ConfigState.fontSize || 16
  const _fw = ConfigState.fontWeight || 400
  styleTag.innerHTML = `
    html { font-size: ${_fs}px; }
    body { font-weight: ${_fw}; }
  `
}

/* INFO: Apply floating navbar at boot. */
if (ConfigState.floatingNavbar === true) {
  const navbar = document.getElementById('navbar')
  if (navbar) navbar.classList.add('floating')
}

/* INFO: Apply Monet color at boot. */
if (ConfigState.monetColor === true) {
  const headTag = document.getElementsByTagName('head')[0]
  const styleTag = document.createElement('style')
  styleTag.id = 'monet-color-tag'
  headTag.appendChild(styleTag)
  styleTag.innerHTML = `
    :root {
      --primary: #D0BCFF;
      --on-primary: #381E72;
      --primary-container: #4F378B;
      --on-primary-container: #EADDFF;
      --secondary: #CCC2DC;
      --on-secondary: #332D41;
      --secondary-container: #4A4458;
      --on-secondary-container: #E8DEF8;
      --tertiary: #EFB8C8;
      --on-tertiary: #492532;
      --tertiary-container: #633B48;
      --on-tertiary-container: #FFD8E4;
    }
  `
}

/* INFO: Apply iOS Liquid Glass + blur intensity at boot. */
if (ConfigState.liquidGlass === true) {
  const headTag = document.getElementsByTagName('head')[0]
  const styleTag = document.createElement('style')
  styleTag.id = 'liquid-glass-tag'
  headTag.appendChild(styleTag)
  styleTag.innerHTML = `
    body.rz-liquid-glass .card,
    body.rz-liquid-glass .small_card,
    body.rz-liquid-glass .miuix-group {
      background-color: color-mix(in srgb, var(--surface) 65%, transparent) !important;
      backdrop-filter: blur(var(--glass-blur, 12px)) saturate(1.5);
      -webkit-backdrop-filter: blur(var(--glass-blur, 12px)) saturate(1.5);
      border: 1px solid color-mix(in srgb, var(--on-surface) 8%, transparent);
      box-shadow: 0 2px 16px rgba(0, 0, 0, 0.08), inset 0 1px 0 color-mix(in srgb, var(--on-surface) 6%, transparent);
    }
    body.rz-liquid-glass .ma-item {
      background-color: color-mix(in srgb, var(--surface) 50%, transparent) !important;
    }
  `
  document.body.classList.add('rz-liquid-glass')
  document.body.style.setProperty('--glass-blur', `${ConfigState.blurIntensity || 12}px`)
  document.body.style.setProperty('--navbar-blur', `${ConfigState.navbarBlur || 12}px`)
  document.body.style.setProperty('--header-blur', `${ConfigState.headerBlur || 12}px`)
}

/* INFO: This code are meant to load the link with any card have credit-link attribute inside it */
document.addEventListener('click', async (event) => {
  const getLink = event.target.getAttribute('credit-link')
  if (!getLink || typeof getLink !== 'string') return;

  const ptrace64Cmd = await exec(`am start -a android.intent.action.VIEW -d https://${getLink}`).catch(() => {
    return window.open(`https://${getLink}`, "_blank", 'toolbar=0,location=0,menubar=0')
  })

  if (ptrace64Cmd.errno !== 0) return window.open(`https://${getLink}`, "_blank", 'toolbar=0,location=0,menubar=0')
}, false)

window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (event) => {
  if (sys_theme !== 'system') return

  const newColorScheme = event.matches ? 'dark' : 'light'
  if (newColorScheme === 'dark') setDark()
  else if (newColorScheme === 'light') setLight()
})
