/// Script injected before any page script runs (WebViewCompat.addDocumentStartJavaScript).
///
/// Why it exists: WebRTC UDP (STUN/ICE) and QUIC are not reachable by the HTTP proxy seal, by CSP
/// `connect-src`, or by request interception, and Android WebView has no WebRTC policy setting.
/// A device run showed STUN binding requests reaching a LAN host with every other layer active.
/// The only control available is to remove the APIs before the page can touch them.
///
/// This is not an isolation boundary on its own (ADR-006): it relies on the page having no way to
/// get a fresh realm. Frames, workers and new windows are refused by CSP and navigation rules, and
/// the probe app tries to obtain a pristine realm through about:blank and srcdoc frames. Starting a
/// page without this script is refused (see SurfaceView), so a WebView that cannot inject it never
/// runs an app.
const String documentStartHardening = r'''
(function () {
  "use strict";
  var names = [
    "RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCSessionDescription",
    "RTCIceCandidate", "RTCRtpSender", "RTCRtpReceiver", "RTCRtpTransceiver", "RTCSctpTransport",
    "RTCDtlsTransport", "RTCIceTransport", "RTCPeerConnectionIceEvent", "RTCCertificate",
    "RTCDTMFSender", "RTCError", "RTCErrorEvent", "WebTransport", "WebTransportBidirectionalStream",
    "WebTransportDatagramDuplexStream", "WebTransportError"
  ];
  for (var i = 0; i < names.length; i++) {
    try {
      Object.defineProperty(window, names[i], {
        value: undefined, writable: false, configurable: false, enumerable: false
      });
    } catch (e) { /* already locked: nothing more to do */ }
  }
})();
''';
