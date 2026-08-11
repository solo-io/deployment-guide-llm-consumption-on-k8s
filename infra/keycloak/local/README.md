# Local identity provider for a lab or PoC

> [!WARNING]
> Lab and PoC only. The realm ships with `admin`/`admin`, a known client
> secret, and no TLS. Do not run this anywhere reachable, and do not use it
> as a starting point for production.

Run from the repository root — the mount path is relative to it.

```sh
docker run -d --restart=always --name keycloak \
  --network kind \
  -p 127.0.0.1:8080:8080 \
  -e KEYCLOAK_ADMIN=admin \
  -e KEYCLOAK_ADMIN_PASSWORD=admin \
  -e KC_HOSTNAME=http://keycloak:8080 \
  -e KC_HTTP_ENABLED=true \
  -e KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true \
  -e KC_HOSTNAME_STRICT=false \
  --mount type=bind,source="$(pwd)/infra/keycloak/local/realm.json",target=/opt/keycloak/data/import/realm.json,readonly \
  quay.io/keycloak/keycloak:26.1.3 \
  start-dev --import-realm
```

Full setup, including the issuer resolution problem, is in
[Attachment A](../../../docs/attachments.md).