{{flutter_js}}
{{flutter_build_config}}

// The LocalJam listener page runs on a LAN with no internet
// (docs/design/WEB_GUEST.md D8): every file comes from the host that served
// the page. CanvasKit is bundled (`--no-web-resources-cdn`), and the
// engine's font fallback — which would otherwise download missing glyphs
// from a font CDN — is pointed at this origin, where nothing is served:
// the page's copy and Nepali/Hindi text draw with the bundled Manrope and
// Noto Sans Devanagari; a glyph neither has (CJK, …) costs at most a few
// same-origin 404s (each fallback font is tried once, then given up on for
// the session) and draws as a box. See README "Fonts".
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
    fontFallbackBaseUrl: "assets/font-fallback/",
  },
});
