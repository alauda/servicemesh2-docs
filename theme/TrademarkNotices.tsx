function NoticeContent() {
  return (
    <div className="alauda-trademark-notices__content">
      <p>
        Istio® is a registered trademark of The Linux Foundation.
        <br />
        Alauda is an independent vendor. This product is not affiliated with, endorsed by, or sponsored by The Linux Foundation. All trademarks are the property of their respective owners and are used here for identification purposes only.
      </p>
      <p>
        Kiali is an open source project sponsored by Red Hat, Inc.
        <br />
        Alauda is an independent vendor. This product is not affiliated with, endorsed by, or sponsored by Red Hat, Inc. All trademarks are the property of their respective owners and are used here for identification purposes only.
      </p>
    </div>
  );
}

export function TrademarkNotices() {
  return (
    <footer className="alauda-trademark-notices">
      <details>
        <summary>Trademark notices</summary>
        <NoticeContent />
      </details>
      <div className="alauda-trademark-notices__print">
        <NoticeContent />
      </div>
    </footer>
  );
}
