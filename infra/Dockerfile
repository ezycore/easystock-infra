# Custom Caddy image: stock Caddy + the Cloudflare DNS plugin. Required for the
# DNS-01 challenge that issues the *.ezycore.com wildcard cert (DEPLOYMENT.md §17.3).
# The stock caddy:2 image has no DNS providers built in.
FROM caddy:2-builder AS build
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=build /usr/bin/caddy /usr/bin/caddy
