/// The page's few building blocks, in the app's visual language
/// (DESIGN_SPEC_V3 §5): soft-rectangle buttons that dim when pressed (no
/// ripples), a cover with a placeholder, flat avatars, grouped sections and
/// the empty/terminal state.
library;

import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'design.dart';

/// The palette for the current brightness.
PageColors colorsOf(BuildContext context) =>
    PageColors.of(Theme.of(context).brightness);

/// A centred column at most [Metrics.column] wide with the side gutter:
/// a phone's width on a phone, a readable column on a laptop.
class PageColumn extends StatelessWidget {
  const PageColumn({super.key, required this.children, this.center = false});

  final List<Widget> children;

  /// Centre the content vertically when it is shorter than the screen.
  final bool center;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: Metrics.gutter,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: center ? constraints.maxHeight - 48 : 0,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Metrics.column),
                child: Column(
                  mainAxisAlignment: center
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How a [PageButton] looks.
enum PageButtonStyle { filled, tinted, plain }

/// A soft-rectangle button: 50 tall, dims to 0.7 pressed, 0.35 disabled; a
/// spinner replaces the label while [busy].
class PageButton extends StatefulWidget {
  const PageButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.style = PageButtonStyle.filled,
    this.busy = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final PageButtonStyle style;
  final bool busy;
  final IconData? icon;

  @override
  State<PageButton> createState() => _PageButtonState();
}

class _PageButtonState extends State<PageButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final enabled = widget.onPressed != null && !widget.busy;
    final (Color ground, Color ink) = switch (widget.style) {
      PageButtonStyle.filled => (c.tintFilled, c.onTint),
      PageButtonStyle.tinted => (c.tintFill, c.tint),
      PageButtonStyle.plain => (Colors.transparent, c.tint),
    };
    final label = Text(
      widget.label,
      textAlign: TextAlign.center,
      style: PageType.headline.copyWith(color: ink),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: !enabled && !widget.busy
              ? 0.35
              : _pressed
              ? 0.7
              : 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: 50),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: ground,
              borderRadius: BorderRadius.circular(Metrics.button),
            ),
            alignment: Alignment.center,
            child: widget.busy
                ? CupertinoActivityIndicator(color: ink)
                : widget.icon == null
                ? label
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, color: ink, size: 20),
                      const SizedBox(width: 8),
                      Flexible(child: label),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A round icon button with a 44 hit area that dims when pressed.
class PageIconButton extends StatefulWidget {
  const PageIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.size = 28,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;

  @override
  State<PageIconButton> createState() => _PageIconButtonState();
}

class _PageIconButtonState extends State<PageIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: SizedBox(
          width: widget.size + 20 < 44 ? 44 : widget.size + 20,
          height: widget.size + 20 < 44 ? 44 : widget.size + 20,
          child: Opacity(
            opacity: !enabled
                ? 0.3
                : _pressed
                ? 0.6
                : 1,
            child: Icon(
              widget.icon,
              size: widget.size,
              color: widget.color ?? c.tint,
            ),
          ),
        ),
      ),
    );
  }
}

/// Square artwork from bytes, or the placeholder (DESIGN_SPEC_V3 §5
/// Artwork): a fill ground with a music note at 40% of the tile.
class Cover extends StatelessWidget {
  const Cover({
    super.key,
    required this.bytes,
    required this.size,
    this.radius = Metrics.cover,
  });

  final Uint8List? bytes;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final image = bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: image == null
            ? ColoredBox(
                color: c.fillSecondary,
                child: Icon(
                  CupertinoIcons.music_note,
                  size: size * 0.4,
                  color: c.tertiaryLabel,
                ),
              )
            : Image.memory(
                image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, _, _) =>
                    Cover(bytes: null, size: size, radius: radius),
              ),
      ),
    );
  }
}

/// Loads [item]'s cover once per item id and draws it.
class AsyncCover extends StatefulWidget {
  const AsyncCover({
    super.key,
    required this.itemKey,
    required this.load,
    required this.size,
    this.radius = Metrics.cover,
  });

  /// Identifies the item: a new key loads again.
  final String? itemKey;
  final Future<Uint8List?> Function()? load;
  final double size;
  final double radius;

  @override
  State<AsyncCover> createState() => _AsyncCoverState();
}

class _AsyncCoverState extends State<AsyncCover> {
  Uint8List? _bytes;
  String? _loadedKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AsyncCover old) {
    super.didUpdateWidget(old);
    if (old.itemKey != widget.itemKey) _load();
  }

  void _load() {
    final key = widget.itemKey;
    final load = widget.load;
    _loadedKey = key;
    if (load == null) {
      _bytes = null;
      return;
    }
    load().then((bytes) {
      if (!mounted || _loadedKey != key) return;
      setState(() => _bytes = bytes);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) =>
      Cover(bytes: _bytes, size: widget.size, radius: widget.radius);
}

/// A flat avatar: a colour from the person's display name, white initials.
/// The colour is the app's `identityColor` (apps/localjam_app
/// `widgets/avatar.dart`): FNV-1a over the name's UTF-16 code units into
/// [avatarPalette], so a person has the same face in the browser as on
/// every phone. (The app also spreads colours apart inside one jam; the
/// page does not.)
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 36});

  final String name;
  final double size;

  static String initialsOf(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final letters = [for (final w in words.take(2)) w.characters.first];
    return letters.isEmpty ? '?' : letters.join().toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    var hash = 0x811c9dc5;
    for (final unit in name.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: avatarPalette[hash % avatarPalette.length],
          shape: BoxShape.circle,
        ),
        child: Text(
          initialsOf(name),
          textScaler: TextScaler.noScaling,
          style: PageType.footnote.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: size * 0.4,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// A grouped section: a sentence-case header, rows on a rounded surface.
class PageSection extends StatelessWidget {
  const PageSection({
    super.key,
    this.header,
    this.trailing,
    required this.children,
    this.footer,
  });

  final String? header;
  final String? trailing;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Container(height: 0.5, color: c.separator),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        header!,
                        style: PageType.footnote.copyWith(
                          color: c.secondaryLabel,
                        ),
                      ),
                    ),
                  ),
                  if (trailing != null)
                    Text(
                      trailing!,
                      style: PageType.footnote.copyWith(
                        color: c.secondaryLabel,
                      ),
                    ),
                ],
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(Metrics.section),
            child: ColoredBox(
              color: c.groupedSurface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rows,
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                footer!,
                style: PageType.footnote.copyWith(color: c.secondaryLabel),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row inside a [PageSection]: leading, title, subtitle, trailing; dims
/// on press when tappable.
class PageRow extends StatefulWidget {
  const PageRow({
    super.key,
    this.leading,
    required this.title,
    this.titleStyle,
    this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.onTap,
    this.semanticsLabel,
  });

  final Widget? leading;
  final String title;
  final TextStyle? titleStyle;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? semanticsLabel;

  @override
  State<PageRow> createState() => _PageRowState();
}

class _PageRowState extends State<PageRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final tappable = widget.onTap != null;
    final row = Container(
      color: _pressed ? c.fill.withValues(alpha: 0.5) : null,
      constraints: const BoxConstraints(minHeight: Metrics.rowMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      widget.titleStyle ??
                      PageType.body.copyWith(color: c.label),
                ),
                if (widget.subtitle != null)
                  Text(
                    widget.subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: PageType.subheadline.copyWith(
                      color: widget.subtitleColor ?? c.secondaryLabel,
                    ),
                  ),
              ],
            ),
          ),
          if (widget.trailing != null) ...[
            const SizedBox(width: 8),
            widget.trailing!,
          ],
        ],
      ),
    );
    if (!tappable) {
      return Semantics(label: widget.semanticsLabel, child: row);
    }
    return Semantics(
      button: true,
      label: widget.semanticsLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: row,
      ),
    );
  }
}

/// The one empty / terminal state (DESIGN_SPEC_V3 §5 "Empty state", v3.1
/// §6): a 48 icon, a title, one sentence, then buttons that hug their label.
/// Never a spinner.
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    return PageColumn(
      center: true,
      children: [
        Icon(icon, size: 48, color: c.tertiaryLabel),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: PageType.title2.copyWith(color: c.label),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: PageType.subheadline.copyWith(color: c.secondaryLabel),
        ),
        for (final action in actions) ...[
          const SizedBox(height: 12),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 140),
              child: IntrinsicWidth(child: action),
            ),
          ),
        ],
      ],
    );
  }
}
