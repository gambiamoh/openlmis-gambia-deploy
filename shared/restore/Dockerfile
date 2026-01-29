FROM alpine:3.20

RUN mkdir -p /restore

COPY after_restore.sh /after_restore_template.sh
RUN chmod +x /after_restore_template.sh

CMD cp /after_restore_template.sh /restore/after_restore.sh && echo "Sync Complete"