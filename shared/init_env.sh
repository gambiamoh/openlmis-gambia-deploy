#!/usr/bin/env bash

cp -r $credentials ./credentials
cp ./credentials/.env ./.env
# Jenkins will inject an env var called "credentials"
# which points to a randomly generated path that contains the keys