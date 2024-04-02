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
```
    $ export BUILD_WITHOUT_QUIC=true
    $ rebar3 compile
```
Docker
------

Best way to see this running is via docker stack.

1) build the image
    ```
    $ docker build . -t bbsvx
    ```
2) Run some nodes

   This command will actually run two nodes. One node named bbsvx_root, acting as the first instance of a fake ontology named `"bbsvx:root"`, and one client node connecting to the node root.

    ```
    $ docker compose up  --scale bbsvx_client=1    
    ```
    
    If everything goes fine, you should be able to connect to grafana at [grafana](http://localhost:3000).

   Most of the things are hapenning in the Dashboards section,  in the Spray Monitoring one.

3) For things to be interesting, you can scale up the platform by adding client nodes :
   ```
   docker compose up  --scale bbsvx_client=2 -d
   docker compose up  --scale bbsvx_client=3 -d
   ....
   docker compose up  --scale bbsvx_client=16 -d
   ```
Pls keep an eye on Grafana dashboard, and see the overay evolving.

   
