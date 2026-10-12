# Shared by ./build.sh and ./build-gui.sh.
# Docker Desktop resolves names through the LAN DNS server. That server can
# fail production.cloudfront.docker.com, which is where Docker Hub stores
# image blobs. A BuildKit container pointed at public resolvers can.
# Sets openscad_builder to the builder name.

ensure_buildx_builder() {
  openscad_builder=openscad-arm64
  local bk_container=buildx_buildkit_openscad-arm640
  local bk_image=moby/buildkit:buildx-stable-1

  if ! "${docker_cmd[@]}" image inspect "$bk_image" >/dev/null 2>&1; then
    echo "The local image $bk_image is required. Docker cannot pull it while its DNS resolver fails." >&2
    exit 1
  fi

  if ! "${docker_cmd[@]}" buildx inspect "$openscad_builder" >/dev/null 2>&1; then
    "${docker_cmd[@]}" buildx create --name "$openscad_builder" --driver docker-container \
      --driver-opt "image=$bk_image" >/dev/null
  fi

  local bk_dns=""
  if "${docker_cmd[@]}" container inspect "$bk_container" >/dev/null 2>&1; then
    bk_dns=$("${docker_cmd[@]}" inspect --format '{{join .HostConfig.Dns " "}}' "$bk_container")
  fi
  if [[ "$bk_dns" != *8.8.8.8* ]]; then
    if "${docker_cmd[@]}" container inspect "$bk_container" >/dev/null 2>&1; then
      "${docker_cmd[@]}" rm -f "$bk_container" >/dev/null
    fi
    "${docker_cmd[@]}" run -d --name "$bk_container" --privileged --init \
      --dns 8.8.8.8 --dns 1.1.1.1 \
      --restart unless-stopped \
      -v "${bk_container}_state:/var/lib/buildkit" \
      "$bk_image" \
      --allow-insecure-entitlement=network.host >/dev/null
  fi
  "${docker_cmd[@]}" buildx inspect --bootstrap "$openscad_builder" >/dev/null
}
