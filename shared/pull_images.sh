#!/usr/bin/env bash
 export spring_profiles_active="production"

docker-compose pull log
docker-compose pull db
docker-compose pull nginx
docker-compose pull consul

# $1 is the parameter passed in
docker-compose pull $1
