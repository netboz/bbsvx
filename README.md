BBSvx
=====

BBSvx is blockchain powered [BBS](https://github.com/netboz/bbs)

dependencies
------------

* GNU Make
* Gcc
* libexpat 1.95 or higher
* Libyaml 0.1.4 or higher
* Erlang/OTP 26.2 or higher
* OpenSSL 1.0.0 or higher for encryption

  ... and a few more.

Build
-----

    $ export BUILD_WITHOUT_QUIC=true
    $ rebar3 compile
