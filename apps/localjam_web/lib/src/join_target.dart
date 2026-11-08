/// What the page was opened with: its own URL, read once at startup
/// (PROTOCOL.md §1, §1.1; docs/design/WEB_GUEST.md "Join URL").
///
/// The page lives at `http://host:port/join#v=1&token=…&name=…&host=a,b`
/// (or at `/`, with the same fragment). The fragment is the invitation; the
/// page's origin is its host. Whatever other candidates the fragment lists,
/// a browser can only talk to the origin that served it — a `fetch` with a
/// bearer token to another address is a cross-origin request the host never
/// answers for — so the page joins its origin, and keeps the full candidate
/// list only for the "Open in app" link (`localjam://join?…`), where a
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

  /// "Open in app": the `localjam://` form of the link as it came, every
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

/// What the page does with its address at startup, so the token does not
/// stay in the browser's history (or a shared screenshot of the address
/// bar) while a reload still works: an invitation in the fragment is
/// remembered in this tab's `sessionStorage` and the fragment is dropped
/// from the address with `history.replaceState`; a page opened (or
/// reloaded) without a fragment reads the remembered one. Pure, so the
/// rules are tested without a browser; `main` does the storage and history
/// calls.
class InviteStartup {
  const InviteStartup._(this.page, this.remember, this.cleanAddress);

  /// The URL to read the invitation from ([JoinTarget.fromPageUrl]).
  final Uri page;

  /// The fragment to remember for this tab, or null to leave what is
  /// remembered alone.
  final String? remember;

  /// What to put in the address bar once [remember] is stored (the page's
  /// URL without its fragment), or null to leave the address alone. Only
  /// after the store succeeded: a tab that cannot remember (storage
  /// disabled) keeps the token in its address, or a reload would lose it.
  final Uri? cleanAddress;

  /// The startup for a page opened at [page] in a tab that remembers
  /// [stored] (null: nothing, or no storage).
  ///
  /// * A fragment that is an invitation wins: remember it, clean the
  ///   address. (A new link opened in the same tab replaces the old one.)
  /// * No fragment at all: the remembered invitation, if any — a reload.
  /// * A fragment that is not an invitation: read as it is (no invite),
  ///   never mixed with a remembered one.
  static InviteStartup resolve(Uri page, String? stored) {
    if (page.hasFragment && page.fragment.isNotEmpty) {
      if (!JoinTarget.fromPageUrl(page).canJoin) {
        return InviteStartup._(page, null, null);
      }
      return InviteStartup._(page, page.fragment, page.removeFragment());
    }
    if (stored != null && stored.isNotEmpty) {
      final remembered = page.replace(fragment: stored);
      if (JoinTarget.fromPageUrl(remembered).canJoin) {
        return InviteStartup._(remembered, null, null);
      }
    }
    return InviteStartup._(page, null, null);
  }
}
