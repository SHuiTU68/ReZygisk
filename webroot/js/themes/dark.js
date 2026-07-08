import { setDarkNav } from './darkNavbar.js'

const rootCss = document.querySelector(':root')

export function setDark(chooseSet) {
  // MiuiX dark palette (HyperOS dark, blue accent)
  rootCss.style.setProperty('--primary', '#4996F3')
  rootCss.style.setProperty('--on-primary', '#FFFFFF')
  rootCss.style.setProperty('--primary-container', '#0D3E8E')
  rootCss.style.setProperty('--on-primary-container', '#CDE0FF')
  rootCss.style.setProperty('--secondary', '#8AB1FA')
  rootCss.style.setProperty('--on-secondary', '#002A6B')
  rootCss.style.setProperty('--secondary-container', '#1E3A66')
  rootCss.style.setProperty('--on-secondary-container', '#CDE0FF')
  rootCss.style.setProperty('--tertiary', '#6FCB9E')
  rootCss.style.setProperty('--error', '#FF8A80')
  rootCss.style.setProperty('--on-error', '#4A0000')
  rootCss.style.setProperty('--error-container', '#5D1A1A')
  rootCss.style.setProperty('--on-error-container', '#FFDAD4')

  rootCss.style.setProperty('--background', '#0E0E0F')
  rootCss.style.setProperty('--on-background', '#E6E6E6')
  rootCss.style.setProperty('--surface', '#1A1A1C')
  rootCss.style.setProperty('--on-surface', '#E6E6E6')
  rootCss.style.setProperty('--surface-variant', '#2A2A2D')
  rootCss.style.setProperty('--on-surface-variant', '#B0B0B4')
  rootCss.style.setProperty('--surface-container', '#232325')
  rootCss.style.setProperty('--surface-container-high', '#2D2D30')
  rootCss.style.setProperty('--surface-container-highest', '#38383B')
  rootCss.style.setProperty('--surface-dim', '#141416')
  rootCss.style.setProperty('--surface-bright', '#3A3A3D')
  rootCss.style.setProperty('--outline', '#6E6E73')
  rootCss.style.setProperty('--outline-variant', '#3A3A3D')
  rootCss.style.setProperty('--scrim', '#000000')

  // Legacy aliases
  rootCss.style.setProperty('--font', '#E6E6E6')
  rootCss.style.setProperty('--desc', '#B0B0B4')
  rootCss.style.setProperty('--bright', '#4996F3')
  rootCss.style.setProperty('--dim', '#141416')
  rootCss.style.setProperty('--icon', '#6E6E73')
  rootCss.style.setProperty('--icon-bc', '#232325')
  rootCss.style.setProperty('--desktop-navbar', '#1A1A1C')
  rootCss.style.setProperty('--desktop-navicon', '#232325')
  rootCss.style.setProperty('--button-enabled', '#4996F3')
  rootCss.style.setProperty('--icon-filter', 'invert(1)')
  rootCss.style.setProperty('--button', '#2D2D30')

  if (chooseSet) setData('dark')
  setDarkNav()
}

function setData(mode) {
  localStorage.setItem('/ReZygisk/theme', mode)

  return mode
}
