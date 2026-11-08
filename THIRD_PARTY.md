# Third party software

Rivulet itself is MIT licensed (see LICENSE). Release builds also ship these programs, which are run as
separate processes and keep their own licenses:

| Component | License | Source |
|---|---|---|
| aria2 (`aria2c`) | GPL-2.0-or-later | https://github.com/aria2/aria2 |
| OpenSSL, libssh2, c-ares, SQLite, zlib and other libraries aria2 links against | Their own licenses (Apache-2.0, BSD, public domain, zlib) | https://formulae.brew.sh/formula/aria2 |

The aria2 version bundled in a release is the one from Homebrew on the day it was built. Its complete source
is available at the link above. Build without it using `BUNDLE_ARIA2=0 ./Scripts/build_app.sh`.

Rivulet does not include any code from Cat-Catch, JDownloader or Transmission. The interface follows the
layout of the Transmission Mac app; the Link Grabber follows the idea of JDownloader's link grabber and
plugins, written from scratch.
