import { jsx } from 'react/jsx-runtime'
import { Layout as DoomLayout } from '@alauda/doom/theme'
import { TrademarkNotices } from './TrademarkNotices'
import './trademark-notices.css'

export * from '@alauda/doom/theme'

export function Layout() {
  return jsx(DoomLayout, {
    bottom: jsx(TrademarkNotices, {}),
  })
}
