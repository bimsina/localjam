/// What the page was opened with: its own URL, read once at startup
/// (PROTOCOL.md §1, §1.1; docs/design/WEB_GUEST.md "Join URL").
///
/// The page lives at `http://host:port/join#v=1&token=…&name=…&host=a,b`
/// (or at `/`, with the same fragment). The fragment is the invitation; the
/// page's origin is its host. Whatever other candidates the fragment lists,
/// a browser can only talk to the origin that served it — a `fetch` with a
/// bearer token to another address is a cross-origin request the host never
/// answers for — so the page joins its origin, and keeps the full candidate
/// list only for the "Open in App" link (`localjam://join?…`), where a
/// native joiner tries each one.
library;

import 'package:localjam_client/localjam_client.dart';

/// The invitation the page URL carries, if it carries one.
class JoinTarget {
  const JoinTarget._(this.link, this.appLink);

  /// The page's URL carried no usable invitation (no token, or not a join
  /// URL at all): there is nothing to join.
  const JoinTarget.none() : link = null, appLink = null;

  /// The join parameters the page joins with: the fragment's, with the
  /// page's own origin as the only candidate. Null without an invitation.
  final JoinLink? link;

  /// "Open in App": the `localjam://` form of the link as it came, every
  /// candidate included (§1). Null without an invitation.
  final Uri? appLink;

  /// Whether the page has something to join.
  bool get canJoin => link != null;

  /// The jam's name from the link, trimmed; null when it carries none.
  String? get jamName => link?.displayName;

  /// What the guest engine joins (its http form, §1).
  Uri? get joinUri => link?.toHttpUri();

  /// Reads [page] — `Uri.base` at startup — as the http join form. A page
  /// served at `/` reads the same fragment as one at `/join`.
  static JoinTarget fromPageUrl(Uri page) {
    if (page.scheme != 'http' || page.host.isEmpty) {
      return const JoinTarget.none();
    }
    final asJoin = JoinLink.fromUri(page.replace(path: '/join'));
    if (asJoin == null) return const JoinTarget.none();
    final own = Uri.decodeComponent(page.host);
    final JoinLink link;
    try {
      link = asJoin.copyWith(hosts: [own], port: page.port);
    } on ArgumentError {
      return const JoinTarget.none();
    }
    return JoinTarget._(link, asJoin.toLocaljamUri());
  }
}
