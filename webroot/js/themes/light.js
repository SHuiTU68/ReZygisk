import { setLightNav } from './lightNavbar.js'

const rootCss = document.querySelector(':root')


export function setLight(chooseSet) {
  rootCss.style.setProperty('--background', '#f2f2f2')
  rootCss.style.setProperty('--font', '#222222ff')
  rootCss.style.setProperty('--desc', '#535353ff')
  rootCss.style.setProperty('--dim', '#e0e0e0')
  rootCss.style.setProperty('--icon', '#acacac')
  rootCss.style.setProperty('--desktop-navbar', '#fefefe')
  rootCss.style.setProperty('--icon-filter', 'invert(0.3)')
  rootCss.style.setProperty('--desktop-navicon', '#eeeeee')
  rootCss.style.setProperty('--button-enabled', '#eeeeee')
  rootCss.style.setProperty('--icon-bc', '#c9c9c9')
  rootCss.style.setProperty('--button', '#b3b3b3')

  // M3 light color scheme
  rootCss.style.setProperty('--m3-primary', '#6750A4')
  rootCss.style.setProperty('--m3-on-primary', '#FFFFFF')
  rootCss.style.setProperty('--m3-primary-container', '#EADDFF')
  rootCss.style.setProperty('--m3-on-primary-container', '#4F378B')
  rootCss.style.setProperty('--m3-secondary', '#625B71')
  rootCss.style.setProperty('--m3-on-secondary', '#FFFFFF')
  rootCss.style.setProperty('--m3-secondary-container', '#E8DEF8')
  rootCss.style.setProperty('--m3-on-secondary-container', '#4A4458')
  rootCss.style.setProperty('--m3-tertiary', '#7D5260')
  rootCss.style.setProperty('--m3-error', '#B3261E')
  rootCss.style.setProperty('--m3-on-error', '#FFFFFF')
  rootCss.style.setProperty('--m3-error-container', '#F9DEDC')
  rootCss.style.setProperty('--m3-on-error-container', '#8C1D18')
  rootCss.style.setProperty('--m3-background', '#FEF7FF')
  rootCss.style.setProperty('--m3-on-background', '#1D1B20')
  rootCss.style.setProperty('--m3-surface', '#FEF7FF')
  rootCss.style.setProperty('--m3-on-surface', '#1D1B20')
  rootCss.style.setProperty('--m3-surface-variant', '#E7E0EC')
  rootCss.style.setProperty('--m3-on-surface-variant', '#49454F')
  rootCss.style.setProperty('--m3-outline', '#79747E')
  rootCss.style.setProperty('--m3-outline-variant', '#CAC4D0')
  rootCss.style.setProperty('--m3-tonal-surface', '#F3EDF7')
  rootCss.style.setProperty('--m3-surface-container-lowest', '#FFFFFF')
  rootCss.style.setProperty('--m3-surface-container-low', '#F7F2FA')
  rootCss.style.setProperty('--m3-surface-container', '#F3EDF7')
  rootCss.style.setProperty('--m3-surface-container-high', '#ECE6F0')
  rootCss.style.setProperty('--m3-surface-container-highest', '#E6E0E9')

  if (chooseSet) setData('light')

  setLightNav()
}

function setData(mode) {
  localStorage.setItem('/ReZygisk/theme', mode)

  return mode
}
