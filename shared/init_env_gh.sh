#!/usr/bin/env sh

# copy the credentials folder from gitlab variable
mkdir -p credentials

cat $ca > credentials/ca.pem
cat $cert > credentials/cert.pem
cat $key > credentials/key.pem
cat $settings > settings.env
