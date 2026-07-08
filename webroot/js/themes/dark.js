import { setDarkNav } from './darkNavbar.js'

const rootCss = document.querySelector(':root')

export function setDark(chooseSet) {
  rootCss.style.setProperty('--background', '#141414')
  rootCss.style.setProperty('--font', '#ffffff')
  rootCss.style.setProperty('--desc', '#c9c9c9')
  rootCss.style.setProperty('--dim', '#1c1c1c')
  rootCss.style.setProperty('--icon', '#494949')
  rootCss.style.setProperty('--icon-bc', '#292929')
  rootCss.style.setProperty('--desktop-navbar', '#252525')
  rootCss.style.setProperty('--button-enabled', '#535353')
  rootCss.style.setProperty('--icon-filter', 'invert(1)')
  rootCss.style.setProperty('--desktop-navicon', '#3a3a3a')
  rootCss.style.setProperty('--button', 'var(--background)')

  // M3 dark color scheme
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
  rootCss.style.setProperty('--m3-background', '#141218')
  rootCss.style.setProperty('--m3-on-background', '#E6E0E9')
  rootCss.style.setProperty('--m3-surface', '#141218')
  rootCss.style.setProperty('--m3-on-surface', '#E6E0E9')
  rootCss.style.setProperty('--m3-surface-variant', '#49454F')
  rootCss.style.setProperty('--m3-on-surface-variant', '#CAC4D0')
  rootCss.style.setProperty('--m3-outline', '#938F99')
  rootCss.style.setProperty('--m3-outline-variant', '#49454F')
  rootCss.style.setProperty('--m3-tonal-surface', '#211F26')
  rootCss.style.setProperty('--m3-surface-container-lowest', '#0F0D13')
  rootCss.style.setProperty('--m3-surface-container-low', '#1D1B20')
  rootCss.style.setProperty('--m3-surface-container', '#211F26')
  rootCss.style.setProperty('--m3-surface-container-high', '#2B2930')
  rootCss.style.setProperty('--m3-surface-container-highest', '#36343B')

  if (chooseSet) setData('dark')
  setDarkNav()
}

function setData(mode) {
  localStorage.setItem('/ReZygisk/theme', mode)

  return mode
}