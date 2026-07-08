import { setDarkNav } from './darkNavbar.js'

const rootCss = document.querySelector(':root')

export function setAmoled(chooseSet) {
  // MiuiX AMOLED palette — true black surfaces, blue accent
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

  // AMOLED: pure black background + surface
  rootCss.style.setProperty('--background', '#000000')
  rootCss.style.setProperty('--on-background', '#E6E6E6')
  rootCss.style.setProperty('--surface', '#000000')
  rootCss.style.setProperty('--on-surface', '#E6E6E6')
  rootCss.style.setProperty('--surface-variant', '#1F1F22')
  rootCss.style.setProperty('--on-surface-variant', '#B0B0B4')
  rootCss.style.setProperty('--surface-container', '#0E0E10')
  rootCss.style.setProperty('--surface-container-high', '#18181A')
  rootCss.style.setProperty('--surface-container-highest', '#222225')
  rootCss.style.setProperty('--surface-dim', '#000000')
  rootCss.style.setProperty('--surface-bright', '#2C2C2F')
  rootCss.style.setProperty('--outline', '#6E6E73')
  rootCss.style.setProperty('--outline-variant', '#2A2A2D')
  rootCss.style.setProperty('--scrim', '#000000')

  // Legacy aliases
  rootCss.style.setProperty('--font', '#E6E6E6')
  rootCss.style.setProperty('--desc', '#B0B0B4')
  rootCss.style.setProperty('--bright', '#4996F3')
  rootCss.style.setProperty('--dim', '#000000')
  rootCss.style.setProperty('--icon', '#6E6E73')
  rootCss.style.setProperty('--icon-bc', '#0E0E10')
  rootCss.style.setProperty('--desktop-navbar', '#000000')
  rootCss.style.setProperty('--desktop-navicon', '#0E0E10')
  rootCss.style.setProperty('--button-enabled', '#4996F3')
  rootCss.style.setProperty('--icon-filter', 'invert(1)')
  rootCss.style.setProperty('--button', '#18181A')

  if (chooseSet) setData('amoled')
  setDarkNav()
}

function setData(mode) {
  localStorage.setItem('/Hrezygisk/theme', mode)

  return mode
}
