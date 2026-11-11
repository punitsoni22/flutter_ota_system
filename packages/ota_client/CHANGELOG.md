## Unreleased

* **Security:** patch ids must be canonical lowercase UUIDs (Dart and Android); other ids are
  refused before any download or file operation.
* **Security:** release builds accept `https://` only (server, downloads, redirects). Debug
  builds also allow `http://localhost` and `http://10.0.2.2`. No https→http redirects; every
  redirect hop is checked; the device token is not forwarded to another host.
* **Security:** download timeouts (response, stall, total) and a connect timeout.

## 0.1.0-alpha.1

* First public alpha, released with Flutter OTA System v0.1.0-alpha.1. See the repository
  [CHANGELOG](../../CHANGELOG.md).
