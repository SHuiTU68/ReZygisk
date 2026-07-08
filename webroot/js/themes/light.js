import { setLightNav } from './lightNavbar.js'

const rootCss = document.querySelector(':root')

export function setLight(chooseSet) {
  // MiuiX light palette (HyperOS light, blue accent)
  rootCss.style.setProperty('--primary', '#1677FF')
  rootCss.style.setProperty('--on-primary', '#FFFFFF')
  rootCss.style.setProperty('--primary-container', '#D6E4FF')
  rootCss.style.setProperty('--on-primary-container', '#001A41')
  rootCss.style.setProperty('--secondary', '#4F66A8')
  rootCss.style.setProperty('--on-secondary', '#FFFFFF')
  rootCss.style.setProperty('--secondary-container', '#DBE1FF')
  rootCss.style.setProperty('--on-secondary-container', '#06215C')
  rootCss.style.setProperty('--tertiary', '#3C9F6E')
  rootCss.style.setProperty('--error', '#BA1A1A')
  rootCss.style.setProperty('--on-error', '#FFFFFF')
  rootCss.style.setProperty('--error-container', '#FFDAD6')
  rootCss.style.setProperty('--on-error-container', '#410002')

  rootCss.style.setProperty('--background', '#F7F8FA')
  rootCss.style.setProperty('--on-background', '#1A1C1E')
  rootCss.style.setProperty('--surface', '#FFFFFF')
  rootCss.style.setProperty('--on-surface', '#1A1C1E')
  rootCss.style.setProperty('--surface-variant', '#E2E2E6')
  rootCss.style.setProperty('--on-surface-variant', '#45474A')
  rootCss.style.setProperty('--surface-container', '#F0F1F4')
  rootCss.style.setProperty('--surface-container-high', '#EAEBEF')
  rootCss.style.setProperty('--surface-container-highest', '#E4E6EA')
  rootCss.style.setProperty('--surface-dim', '#D7DADF')
  rootCss.style.setProperty('--surface-bright', '#FCFCFE')
  rootCss.style.setProperty('--outline', '#767680')
  rootCss.style.setProperty('--outline-variant', '#C6C6D0')
  rootCss.style.setProperty('--scrim', '#000000')

  // Legacy aliases
  rootCss.style.setProperty('--font', '#1A1C1E')
  rootCss.style.setProperty('--desc', '#45474A')
  rootCss.style.setProperty('--dim', '#D7DADF')
  rootCss.style.setProperty('--icon', '#767680')
  rootCss.style.setProperty('--icon-bc', '#E4E6EA')
  rootCss.style.setProperty('--desktop-navbar', '#FFFFFF')
  rootCss.style.setProperty('--desktop-navicon', '#F0F1F4')
  rootCss.style.setProperty('--button-enabled', '#1677FF')
  rootCss.style.setProperty('--icon-filter', 'invert(0.3)')
  rootCss.style.setProperty('--button', '#EAEBEF')

  if (chooseSet) setData('light')

  setLightNav()
}

function setData(mode) {
  localStorage.setItem('/Hrezygisk/theme', mode)

  return mode
}
