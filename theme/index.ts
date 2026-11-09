import { DocFooter as OriginalDocFooter } from '@rspress/core/theme-original'
import { TrademarkNotices } from './TrademarkNotices'
import './trademark-notices.css'

export * from '@alauda/doom/theme'

export function DocFooter() {
  return (
    <>
      <OriginalDocFooter />
      <TrademarkNotices />
    </>
  )
}
