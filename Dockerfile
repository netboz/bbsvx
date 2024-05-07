# Build stage
FROM erlang:26.2-alpine AS build

# Build the image used to buimd the release
RUN apk update && apk add --no-cache \
    openssl-dev \
    ncurses-libs \
    libstdc++ \
    git \
    build-base \
    bash \
    expat-dev \
    zlib-dev \
    libexpat \
    bsd-compat-headers \
    linux-headers \
    yaml-dev \
    erlang-dev
WORKDIR /buildroot
RUN mkdir src include config priv log

COPY rebar.config ./rebar.config
COPY rebar.lock ./rebar.lock
ENV BUILD_WITHOUT_QUIC=true
RUN rebar3 compile

## Copy needed files and build the release
FROM build as builded
# Set working directory
WORKDIR /buildroot
COPY src ./src
COPY include ./include
COPY config ./config
COPY priv ./priv
COPY ./priv/scripts/run.sh ./run.sh

# Build the release
ENV BUILD_WITHOUT_QUIC=true

RUN rebar3 compile && \
    rebar3 release
## Build the runtime image
FROM erlang:26.2-alpine AS run
RUN apk update && apk add --no-cache \
    openssl-dev \
    ncurses-libs \
    expat-dev \
    libstdc++ \
    bash \
    zlib-dev \
    libexpat \
    yaml-dev \
    erlang-dev

## Copy the release from the build stage to the runtime image
FROM run

# Copy only the necessary files from the build stage

COPY --from=builded /buildroot/_build/default/rel/bbsvx /bbsvx
COPY --from=builded /buildroot/config /bbsvx/config
COPY --from=builded /buildroot/priv /bbsvx/priv
COPY --from=builded /buildroot/run.sh /bbsvx/run.sh

# Expose relevant ports
EXPOSE 10300
#EXPOSE 8443

# Run the application
CMD ["sh", "/bbsvx/run.sh", "foreground"]
