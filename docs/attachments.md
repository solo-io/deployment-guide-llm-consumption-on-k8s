## Attachment A: Keycloak for a lab or PoC

> [!WARNING]
> Lab and PoC only. Nothing in this attachment is safe for production, and the reasons are listed at the end so you can see exactly why.

### A.0 The one thing that matters

Read this before running anything, because every failure in this attachment is a violation of one sentence.

> [!WARNING]
> Keycloak must be reachable at **one URL** that resolves identically from your laptop and from inside the cluster, and the `iss` claim in your tokens must match that URL exactly.

Here is why. The gateway does two things with your IdP. It fetches signing keys from the JWKS endpoint, which happens **from inside the proxy pod**. And it compares the `iss` claim in each token against the `issuer` in your policy, which is a string comparison with no normalization. If you obtain a token through `localhost` on your laptop and configure the gateway with a cluster DNS name, the JWKS fetch works, the signature verifies, and the request is still rejected because two strings do not match.

The symptom is HTTP 401 while holding a token that decodes perfectly. It is the single most common way people fail this guide, and it looks like a gateway problem.

### A.1 Recommended: Keycloak outside the cluster

Run Keycloak as a container alongside the cluster rather than inside it. Two reasons, and the second is the better one.

The practical reason is that it removes a whole class of problems and survives cluster rebuilds, which matters when you are testing and will nuke the cluster several times.

The better reason is that it models production. Nobody runs their identity provider inside the same cluster as their AI gateway. An in-cluster IdP teaches a shape you would have to unlearn, and it quietly implies your IdP shares a blast radius with your data plane. Outside is both easier and more honest.

**Get the realm definition.** Clone the reference repo, which you want anyway for the tested manifests:

```bash run id=a-1-recommended-keycloak-outside
git clone https://github.com/solo-io/deployment-guide-llm-consumption-on-k8s.git
cd deployment-guide-llm-consumption-on-k8s
```

Two paths matter for this attachment:

| Path | Used by |
|---|---|
| `infra/keycloak/local/realm.json` | The container path in A.1, mounted into Keycloak |
| `infra/keycloak/k8s/keycloak.yaml` | The in-cluster path in A.3 |

**Check the realm file exists and is a file.** Do not skip this. It takes one second and it prevents the failure described in A.1a.

```bash run id=a-1-recommended-keycloak-outside-2
REALM="$(pwd)/infra/keycloak/local/realm.json"
[ -f "${REALM}" ] || { echo "NOT A FILE: ${REALM}"; ls -ld "${REALM}" 2>/dev/null; }
```

If that prints anything, stop and read A.1a before running Docker.

**Start Keycloak on the cluster's Docker network:**

```bash run id=a-1-recommended-keycloak-outside-3
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

`KC_HOSTNAME` **is the line that matters most,** and not only because Keycloak refuses to start without it when `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` is true (see A.1a). Pinning the hostname makes the token issuer deterministic instead of derived from whichever Host header a caller happened to use, which is what removes the largest source of failure in this attachment. A.2 covers the consequence.

`--network kind` is the part that makes this work. The container joins the same Docker bridge network as the kind nodes, so pods can reach it at `http://keycloak:8080` by container name, while your laptop reaches it at `127.0.0.1:8080`.

Four things about that command:

- `--network kind` **does not exist until a kind cluster does.** Docker creates that network with your first cluster. If you run this on a clean machine before creating a cluster you get `network kind not found`. Create the cluster first, or run `docker network create kind` defensively.
- **Use** `--mount`**, not** `-v`**, and note the different syntax.** `--mount type=bind` fails with an error if the source path does not exist. `-v` silently creates a directory there instead, which is the failure in A.1a. Behavior is identical when the path is correct; the difference only shows up when you are already in trouble.
- **The source path must be absolute.** `$(pwd)` expands to wherever your shell is, not the repo root, so run this from the top of the clone.
- **Not all clusters are kind.** For k3d, minikube, or a managed cluster, the network flag changes but A.0 does not. Whatever you do, produce one URL that resolves from both sides.
- `-v` **takes a file path, not a URL.** There is no import-from-URL option. If you would rather not clone the repo, `curl` the file down first and mount the local copy.
- `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` **requires** `KC_HOSTNAME`**.** Keycloak 26 validates the pairing at startup and refuses to boot without it. Keycloak 24 ignored the option entirely, so a command carried over from 24.x starts there and crashloops on 26. See A.1a.
- **Hostname options were reworked in Keycloak 25.** Anything carried over from a 24.x setup needs verifying against the version you are pinning rather than assumed to still be valid.
> [!WARNING]
> **On the admin variables.** The command above uses `KEYCLOAK_ADMIN` and `KEYCLOAK_ADMIN_PASSWORD` because that is what was tested and it works on 26.1.3. Keycloak 26 introduced `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD` as the current names, with the old pair deprecated but functional. Switching is the right move eventually. Verify it before you rely on it, because getting it wrong gives you a Keycloak with no admin user.

### A.1a If Keycloak crashloops

Two causes, both encountered while building this guide. Get the error message before doing anything else, and run it in the foreground so the failure prints in front of you:

```bash
docker rm -f keycloak
# same command as A.1, but with --rm instead of -d --restart=always
```

#### Cause 1: an invalid hostname option combination

```text
ERROR: Failed to start quarkus
ERROR: hostname-backchannel-dynamic must be set to false when no hostname is provided
```

Keycloak 26 validates option combinations at startup and exits. `hostname-backchannel-dynamic` is only valid when a hostname is provided, so it needs `KC_HOSTNAME` alongside it.

**Why this looks like a version problem, and why downgrading is the wrong fix.** Keycloak 24 ignored the option and started fine, so an otherwise identical command works on 24 and crashloops on 26. That makes the version look guilty when the real issue is a configuration pairing that only 26 validates. Set `KC_HOSTNAME` as shown in A.1 rather than downgrading, because pinning the hostname is the better configuration anyway.

The startup logs are unambiguous about this class of failure. If Keycloak dies in under a second with `ERROR: Failed to start quarkus`, it is a configuration validation error and the line underneath names the option.

#### Cause 2: a bind mount pointed at a directory

**Symptom.** Keycloak starts and exits repeatedly, with no realm imported, and downgrading appears to help.

**Cause.** With a `-v` bind mount, if the host source path does not exist, the Docker daemon **creates it, as a directory**, because it cannot know whether you meant a file. So if you ran `docker run` before the realm file was in place, or from a working directory where `$(pwd)` did not resolve to the repo root, Docker created a directory named `realm.json`. Keycloak then mounts a directory where it expects a file, finds nothing importable, and exits.

This is documented Docker behavior rather than a bug, which is why the command in A.1 uses `--mount` instead. `--mount` refuses to create a missing source path. Note that it will still happily bind a path of the wrong type, so a directory left behind by an earlier `-v` run continues to break things.

**Confirm it.** Run all three, because they catch different mistakes:

```text
# Is it a directory? A leading d in the permissions means yes. Use -ld, not -la:
# on a directory, ls -la lists the contents rather than the entry itself.
ls -ld ./infra/keycloak/local/realm.json

# Is the name what you think? -b escapes non-printing characters,
# which catches a stray carriage return from a copied command or an editor.
ls -lab ./infra/keycloak/local/

# What did Docker actually mount? Brackets expose trailing whitespace.
docker inspect keycloak --format '{{range .Mounts}}[{{.Source}}] type={{.Type}}{{"\n"}}{{end}}'
```

If the mount source is not the path you expected, you ran the command from the wrong working directory. That is the underlying mistake, and it is why the directory reappears after you delete it.

**Fix it:**

```bash
docker rm -f keycloak
sudo rm -rf ./infra/keycloak/local/realm.json   # daemon-created, so likely root-owned
git checkout -- infra/keycloak/local/realm.json # or restore the file however you created it
file ./infra/keycloak/local/realm.json          # must say JSON text, not directory
```

Then re-run the A.1 command **from the root of the clone**.

> [!WARNING]
> Docker created that directory as root, so a plain `rm -rf` may be denied. That is a useful confirming signal rather than a separate problem. And if an editor shows the path as a file while the terminal disagrees, trust `ls -ld`.

### A.2 Making the issuer match

The constraint from A.0 is that the `iss` claim in your tokens must exactly match the `issuer` configured in the gateway policy. There are two ways to satisfy it, and the command in A.1 takes the better one.

**With** `KC_HOSTNAME` **pinned,** Keycloak builds the issuer from that value rather than deriving it from the request Host header. So every token carries `iss: http://keycloak:8080/realms/llm-platform` regardless of which address you fetched it from, and the gateway policy is configured with that same string. The proxy pod resolves `keycloak` through Docker's network DNS, so JWKS retrieval works from inside the cluster.

```bash run id=a-2-making-the-issuer-match-env
export KEYCLOAK_URL=http://keycloak:8080
export KEYCLOAK_REALM=llm-platform
```

> [!WARNING]
> **NEEDS VALIDATION.** Confirm two things, because together they decide whether the hosts entry below is required at all. First, that a token fetched from your laptop at `http://localhost:8080` comes back with `iss` set to `http://keycloak:8080/realms/llm-platform`. Second, that the admin console is still usable through `localhost:8080` with the hostname pinned. If the issuer is genuinely fixed, fetching tokens at `localhost` is fine, the hosts entry becomes optional, and this section gets shorter.

**The hosts entry,** which you want anyway and which is mandatory if you did not pin the hostname:

```text
# /etc/hosts
127.0.0.1 keycloak
```

With that in place you can use `http://keycloak:8080` consistently everywhere: in `KEYCLOAK_URL`, in the gateway policy, and when fetching tokens from your laptop. One name, resolving to the port-published container from your machine and through Docker's network DNS from inside the cluster. It also puts the admin console at the same address your tokens name, which is one less thing to hold in your head while debugging.

Verify from your laptop:

```bash run id=a-2-making-the-issuer-match-curl
curl -s ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs | jq '.keys | length'
```

And from inside the cluster, which is the check that actually matters, because this is the request the proxy makes:

```bash run id=a-2-making-the-issuer-match
kubectl run -n agentgateway-system --rm -i --restart=Never jwks-check \
  --image=curlimages/curl:latest -- \
  curl -s ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs
```

If the second one fails, the gateway cannot validate tokens no matter what else is correct. Fix it here rather than in Step 6.

**If you do not pin** `KC_HOSTNAME`**,** the issuer is derived from the Host header of whichever request produced the token. The hosts entry then stops being a convenience and becomes mandatory, because you have to fetch tokens using the same name the gateway is configured with or `iss` will not match. This is the configuration most people arrive at by accident, and it is the cause of the 401-with-a-valid-token failure in A.6.

### A.3 If you must run Keycloak in the cluster

Sometimes outside is not practical. If you are developing against EKS or another managed cluster and standing up a host for Keycloak means a ticket, a VPC decision, and three days, that is a bad trade for a lab. Running it in the cluster is a legitimate choice, and the repo has a manifest for it:

```bash
kubectl apply -f infra/keycloak/k8s/keycloak.yaml
```

It defines the same realm, the same client and mappers, and the same three users as the container path, so everything in A.4 applies unchanged.

The same principle from A.0 applies and the same fix works. Because you will reach Keycloak through a port-forward, add a hosts entry for the in-cluster service name:

```text
# /etc/hosts
127.0.0.1 keycloak.keycloak.svc.cluster.local
```

```bash
kubectl port-forward svc/keycloak -n keycloak 8080:8080 &
export KEYCLOAK_URL=http://keycloak.keycloak.svc.cluster.local:8080
```

**The ports have to match on both sides.** The proxy pod reaches Keycloak on the Service port, and your token request carries whatever port is in the URL you used. If you port-forward `8081:8080`, your tokens carry `iss` with `:8081` and the gateway is configured with `:8080`, and you are back to a 401 with a valid token.

> [!WARNING]
> **NEEDS VALIDATION.** Confirm on a clean cluster: the manifest needs a `Namespace` resource added (nothing currently creates `namespace: keycloak`, so `kubectl apply` fails), `KC_PROXY: edge` is deprecated in Keycloak 26 and should be removed, and confirm whether `KC_HOSTNAME_STRICT` and `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` need setting explicitly or whether the `start-dev` defaults are sufficient.

### A.4 What the realm gives you

You do not need to read this to continue, but you do need to read it to adapt it. Every block in `realm.json` exists for a reason the gateway cares about.

**Realm** `llm-platform`**.** Keycloak also creates a `master` realm on startup for its own administration. agentgateway never uses it, and everything in this guide uses `llm-platform`.

**Access token lifespan.** Keycloak's default is **five minutes**, which is correct for production and painful for a walkthrough: you export a token, work through several steps, and start getting 401s that look like a policy fault. The realm sets a longer lifespan for lab use:

```text
"accessTokenLifespan": 3600
```

An hour is enough to get through a section including a detour or two. Thirty minutes sounds like plenty and is not: any troubleshooting at all will outlast it, and an expired token in the middle of a step you are debugging is a false trail you do not need. **Lab only.** Do not carry this into a real realm, and if you are adapting your own existing realm, leave its lifespan alone and use the `get_token` helper in A.5 instead.

**Client** `agentgateway-client`**,** confidential, with a fixed secret. Three settings matter:

| Setting | Why |
|---|---|
| `serviceAccountsEnabled: true` | Allows client-credentials tokens for machine callers |
| `directAccessGrantsEnabled: true` | Allows password-grant tokens for the test users, which is how you get a token with real group membership. Without this you can only get a service account token, and the service account belongs to no group, so authorization in Step 7 would deny everything. |
| `standardFlowEnabled: false` | No browser redirect flow, because nothing here needs one. This is also why you do not hit redirect problems. |

**The audience mapper,** emitting `agentgateway`. The gateway requires `aud` to include this value and **Keycloak does not add custom audiences by default**. If you are adapting an existing realm, this is the setting people miss.

**The groups mapper,** with `full.path: "false"`. That produces `developers` rather than `/developers`. With the leading slash, a policy matching `developers` matches nothing, the request is denied, and there is no obvious reason why. If you are adapting an existing realm, check this one second.

**The roles mapper,** emitting realm roles into a `roles` claim. Used for tiering in Step 7 and for budget exemptions in Step 14.

**A singular** `group` **claim, which the cost dashboard needs.** This is the non-obvious one. The `groups` mapper above emits an array, which is what RBAC in Step 7 matches against and what every mainstream IdP produces. But the gateway's default budget dimension for group is `coalesce(jwt.group, apiKey.group)`, **singular**, so an array claim resolves to nothing and the cost dashboard shows no groups at all.

The contained fix is to emit both. Give each user an attribute:

```text
"attributes": { "group": ["developers"] },
```

and add a mapper that projects it as a scalar claim:

```json
{
    "name": "group-single-mapper",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-attribute-mapper",
    "config": {
        "user.attribute": "group",
        "claim.name": "group",
        "jsonType.label": "String",
        "multivalued": "false",
        "access.token.claim": "true",
        "id.token.claim": "false"
    }
}
```

Your tokens then carry `groups: ["developers"]` for authorization and `group: "developers"` for cost attribution, and neither the gateway's shared dimension ConfigMap nor your RBAC policy needs changing.

**Verified on 2026.7.1.** This produces a scalar `group` claim, and the group breakdown then populates in the Step 12 cost dashboard with no change to the gateway's shared dimension ConfigMap.

**A note on modelling.** A single-valued `group` attribute means one group per user for cost purposes, which is usually what you want for chargeback: spend has to land in exactly one bucket. Multi-group membership stays available through `groups` for authorization decisions, where overlapping membership is normal and useful. Worth being deliberate about, because those two requirements genuinely differ.

**Groups and users:**

| User | Password | Email | Group | Role |
|---|---|---|---|---|
| `dev-admin` | `dev-admin-password` | `dev-admin@example.com` | `developers` | `llm-admin` |
| `dev` | `dev-password` | `dev@example.com` | `developers` | `llm-user` |
| `agent` | `agent-password` | `agent@example.com` | `agents` | `llm-user` |

Passwords follow `<username>-password` throughout, which is what makes the `get_token` helper in A.5 work for any user without special cases.

**Each user needs** `firstName`**,** `lastName`**,** `email`**,** `emailVerified: true`**, and an empty** `requiredActions`**.** Newer Keycloak enables the declarative user profile by default, and the default profile marks those name and email fields as required. A user imported without them is incomplete, so a password grant fails with `invalid_grant` / `Account is not fully set up`. Keycloak 24 did not enforce this, so a realm carried over from 24.x needs the fields added.

The empty `requiredActions` and `emailVerified: true` matter as much as the fields, because a pending verify-email or update-profile action produces the same error.

**The emails are not decoration.** Step 10.2 attributes metrics using a CEL expression, and a real email means you can use `jwt.email` or `jwt.preferred_username` there instead of `jwt.sub`. The difference on the cost dashboard is `dev@example.com` versus `f47ac10b-58cc-4372-a567-0e02b2c3d479`, which matters when the audience for that dashboard is a budget holder rather than an engineer.

Two groups rather than one is deliberate. `dev` proves authorization allows the right caller, `agent` proves it denies the wrong one, and a policy you have only tested in the passing direction is not tested. Splitting human callers from agent callers is also worth doing on its own merits, because the two end up wanting different access and different budgets.

> [!WARNING]
> **On group names in the import.** Plain names work: `"groups": ["developers"]` populates the claim as `["developers"]`, verified on Keycloak 26.1.3. You do not need a leading slash in the user entries, and `full.path: "false"` on the mapper is what keeps the slash out of the claim itself.

**Editing the realm:** `--import-realm` does not overwrite a realm that already exists. If you change `realm.json` and restart, nothing happens. Remove and recreate the container to pick up changes:

```bash run id=a-4-what-the-realm-gives-you
docker rm -f keycloak
# then re-run the docker run command from A.1
```

### A.5 Get your tokens

```bash run id=a-5-get-your-tokens-env
export ALLOWED_TOKEN=$(curl -s \
  -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=agentgateway-client" \
  -d "client_secret=agentgateway-client-secret" \
  -d "username=dev" -d "password=dev-password" \
  | jq -r '.access_token')

export DENIED_TOKEN=$(curl -s \
  -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=agentgateway-client" \
  -d "client_secret=agentgateway-client-secret" \
  -d "username=agent" -d "password=agent-password" \
  | jq -r '.access_token')

decode_jwt() {
  if [ -z "${1}" ]; then
    echo "decode_jwt: empty token. Did the fetch actually succeed?" >&2
    return 1
  fi
  echo "${1}" | cut -d. -f2 | tr '_-' '/+' \
    | awk '{n=length($0)%4; printf "%s%s", $0, (n ? substr("===",1,4-n) : "")}' \
    | base64 -d | jq .
}

decode_jwt "${ALLOWED_TOKEN}"   | jq '{iss, aud, sub, groups, roles, preferred_username}'
decode_jwt "${DENIED_TOKEN}" | jq '{iss, aud, sub, groups, roles, preferred_username}'
```

> [!WARNING]
> **Why not just** `base64 -d`**.** JWTs use base64url without padding, so a payload whose length is not a multiple of four fails to decode. `base64` decodes as much as it can and then errors, leaving you with truncated JSON and a confusing `jq: parse error: Unfinished string at EOF`. base64url also uses `-` and `_` where base64 expects `+` and `/`. The helper above adds the padding and translates the characters, and it works with both BSD and GNU `base64`.

Worth knowing that the two behave differently when the padding is missing. GNU `base64` errors with `invalid input`. BSD `base64`, which is what you have on macOS, **silently drops the incomplete final group**, so you get output that looks complete but is missing its last one or two characters. On a token payload that usually means the closing `"}`, which is enough to read the claims by eye and enough to break any `jq` filter. Do not add `2>/dev/null` either: on GNU that hides the only message that explains the failure.

If either token comes back `null`, drop the `jq -r '.access_token'` filter and read the error object. Keycloak names the problem precisely, and the A.6 table maps the common ones to fixes. `.well-known/openid-configuration` is also worth a look, since it confirms the realm imported and shows you the issuer Keycloak is actually advertising:

```bash run id=a-5-get-your-tokens-curl
curl -s ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration | jq '{issuer, grant_types_supported}'
```

Confirm before you leave this attachment:

- `iss` is exactly `${KEYCLOAK_URL}/realms/llm-platform`
- `aud` includes `agentgateway`. Note this is a **string** when there is one audience and an array when there are several. Both are valid, so do not go looking for a problem if you see a bare string.
- `ALLOWED_TOKEN` has `groups: ["developers"]`, `DENIED_TOKEN` has `groups: ["agents"]`, with **no leading slash**
- `roles` is populated
- `preferred_username` is present. This is the most readable value available for cost attribution in Step 10.2, better than `sub`, which is a UUID.
**Keep this handy, because tokens expire.** Even with the extended lab lifespan you will need to re-fetch at some point, and doing it by hand means finding the command again:

```bash run id=a-5-get-your-tokens
get_token() {
  local user="${1:?usage: get_token <username> [password]}"
  local pass="${2:-${user}-password}"
  : "${KEYCLOAK_URL:?not set. See Environment setup.}"
  : "${KEYCLOAK_REALM:?not set. See Environment setup.}"
  : "${KEYCLOAK_CLIENT_ID:?not set. See Environment setup.}"
  : "${KEYCLOAK_CLIENT_SECRET:?not set. See Environment setup.}"
  curl -s -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=${KEYCLOAK_CLIENT_ID}" \
    -d "client_secret=${KEYCLOAK_CLIENT_SECRET}" \
    -d "username=${user}" \
    -d "password=${pass}" \
    | jq -r '.access_token'
}

export ALLOWED_TOKEN=$(get_token dev)
export DENIED_TOKEN=$(get_token agent)
```

The password defaults to `<username>-password`, which is this realm's convention, and takes an explicit second argument for anything else: `get_token alice 's3cret'`. The client ID and secret come from `KEYCLOAK_CLIENT_ID` and `KEYCLOAK_CLIENT_SECRET` in Environment setup, so the helper works against any Keycloak realm rather than only this one.

**Confirm the lifespan actually took effect,** because it will not have if the container was restarted rather than removed:

```text
decode_jwt "${ALLOWED_TOKEN}" | jq '.exp - .iat'
```

`3600` means the realm change is live. `300` means you are still on Keycloak's default, so remove the container and recreate it: `--import-realm` skips a realm that already exists, so restarting changes nothing.

> [!WARNING]
> **An empty variable decodes to nothing at all.** If `decode_jwt` prints no output, the token variable is empty, which means the fetch failed rather than the decode. The helper above returns an error in that case rather than staying silent, because a blank response is easy to read as success when you are working through several of these.
>
> **If requests start returning 401 after working fine,** your token has expired. It is the most likely cause of a 401 in the middle of a section, and it is easy to mistake for a policy problem because you will have been deliberately testing 401s a few steps earlier. Re-run `get_token` before you debug anything else.

### A.6 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 401 with a token that decodes fine | `iss` does not match the policy `issuer` | Decode the token, compare the two strings character by character including the port. See A.0 and A.2. |
| JWKS check fails from inside the cluster | The URL is not resolvable from the pod | A.2. Test with the in-cluster curl, not from your laptop. |
| `network kind not found` | No kind cluster yet | Create the cluster, or `docker network create kind` |
| Crashloop, `hostname-backchannel-dynamic must be set to false when no hostname is provided` | `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` set without `KC_HOSTNAME`. Keycloak 26 validates the pairing, 24 ignored it. | Set `KC_HOSTNAME`. A.1a cause 1. Do not downgrade. |
| Crashloop that works on Keycloak 24 and fails on 26 | Almost always a configuration pairing only 26 validates, not a version incompatibility | Run in the foreground and read the error. A.1a. |
| Crashloop with no realm imported | `-v` created a **directory** at the realm.json path because the file did not exist when first run | A.1a cause 2. Remove the directory, restore the file, use `--mount`. |
| The directory keeps coming back after you delete it | You are running from a working directory where `$(pwd)` does not resolve to the repo root, so Docker creates the path again | `docker inspect` the mount source and compare to `pwd`. Run from the root of the clone. |
| Cannot delete the directory without sudo | Docker's daemon created it as root | Expected. Confirms the diagnosis. |
| Keycloak starts with no realm | Same cause as above, or a relative volume path treated as a named volume | `ls -ld` the path, then A.1a |
| Editor shows a file, terminal shows a directory | Cached editor view over a Docker-created directory | Trust `ls -ld`. Create the file from a terminal. |
| Realm changes have no effect | `--import-realm` does not overwrite | `docker rm -f keycloak` and recreate |
| `invalid_grant`, `Account is not fully set up` | User is missing `firstName`, `lastName`, `email`, or has a pending required action. Newer Keycloak requires them by default. | Add the profile fields and `emailVerified: true` with empty `requiredActions`, then recreate the container |
| `unauthorized_client` or `invalid_client` | The client secret did not survive the import | `kcadm.sh get clients -r llm-platform --fields clientId,secret` |
| `unsupported_grant_type` | `directAccessGrantsEnabled` is not actually on | Check the imported client rather than the JSON |
| `Realm does not exist` | Import was skipped because a partial realm persisted in the container's store | `docker rm -f keycloak` and recreate. Restarting is not enough. |
| `decode_jwt` prints nothing | The token variable is empty. The fetch failed, not the decode. | Re-run `get_token` and check the response for an error object |
| `get_token dev-admin` fails | Password convention mismatch if the realm still has `admin-password` | Realm passwords are `<username>-password`. Update `realm.json`. |
| `jq: parse error: Unfinished string at EOF` when decoding a token | `base64 -d` cannot handle unpadded base64url. The token is fine. | Use the `decode_jwt` helper in A.5 |
| A decoded token looks complete but ends mid-value, with no error | BSD `base64` on macOS silently drops the incomplete final group | Same fix. The claims are readable but the JSON is invalid, so anything piping to `jq` fails. |
| 401 with `Error(ExpiredSignature)` in the message | Access token expired. Default lifespan is five minutes. | Re-run `get_token`. The gateway names this specifically, so no diagnosis is needed. |
| `exp - iat` still reports 300 after adding `accessTokenLifespan` | `--import-realm` skips a realm that already exists, so a restart changes nothing | `docker rm -f keycloak` and recreate. Restarting is not enough. |
| Authorization denies a caller who should pass | `groups` claim missing, or has a leading slash | Check the groups mapper and `full.path` |
| Everything worked yesterday, cluster was rebuilt | Nothing, that is the point of running Keycloak outside | Confirm the container is still up: `docker ps` |

### A.7 Why this is lab-only

Not a disclaimer, a list, so you can see what would need to change:

- `admin`/`admin` credentials, and user passwords in a file
- No TLS anywhere, `KC_HTTP_ENABLED=true`
- The hostname is pinned to a plain HTTP address on a Docker bridge network, with `KC_HOSTNAME_STRICT=false`. Production pins a real hostname over TLS.
- `start-dev` uses an in-memory-class local store. It survives container restarts and cluster rebuilds, but not `docker rm`.
- `--restart=always` means this comes back after a reboot and sits there indefinitely with weak credentials. Remove it when you are done.
> [!WARNING]
> ↩ **Return to Step 6.1.** Your IdP is ready and your tokens are in `ALLOWED_TOKEN` and `DENIED_TOKEN`.

## Attachment B: Using your own IdP

This attachment is for a realm or tenant you already have. It is not setup instructions, it is the list of things to change and the configuration delta for the gateway policy in Step 6.3.

Each of the three below needs two resources: a backend that resolves the IdP host, and a policy that points at it. The gateway reaches JWKS through a backend reference rather than a URL, so a public IdP needs a `static` backend with `host` and `port` — which is also why `jwks.remote.url` does not exist as a field.

> [!NOTE]
> **The policy shape below is the one running in Step 13.3.** Only the issuer, the JWKS path, the audience and the backend name differ between vendors. Targeting the Gateway rather than a route gives every route coverage by default, including routes added later.

### B.1 Okta

Take your Okta domain and Authorization Server ID from the admin console. The default authorization server uses `default` as its ID.

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: okta
  namespace: agentgateway-system
spec:
  static:
    host: dev-12345678.okta.com
    port: 443
  policies:
    tls:
      sni: dev-12345678.okta.com
EOF
```

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: llm-gateway-jwt-okta
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  traffic:
    jwtAuthentication:
      mode: Strict
      location:
        header:
          name: Authorization
          prefix: "Bearer "
      providers:
        - audiences:
            - agentgateway
          issuer: https://dev-12345678.okta.com/oauth2/default
          jwks:
            remote:
              backendRef:
                group: enterpriseagentgateway.solo.io
                kind: EnterpriseAgentgatewayBackend
                name: okta
              cacheDuration: 5m
              jwksPath: /oauth2/default/v1/keys
EOF
```

**Okta specifics.** Set the `agentgateway` audience in the Authorization Server’s Audience field, or tokens arrive without it and every request returns 401 with a token that looks valid. Add a Groups claim to the authorization server for group attribution — it is not present by default. Okta emits `sub` as an opaque ID, so put `email` ahead of it in the user dimension if you want readable names on the dashboard.

**↩ Return to Step 6.4** and verify a token is accepted.

### B.2 Microsoft Entra ID

Take the Tenant ID and Application (client) ID from the Azure portal.

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: entra-id
  namespace: agentgateway-system
spec:
  static:
    host: login.microsoftonline.com
    port: 443
  policies:
    tls:
      sni: login.microsoftonline.com
EOF
```

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: llm-gateway-jwt-entra
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  traffic:
    jwtAuthentication:
      mode: Strict
      location:
        header:
          name: Authorization
          prefix: "Bearer "
      providers:
        - audiences:
            - <application-client-id>
          issuer: https://login.microsoftonline.com/<tenant-id>/v2.0
          jwks:
            remote:
              backendRef:
                group: enterpriseagentgateway.solo.io
                kind: EnterpriseAgentgatewayBackend
                name: entra-id
              cacheDuration: 5m
              jwksPath: /<tenant-id>/discovery/v2.0/keys
EOF
```

> [!WARNING]
> The audience is your Application ID, not `agentgateway`**.** Entra ID uses the client ID as the audience and will not emit a custom one, so this is the one vendor where the audience differs from every example in the main guide. Configuring `agentgateway` here produces a 401 on every request.

**Entra specifics.** Add a groups claim through App Registration > Token configuration. Large group memberships emit Object IDs rather than display names, and above the claim limit Entra omits groups entirely and sets a `_claim_names` overage pointer instead — group attribution silently stops working for exactly the users who belong to the most groups. Use `oid` as the stable user identifier; `sub` is per-application.

**↩ Return to Step 6.4** and verify a token is accepted.

### B.3 Auth0

Take your tenant domain and the API identifier from the Auth0 dashboard.

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: auth0
  namespace: agentgateway-system
spec:
  static:
    host: your-tenant.auth0.com
    port: 443
  policies:
    tls:
      sni: your-tenant.auth0.com
EOF
```

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: llm-gateway-jwt-auth0
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  traffic:
    jwtAuthentication:
      mode: Strict
      location:
        header:
          name: Authorization
          prefix: "Bearer "
      providers:
        - audiences:
            - https://agentgateway.your-org.com
          issuer: https://your-tenant.auth0.com/
          jwks:
            remote:
              backendRef:
                group: enterpriseagentgateway.solo.io
                kind: EnterpriseAgentgatewayBackend
                name: auth0
              cacheDuration: 5m
              jwksPath: /.well-known/jwks.json
EOF
```

> [!WARNING]
> **The trailing slash on the issuer is required.** Auth0 emits `iss` with it, the gateway compares the string exactly, and omitting it fails every token with no indication that a single character is the cause.

**Auth0 specifics.** The audience is the API identifier from your Auth0 API settings, not the client ID. Auth0 does not include group or role claims in access tokens at all — you add them with an Action or Rule, and a custom claim must be namespaced as a URI, so your dimension expression reads something like `jwt["https://your-org.com/groups"]` rather than `jwt.groups`.

**↩ Return to Step 6.4** and verify a token is accepted.

### B.4 Verifying any of them

Decode a token before debugging a policy. Three of the four failure modes are visible in the token itself:

```bash
echo "${ALLOWED_TOKEN}" | cut -d. -f2 | python3 -c "
import sys, base64, json
s = sys.stdin.read().strip(); s += '=' * (-len(s) % 4)
d = json.loads(base64.urlsafe_b64decode(s))
print('iss   :', d.get('iss'))
print('aud   :', d.get('aud'))
print('sub   :', d.get('sub'))
print('groups:', d.get('groups') or d.get('group'))
"
```

`iss` must match your policy issuer character for character, including any trailing slash. `aud` must contain what the policy expects. A missing group claim is an IdP configuration gap, not a gateway one. If all three look right and requests still fail, check the policy reports `reason: Valid` and that the backend resolves from inside the cluster.

> [!WARNING]
> **Confirm the TLS block applies as written.** The `static` backend and the `jwks.remote.backendRef` policy are both from the v2026.7.1 schema, but the `policies.tls` stanza on a static backend has not been live-tested against a public IdP. An unknown field is rejected loudly at apply time rather than silently, so a failure here names itself — but verify before relying on it.

## Attachment C: Other LLM providers

Step 3 uses Anthropic. Every other provider is the same resource with a different key under `spec.ai.provider`. Credentials always attach the same way, through `spec.policies.auth`, so only the provider block changes.

> [!NOTE]
> **Fields below are from the v2026.7.1 CRD schema.** Read them from your own cluster with `kubectl explain enterpriseagentgatewaybackend.spec.ai.provider --recursive` if a release has moved them.

The secret carries the credential under the key `Authorization`, not `apiKey` — the same as Step 2:

```bash
kubectl create secret generic <secret-name> \
  --from-literal=Authorization=<your-api-key> \
  -n agentgateway-system
```

### C.1 OpenAI

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: openai-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:
        model: "gpt-4o"
  policies:
    auth:
      secretRef:
        name: <secret-name>
EOF
```

Only `model` is available. To reach an OpenAI-compatible endpoint that is not OpenAI, use `custom` in C.7 rather than this.

### C.2 Azure OpenAI

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: azure-openai-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      azureopenai:
        endpoint: "<resource>.openai.azure.com"
        deploymentName: "<deployment>"
        apiVersion: "2024-10-21"
  policies:
    auth:
      secretRef:
        name: <secret-name>
EOF
```

> [!WARNING]
> There is no `model` **field.** Azure OpenAI routes by deployment, so the model is whatever that deployment was created with. A caller sending `"model": "gpt-4o"` is not choosing a model here, and model aliasing in Step 15 has nothing to map onto.

### C.3 Azure AI Foundry

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: azure-foundry-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      azure:
        resourceName: "<resource>"
        resourceType: "<type>"
        projectName: "<project>"
        model: "<model>"
        apiVersion: "<api-version>"
  policies:
    auth:
      secretRef:
        name: <secret-name>
EOF
```

Distinct from `azureopenai`. This one does take a model, and adds the project and resource coordinates Foundry uses.

### C.4 Amazon Bedrock

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: bedrock-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      bedrock:
        model: "anthropic.claude-sonnet-4-5-20250929-v1:0"
        region: "us-east-1"
  policies:
    auth:
      aws:
        region: "us-east-1"
        secretRef:
          name: <aws-credentials-secret>
EOF
```

Bedrock authenticates through `policies.auth.aws` rather than a bearer secret. Use `secretRef` for static keys, or `assumeRole` with a `roleArn` for IRSA and cross-account access. The two are mutually exclusive.

> [!NOTE]
> **Bedrock can attach a guardrail at the backend.** `bedrock.guardrail` takes `identifier` and `version`, both required. That is AWS evaluating the guardrail, separate from the gateway-level guardrails in Step 8 and Attachment E. Using both means content is checked twice, in two places, with two sets of rules to keep aligned.

```text
      bedrock:
        model: "anthropic.claude-sonnet-4-5-20250929-v1:0"
        region: "us-east-1"
        guardrail:
          identifier: "<guardrail-id>"
          version: "DRAFT"
```

### C.5 Google Gemini

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: gemini-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      gemini:
        model: "gemini-2.0-flash"
  policies:
    auth:
      secretRef:
        name: <secret-name>
EOF
```

### C.6 Google Vertex AI

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: vertex-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      vertexai:
        model: "gemini-2.0-flash-001"
        projectId: "<gcp-project-id>"
        region: "us-central1"
  policies:
    auth:
      secretRef:
        name: <secret-name>
EOF
```

### C.7 Self-hosted and OpenAI-compatible endpoints

Use `custom` for anything the named providers do not cover — vLLM, Ollama, an internal inference service, or a vendor exposing an OpenAI-compatible API:

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: custom-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      custom:
        model: "<model-name>"
        backendRef:
          name: <service-name>
          namespace: <namespace>
          port: 8000
        formats:
          - type: Completions
            path: /v1/chat/completions
  policies:
    auth:
      secretRef:
        name: <secret-name>
EOF
```

`formats` declares which API surfaces the endpoint serves and where. `type` is one of `Completions`, `Messages`, `Responses`, `Embeddings`, `Rerank`, `Realtime` or `AnthropicTokenCount`, with an optional `path` that must start with a slash. Up to six entries, one per type.

> [!WARNING]
> **The endpoint is reached through a backend reference, not a URL.** This is the same rule as JWKS in Attachment B and webhook guardrails in Attachment E: anything outside the gateway is addressed by resource. For a service inside the cluster that is its Service; for an external host you need a backend that resolves it.

### C.8 Pointing a named provider somewhere else

`provider` also accepts `host`, `port`, `path` and `pathPrefix` alongside the provider block. That keeps a provider’s request and response translation while sending traffic elsewhere — a regional endpoint, a proxy, or a compatible service that speaks the same wire format.

**↩ Return to Step 3** with your backend name, and use it in the `HTTPRoute` backendRef. Everything after Step 3 is provider-independent.

## Attachment D: Collecting metrics and traces into your own stack

Nothing in the Deployment Guide requires this. The cost dashboard in Step 12 is built from traces sent to the Solo UI, and the metrics endpoint is readable directly with a port-forward, which is all Steps 10 and 11 need it for.

This attachment is for the other job: getting the telemetry into the monitoring stack you already run, so you can alert on it and query it next to everything else. Most teams reading this already have Prometheus, Datadog or Dynatrace, and would rather use it than adopt something new.

> [!WARNING]
> The metrics follow the OpenTelemetry semantic conventions for generative AI, and traces are standard OTel spans. Any Prometheus-compatible backend or OTel-capable tracing backend understands them with no custom mapping.

### D.0 What the gateway emits without any configuration

Worth being clear about what is free and what needs work.

| Signal | Available by default | Needs configuration |
|---|---|---|
| Token usage metrics on port 15020 | yes | a caller label, see Step 10.2 |
| Realized cost in access logs and CEL | after Step 11 | the model cost catalog |
| Access logs on stdout, logfmt with `jwt.sub` on every line | yes | forwarding, if you want retention |
| Traces | no | a tracing policy, see Step 10.4 |
| Scraping, dashboards, alerting | no | this attachment |

### D.1 Prometheus with the Prometheus Operator

> [!WARNING]
> **Use a PodMonitor, not a ServiceMonitor.** Verified on v2026.7.1: the `agentgateway-proxy` Service exposes one port, `listener-80`. Metrics are on the pod at 15020 and are not on any Service, which is why the port-forwards in this guide target the deployment. A ServiceMonitor has nothing to select — it applies cleanly, reports healthy, and never scrapes.

The Service is also `managed-by: agentgateway`, so adding a metrics port by hand is reconciled away. PodMonitor avoids that entirely.

```bash
kubectl apply -f- <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: agentgateway-proxy
  namespaceSelector:
    matchNames:
      - agentgateway-system
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 15s
EOF
```

The pod carries `app.kubernetes.io/name: agentgateway-proxy` and the container port is named `metrics`, so the selector needs nothing else. The `release: prometheus` label on the PodMonitor itself must match your Prometheus instance’s `podMonitorSelector` — check yours, it is the usual reason nothing appears.

Confirm it is actually scraping rather than merely accepted:

```bash
kubectl get podmonitor agentgateway-proxy -n agentgateway-system

# Then in the Prometheus UI, Status > Targets, look for the agentgateway-proxy pod.
# Or query for a metric that only exists once traffic has flowed:
#   agentgateway_gen_ai_client_token_usage_sum
```

> [!NOTE]
> **An accepted monitor that never scrapes is silent.** Nothing errors, no condition turns false, and the metric is simply absent — which looks identical to a gateway that has served no traffic. Send one request first, then check.

### D.2 Prometheus without the operator

Without the operator you scrape pods directly. There is no metrics Service to target, so use Kubernetes pod discovery and filter on the same label:

```text
scrape_configs:
  - job_name: agentgateway-proxy
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [agentgateway-system]
    relabel_configs:
      # keep only the proxy pods
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        action: keep
        regex: agentgateway-proxy
      # keep only the metrics port
      - source_labels: [__meta_kubernetes_pod_container_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
    metrics_path: /metrics
    scrape_interval: 15s
```

The second relabel matters. Without it every port on the pod is scraped, most of which return nothing, and you get failing targets alongside the working one.

> [!NOTE]
> **If your Prometheus honours scrape annotations** you may be able to skip this entirely, but the proxy pod is created by the controller from the Gateway resource, so annotations have to be set through `EnterpriseAgentgatewayParameters` rather than added by hand — anything applied directly to the pod is reconciled away.

### D.3 PromQL for cost and consumption

Metric and label names below are captured from a running v2026.7.1 gateway. The `user_id` label comes from the attribution policy in Step 10.2; without it every query still works but groups everything into one series.

```text
# Labels available on the token and cost metrics:
#   gen_ai_token_type      input | output | input_cache_read | input_cache_write
#   gen_ai_system          anthropic, openai, ...
#   gen_ai_request_model   what the caller asked for
#   gen_ai_response_model  what actually answered (may differ)
#   route                  namespace/httproute-name
#   user_id                from your Step 10.2 expression
```

**Spend by caller over a window. This is the query behind chargeback:**

```text
sum by (user_id) (
  increase(agentgateway_gen_ai_client_cost_usd_total[24h])
)
```

**Spend by model, which answers whether anyone is using an expensive model for cheap work:**

```text
sum by (gen_ai_request_model) (
  increase(agentgateway_gen_ai_client_cost_usd_total[24h])
)
```

**Top spenders, for a dashboard panel that stays readable as callers grow:**

```text
topk(10,
  sum by (user_id) (
    increase(agentgateway_gen_ai_client_cost_usd_total[7d])
  )
)
```

**Output token share. Output is the expensive half, so a rising ratio explains a rising bill that request counts do not:**

```text
sum(rate(agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type="output"}[1h]))
/
sum(rate(agentgateway_gen_ai_client_token_usage_sum[1h]))
```

**Cache effectiveness, if you have prompt caching enabled:**

```text
sum(rate(agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type="input_cache_read"}[1h]))
/
sum(rate(agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type=~"input|input_cache_read"}[1h]))
```

Catalog coverage. A `Missing` **count that grows during normal traffic means models are being served that your catalog does not price:**

```text
sum by (status, gen_ai_request_model) (
  increase(agentgateway_cost_catalog_lookups_total[1h])
)
```

> [!WARNING]
> **Three pitfalls with these.** Series persist for the life of the proxy process, so a label expression you changed leaves old values on the endpoint until a restart. `status="Exact"` does not distinguish a rate you set from a shipped default, so it is not evidence your rates are being applied. And `user_id="unknown"` on HTTP metric families is normal — those are rejected requests with no identity to resolve. Only `unknown` on a `gen_ai_*` family indicates a broken expression.

### D.4 Alerting, which matters more than the dashboards

The dashboard in Step 12 tells you what happened when someone goes and looks. These fire whether anyone is looking or not.

```bash
kubectl apply -f- <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: llm-cost-alerts
  namespace: agentgateway-system
  labels:
    release: prometheus
spec:
  groups:
    - name: llm_spend
      interval: 5m
      rules:

        # 1. A caller's daily spend crosses a threshold.
        - alert: LLMCallerDailySpendHigh
          expr: |
            sum by (user_id) (
              increase(agentgateway_gen_ai_client_cost_usd_total[24h])
            ) > 50
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "{{ \$labels.user_id }} has spent \${{ \$value | humanize }} in 24h"

        # 2. Traffic is being priced from a catalog you did not write.
        - alert: LLMUnpricedModelInUse
          expr: |
            sum by (gen_ai_request_model) (
              increase(agentgateway_cost_catalog_lookups_total{status!="Exact"}[1h])
            ) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "{{ \$labels.gen_ai_request_model }} is not priced by your catalog"

        # 3. Budget enforcement has silently stopped.
        - alert: LLMBudgetNotEnforcing
          expr: |
            absent(agentgateway_gen_ai_client_cost_usd_total) == 1
          for: 30m
          labels:
            severity: critical
          annotations:
            summary: "No LLM cost metrics for 30m: gateway down, or scraping broken"
EOF
```

**The second is the one people do not think of.** A new model appearing in traffic is priced from the shipped catalog at list rate and reported as `Exact`, so the dashboard looks healthy while your negotiated rates are not being applied. Alerting on anything other than `status="Exact"` catches models with no price at all; catching list-priced models means watching for `gen_ai_request_model` values you did not put in the catalog.

> [!WARNING]
> **Alert on budget enforcement separately.** An `EnterpriseAgentgatewayBudget` can report `ACCEPTED=True` and `ENFORCED=False` at the same time — valid, compiled, and failing open. Prometheus does not see that. Watch the resource condition with `reason: DimensionsConfigNotFound` through kube-state-metrics or a periodic check, because nothing in the data path errors when it happens.

### D.5 Datadog and Dynatrace

Both take the same shape: point an OTel collector at the gateway and forward to the vendor's endpoint.

> [!WARNING]
> **KNOWN GAP.** Rebuild the collector configuration for the current release, and answer the question nobody has answered yet: **can traces go to the Solo UI telemetry collector and a third-party backend at the same time?** The cost dashboard in Step 12 depends on spans reaching the Solo UI collector, so if forwarding to Datadog replaces that rather than adding to it, a reader has to choose between their existing tracing backend and the cost dashboard. Worth confirming before you commit to a collector topology.

### D.6 Estimating cost in PromQL without a catalog

If you have not configured a catalog in Step 11 there is no `agentgateway_gen_ai_client_cost_usd_total` to query, and you multiply token counts by rates you maintain by hand. Rates below are Anthropic Claude Sonnet list at the time of writing — substitute yours.

```text
# Spend by caller over 24h, priced by hand.
# Sonnet 4.6: $3.00 / 1M input, $15.00 / 1M output
sum by (user_id) (
  (
    increase(agentgateway_gen_ai_client_token_usage_sum{
      gen_ai_token_type="input",
      gen_ai_request_model="claude-sonnet-4-6"
    }[24h]) / 1000000 * 3.00
  )
  +
  (
    increase(agentgateway_gen_ai_client_token_usage_sum{
      gen_ai_token_type="output",
      gen_ai_request_model="claude-sonnet-4-6"
    }[24h]) / 1000000 * 15.00
  )
)
```

> [!WARNING]
> **This is a stopgap, and it has three problems the catalog does not.** The rates drift the moment a provider changes pricing, and nothing tells you. It has to be repeated per model, so every new model needs another arm in the query or it is silently costed at zero. And no policy can read it, so no dollar budget can be built on it — Step 14 budgets need the catalog.

Cache tokens are priced differently again, so a query that ignores `input_cache_read` and `input_cache_write` overstates spend on a caching workload, sometimes substantially.

**↩ Return to Step 11** and configure a catalog when you can. This works, and it is a poor destination.

## Attachment E: Guardrail alternatives

Step 8 uses regex builtins for pattern matching and OpenAI Moderation for content classification. Moderation covers requests only. For content classification on responses you need one of the four below, all of which work in both directions.

> [!NOTE]
> **They all attach the same way.** Each is an entry in `entPromptGuard.request` or `entPromptGuard.response`, alongside the regex entries from 8.2. Multiple entries in one list all run.

> [!WARNING]
> Credentials use the same `policies.auth` **block as a backend.** Exactly one of `key`, `secretRef` or `aws` — the schema rejects more than one. `aws` takes either `secretRef` or `assumeRole`, also mutually exclusive. If you configured a Bedrock backend in Attachment C, this is the same shape you already wrote.

### E.1 AWS Bedrock Guardrails

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: llm-guardrails-bedrock
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: anthropic-claude-sonnet
  backend:
    ai:
      entPromptGuard:
        response:
          - bedrockGuardrails:
              identifier: "<guardrail-id>"
              version: "DRAFT"
              region: "us-east-1"
              policies:
                auth:
                  aws:
                    region: "us-east-1"
                    assumeRole:
                      roleArn: "arn:aws:iam::<account-id>:role/<role>"
EOF
```

Use `assumeRole` on EKS with IRSA, or `secretRef` for static keys. `sessionName` and `tags` are available if your account requires session attribution.

> [!NOTE]
> **Not the same as the backend guardrail in C.4.** That one has Bedrock evaluate on the model call. This one has the gateway call Bedrock Guardrails as a separate service, so it works for any provider — including Anthropic direct.

### E.2 Google Model Armor

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: llm-guardrails-model-armor
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: anthropic-claude-sonnet
  backend:
    ai:
      entPromptGuard:
        response:
          - googleModelArmor:
              projectId: "<gcp-project-id>"
              location: "us-central1"
              templateId: "<template-id>"
              policies:
                auth:
                  secretRef:
                    name: <gcp-credentials-secret>
EOF
```

The template carries the rules. The gateway calls it and acts on the verdict, so changing what is blocked is a Google-side change with no gateway restart.

### E.3 Microsoft Purview DLP

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: llm-guardrails-purview
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: anthropic-claude-sonnet
  backend:
    ai:
      entPromptGuard:
        response:
          - purviewDlp:
              tenantId: "<entra-tenant-id>"
              clientId: "<app-registration-client-id>"
              purviewAppName: "<purview-app-name>"
              guardrailName: "<policy-name>"
              activity: "<activity>"
              apiVersion: "<api-version>"
              userId: "<user-id-or-expression>"
              policies:
                auth:
                  secretRef:
                    name: <purview-credentials-secret>
EOF
```

> [!WARNING]
> **This one has the largest configuration surface of the four** and the most identity plumbing: an Entra tenant, an app registration, a Purview app name and a user identity for attribution. `userId` is what Purview attributes the activity to, so it should carry the calling identity rather than a fixed service account if the audit trail is the point. Budget real time for this one.

### E.4 Your own webhook

```bash
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: llm-guardrails-webhook
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: anthropic-claude-sonnet
  backend:
    ai:
      entPromptGuard:
        response:
          - webhook:
              backendRef:
                name: <service-name>
                namespace: <namespace>
                port: 8080
              failureMode: FailClosed
              forwardHeaderMatches:
                - name: x-request-id
                  type: Exact
EOF
```

> [!WARNING]
> **failureMode decides what an outage does to your traffic.** `FailClosed` rejects requests when the webhook is unreachable: your guardrail holds, and a webhook outage is an outage. `FailOpen` lets traffic through unchecked: your service stays up, and content flows unguarded with nothing in the response to say so. There is no safe default here, only a choice about which failure you would rather have. Decide it deliberately and write it down.

`forwardHeaderMatches` selects which request headers reach your webhook. Forward what you need for correlation and nothing else — the payload already contains the prompt or completion.

> [!NOTE]
> **A webhook adds its latency to every request it inspects.** A response-side webhook sits between the model finishing and the caller receiving, so its round trip is added to a response the user is already waiting for. Measure it before enabling it on a latency-sensitive route.

### E.5 Streaming

> [!WARNING]
> **The Step 8 finding applies to all four.** On streamed responses, `Mask` does not apply — the gateway cannot redact content it has already begun forwarding. `Reject` does work, and the block arrives as an event inside the stream with HTTP 200 already sent. If callers on a route can set `"stream": true`, use rejection rather than masking whatever provider you choose.

**↩ Return to Step 8.4** and verify in both directions: a request that should be blocked, and a response that should be. Confirm the policy reports `reason: Valid` rather than `PartiallyValid` first — a missing credential secret drops the guard and keeps serving traffic.
