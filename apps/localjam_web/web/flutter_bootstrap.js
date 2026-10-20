{{flutter_js}}
{{flutter_build_config}}

// The LocalJam listener page runs on a LAN with no internet
// (docs/design/WEB_GUEST.md D8): every file comes from the host that served
// the page. CanvasKit is bundled (`--no-web-resources-cdn`), and the
// engine's font fallback — which would otherwise download missing glyphs
// from a font CDN — is pointed at this origin. The page's copy only uses
// glyphs its bundled fonts have, so no fallback is ever needed.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
    fontFallbackBaseUrl: "assets/font-fallback/",
  },
});
