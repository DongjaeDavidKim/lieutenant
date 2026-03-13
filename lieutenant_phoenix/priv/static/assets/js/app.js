// Lieutenant — Phoenix LiveView app.js (no bundler)
// Phoenix and LiveView are loaded as separate scripts

let Hooks = {}
Hooks.AutoScroll = {
  mounted() {
    this._autoScroll = true
    this.el.addEventListener("scroll", () => {
      this._autoScroll = (this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight) < 50
    })
  },
  updated() {
    if (this._autoScroll) {
      this.el.scrollTop = this.el.scrollHeight
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
  hooks: Hooks,
  params: {_csrf_token: csrfToken},
  longPollFallbackMs: 2500
})

liveSocket.connect()
window.liveSocket = liveSocket
