FROM alpine:3.18

COPY ./services /config
COPY ./init.sh /init.sh

RUN apk add --no-cache curl

CMD /bin/true
