BBSvx
=====


BBSvx is blockchain powered [BBS](https://github.com/netboz/bbs)

This project is under development and started as a proof of concept.

Integrating blockchain into BBS should permit to :

* Have permanent ontologies.
* Have permanently running agents ( agents being ontologies )
* Keep concistency of ontologies in a distributed environements as agents are interacting with them
* Benefit from blockchain inherent characteristics : Enhanced security, transparency, tracability etc ...

This blockchain is supported by a P2P overlay network formed by nodes following [SPRAY protocol](https://hal.science/hal-01203363) protocol. This permits to bring up a network where each peer only have a partial view of the whole network, named neighnours. Each node exchange a part of its neighbours with one of them.

Nodes are exchanging messages following [Epto protocol](https://www.dpss.inesc-id.pt/~mm/papers/2015/middleware_epto.pdf). This permits to have a concistent ordering of events among the nodes.

To permit side effects to prolog queries, a leader is elected among the nodes of an ontology.


State of advancement
--------------------

At this moment, are in alpha state :

  * The Spray network
  * Epto algorithm messaging
  * Leader election

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
Pls keep an eye on Grafana dashboard, and see the overlay evolving.

   
