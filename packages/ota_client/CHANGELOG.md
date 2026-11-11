## Unreleased

* **Security:** patch ids must be canonical lowercase UUIDs (Dart and Android); other ids are
  refused before any download or file operation.
* **Security:** plain `http://` is refused except loopback (any build) and `10.0.2.2` (debug
  builds only), for the server and patch downloads.
* **Security:** download timeouts (response, stall, total) and a connect timeout.

## 0.1.0-alpha.1

* First public alpha, released with Flutter OTA System v0.1.0-alpha.1. See the repository
  [CHANGELOG](../../CHANGELOG.md).
