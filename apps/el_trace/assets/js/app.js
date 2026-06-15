import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// 핸드오프 그래프를 클라이언트에서 Graphviz(viz.js, CDN)로 렌더한다.
// viz.js가 로드돼 있으면 DOT을 SVG로 그려 넣고 서버사이드 SVG 폴백을 숨긴다.
// viz.js가 없거나(오프라인/CDN 차단) 렌더 실패 시 아무것도 하지 않아 서버 SVG가 그대로 보인다.
let Hooks = {}
Hooks.DotGraph = {
  mounted() { this.render() },
  updated() { this.render() },
  render() {
    let dot = this.el.dataset.dot
    let target = this.el.querySelector("[data-viz-target]")
    if (!dot || !target || typeof Viz === "undefined" || !Viz.instance) return
    Viz.instance().then(viz => {
      target.replaceChildren(viz.renderSVGElement(dot))
      let fb = this.el.dataset.fallback && document.getElementById(this.el.dataset.fallback)
      if (fb) fb.style.display = "none"
    }).catch(() => {}) // 렌더 실패 시 서버 SVG 폴백 유지
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {hooks: Hooks, params: {_csrf_token: csrfToken}})

liveSocket.connect()
window.liveSocket = liveSocket
