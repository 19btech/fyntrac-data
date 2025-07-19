#!/bin/bash

CSRF_TOKEN=$(curl http://localhost:7750/pulsar-manager/csrf-token)

curl -X PUT http://localhost:7750/pulsar-manager/users/superuser \
  -H "X-XSRF-TOKEN: $CSRF_TOKEN" \
  -H "Cookie: XSRF-TOKEN=$CSRF_TOKEN;" \
  -H "Content-Type: application/json" \
  -d '{
        "name": "admin",
        "password": "R3s3rv#313",
        "description": "Dev",
        "email": "uabbas@19btech.com"
      }'