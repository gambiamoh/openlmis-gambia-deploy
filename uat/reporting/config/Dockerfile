FROM alpine:3.11

COPY ./services /config

RUN apk update && apk upgrade && \
    apk add curl && \
    apk add bash && \
    apk add bash-completion && \
    rm -rf /var/cache/apk/*

ENTRYPOINT [""]
CMD /bin/true
