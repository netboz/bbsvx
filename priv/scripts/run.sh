#!/bin/sh

export APP=bbsvx

# If we're running in Docker compose...
if [ ! -z "$DOCKER_COMPOSE" ]; then
  export IP=$(awk 'END{print $1}' /etc/hosts)
  export NODE_NAME=bbsvx@${IP}
  export OTP_IP={`echo $IP | tr . ,`}
fi

# Assume 127.0.0.1 as bind host.
if [ -z "$IP" ]; then
  echo "IP address not set; defaulting to 127.0.0.1."
  export IP=127.0.0.1
fi

if [ -z "$NODE_NAME" ]; then
  export NODE_NAME=${APP}@${IP}
fi

export COOKIE=${APP}

export RELX_REPLACE_OS_VARS=true

echo "PEER_PORT: ${PEER_PORT}"
echo "WEB_PORT: ${WEB_PORT}"
echo "NODE_NAME: ${NODE_NAME}"
echo "COOKIE: ${COOKIE}"
echo "IP: ${IP}"
echo "OTP_IP: ${OTP_IP}"
echo "HOSTNAME: ${HOSTNAME}"

#echo "Printing the environment:"
#env

RELNAME="`dirname \"$0\"`"/${APP}
echo "Starting ${RELNAME}..."
exec /bbsvx/bin/bbsvx foreground "$@"
