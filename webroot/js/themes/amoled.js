import { setDarkNav } from './darkNavbar.js'

const rootCss = document.querySelector(':root')

export function setAmoled(chooseSet) {
  rootCss.style.setProperty('--background', '#000000')
  rootCss.style.setProperty('--font', '#d9d9d9')
  rootCss.style.setProperty('--desc', '#a9a9a9')
  rootCss.style.setProperty('--dim', '#0e0e0eff')
  rootCss.style.setProperty('--icon', '#292929ff')
  rootCss.style.setProperty('--icon-bc', '#202020ff')
  rootCss.style.setProperty('--desktop-navbar', '#161616ff')
  rootCss.style.setProperty('--desktop-navicon', '#242424ff')
  rootCss.style.setProperty('--icon-filter', 'invert(1)')
  rootCss.style.setProperty('--button', 'var(--background)')

  // M3 AMOLED-tuned dark scheme (true black surfaces)
  rootCss.style.setProperty('--m3-primary', '#D0BCFF')
  rootCss.style.setProperty('--m3-on-primary', '#381E72')
  rootCss.style.setProperty('--m3-primary-container', '#4F378B')
  rootCss.style.setProperty('--m3-on-primary-container', '#EADDFF')
  rootCss.style.setProperty('--m3-secondary', '#CCC2DC')
  rootCss.style.setProperty('--m3-on-secondary', '#332D41')
  rootCss.style.setProperty('--m3-secondary-container', '#4A4458')
  rootCss.style.setProperty('--m3-on-secondary-container', '#E8DEF8')
  rootCss.style.setProperty('--m3-tertiary', '#EFB8C8')
  rootCss.style.setProperty('--m3-error', '#F2B8B5')
  rootCss.style.setProperty('--m3-on-error', '#601410')
  rootCss.style.setProperty('--m3-error-container', '#8C1D18')
  rootCss.style.setProperty('--m3-on-error-container', '#F9DEDC')
  rootCss.style.setProperty('--m3-background', '#000000')
  rootCss.style.setProperty('--m3-on-background', '#E6E0E9')
  rootCss.style.setProperty('--m3-surface', '#000000')
  rootCss.style.setProperty('--m3-on-surface', '#E6E0E9')
  rootCss.style.setProperty('--m3-surface-variant', '#49454F')
  rootCss.style.setProperty('--m3-on-surface-variant', '#CAC4D0')
  rootCss.style.setProperty('--m3-outline', '#938F99')
  rootCss.style.setProperty('--m3-outline-variant', '#49454F')
  rootCss.style.setProperty('--m3-tonal-surface', '#1A1A1A')
  rootCss.style.setProperty('--m3-surface-container-lowest', '#000000')
  rootCss.style.setProperty('--m3-surface-container-low', '#0A0A0A')
  rootCss.style.setProperty('--m3-surface-container', '#141414')
  rootCss.style.setProperty('--m3-surface-container-high', '#1E1E1E')
  rootCss.style.setProperty('--m3-surface-container-highest', '#282828')

  if (chooseSet) setData('amoled')
  setDarkNav()
}

function setData(mode) {
  localStorage.setItem('/ReZygisk/theme', mode)

  return mode
}