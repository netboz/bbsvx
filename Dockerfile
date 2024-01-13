# Build stage 0
FROM erlang:alpine

# Set working directory
RUN mkdir /buildroot
WORKDIR /buildroot
RUN mkdir src include config log
COPY src ./src
COPY include ./include
COPY config ./config
COPY priv ./priv
COPY rebar.config ./rebar.config
COPY rebar.lock ./rebar.lock
COPY ejabberd.yml ./_build/default/rel/bbsvx/ejabberd.yml


RUN apk update
# Install some libs
RUN apk add --no-cache openssl-dev && \
    apk add --no-cache ncurses-libs && \
    apk add --no-cache libstdc++ && \
    apk add --no-cache git && \
    apk add --no-cache libsodium-dev && \
    apk add --no-cache build-base && \
    apk add --no-cache cargo && \
    apk add --no-cache bash && \
    apk add --no-cache expat-dev && \
    apk add --no-cache zlib-dev && \
    apk add --no-cache libexpat && \
    apk add --no-cache cmake && \
    apk add --no-cache yaml-dev && \
    apk add --no-cache automake && \
    apk add --no-cache autoconf && \
    apk add --no-cache erlang-dev
# And build the release

ENV BUILD_WITHOUT_QUIC=true


RUN rebar3 get-deps
# Run configure script in ejabberd deps directory
RUN ls _build/default/lib/ejabberd
RUN cd _build/default/lib/ejabberd && ./autogen.sh && ./configure && cd -
RUN rebar3 compile
RUN rebar3 release

# Build stage 1
#FROM erlang:alpine 

# Install the released application
WORKDIR /buildroot
RUN ls
#COPY /buildroot/_build/default/rel/plpod .
#COPY /buildroot/config /plpod/config
# Expose relevant ports
EXPOSE 10300
 #EXPOSE 8443
CMD ["sh", "./priv/scripts/run.sh", "foreground"]