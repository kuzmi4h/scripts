#!/usr/bin/env bash
set -euo pipefail

########################
# CONFIG
########################

# Внешний репозиторий VyOS
UPSTREAM_BASE="https://packages.vyos.net/repositories/current"

# Что зеркалим
DIST="current"
ARCHES=("amd64" "arm64")

# Куда зеркалим (HTTP root)
ROOT="/var/www/html/vyos"

# Логи
LOG_DIR="/var/log/vyos-mirror"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/mirror-$(date +%F).log"

# Параллелизм
JOBS=8

########################
# LOGGING
########################

log() {
    local ts
    ts="$(date '+%F %T')"
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

########################
# CHECK DEPENDENCIES
########################

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required command '$1' not found in PATH" >&2
        exit 1
    }
}

check_deps() {
    for cmd in curl gzip awk sort xargs dpkg-scanpackages sha256sum; do
        need_cmd "$cmd"
    done
}

########################
# DOWNLOAD HELPER
########################

# Скачивание с резюмом и проверкой HTTP-кода
fetch_file() {
    local url="$1"
    local dest="$2"

    mkdir -p "$(dirname "$dest")"

    # Если файл уже есть, пробуем использовать --continue
    if [[ -f "$dest" ]]; then
        curl -fL --continue-at - --retry 3 --retry-delay 2 -o "$dest" "$url" \
            && return 0 \
            || log "WARN: resume failed for $url, re-downloading..."
    fi

    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
}

########################
# STEP 1: SYNC META (Release, InRelease, Contents)
########################

sync_metadata() {
    local dist="$DIST"
    local base="$UPSTREAM_BASE/dists/$dist"
    local local_dist_dir="$ROOT/dists/$dist"

    mkdir -p "$local_dist_dir"

    log "Syncing metadata for dist '$dist'..."

    # Release / InRelease / Contents-*.gz
    for f in Release InRelease Contents-any.gz; do
        local src="$base/$f"
        local dst="$local_dist_dir/$f"
        log "  -> $src"
        if ! fetch_file "$src" "$dst"; then
            log "ERROR: failed to fetch $src"
        fi
    done
}

########################
# STEP 2: PARSE CONTENTS AND BUILD PACKAGE LIST
########################

build_package_list() {
    local dist="$DIST"
    local contents="$ROOT/dists/$dist/Contents-any.gz"
    local list_dir="$ROOT/.lists"
    mkdir -p "$list_dir"

    if [[ ! -f "$contents" ]]; then
        log "ERROR: Contents-any.gz not found at $contents"
        exit 1
    fi

    log "Building package path list from Contents-any.gz ..."

    # Формат Contents-any.gz:  <path> <package>
    # Нам нужен только уникальный список путей (pool/...deb)
    gzip -dc "$contents" \
        | awk '{print $1}' \
        | grep '\.deb$' \
        | sort -u \
        > "$list_dir/all-paths.txt"

    log "Total unique .deb paths: $(wc -l < "$list_dir/all-paths.txt")"

    # На всякий случай сохраняем как есть — Upstream уже содержит только актуальные версии
    # Но если понадобится логика выбора latest по имени/версии — сюда можно встроить.
}

########################
# STEP 3: DOWNLOAD PACKAGES IN PARALLEL
########################

download_packages() {
    local list_dir="$ROOT/.lists"
    local pool_dir="$ROOT/pool"

    mkdir -p "$pool_dir"

    log "Starting parallel download of packages with $JOBS jobs..."

    # Функция для xargs
    _dl_one() {
        local rel_path="$1"
        local url="$UPSTREAM_BASE/$rel_path"
        local dst="$pool_dir/$(basename "$rel_path")"

        # Если файл уже есть — пропускаем (resume-logic)
        if [[ -f "$dst" ]]; then
            echo "SKIP $url" >&2
            return 0
        fi

        echo "GET  $url" >&2
        if ! fetch_file "$url" "$dst"; then
            echo "FAIL $url" >&2
            rm -f "$dst"
            return 1
        fi
    }

    export -f _dl_one fetch_file log
    export UPSTREAM_BASE pool_dir

    # xargs - загрузка с параллелизмом
    < "$list_dir/all-paths.txt" xargs -P "$JOBS" -n 1 bash -lc '_dl_one "$@"' _

    log "Package download phase finished."
}

########################
# STEP 4: GENERATE Packages.gz PER ARCH
########################

generate_packages_indices() {
    local dist="$DIST"

    for arch in "${ARCHES[@]}"; do
        local bin_dir="$ROOT/dists/$dist/main/binary-$arch"
        mkdir -p "$bin_dir"

        log "Generating Packages.gz for arch=$arch ..."

        # В данном случае у нас один общий pool, но это нормально: APT сам отфильтрует по arch внутри .deb
        dpkg-scanpackages "$ROOT/pool" /dev/null \
            | gzip -9 \
            > "$bin_dir/Packages.gz"
    done
}

########################
# STEP 5: GENERATE Release (LOCAL)
########################

generate_release() {
    local dist="$DIST"
    local dist_dir="$ROOT/dists/$dist"

    log "Generating local Release file..."

    cat > "$dist_dir/Release" <<EOF
Origin: Local VyOS Mirror
Label: LocalVyOS
Suite: $dist
Codename: $dist
Architectures: ${ARCHES[*]}
Components: main
Date: $(date -Ru)
EOF

    # Добавим SHA256 для Packages.gz
    {
        echo "SHA256:"
        for arch in "${ARCHES[@]}"; do
            local bin_dir="$dist_dir/main/binary-$arch"
            local pkgs_gz="$bin_dir/Packages.gz"
            if [[ -f "$pkgs_gz" ]]; then
                local sum size rel
                sum="$(sha256sum "$pkgs_gz" | awk '{print $1}')"
                size="$(stat -c%s "$pkgs_gz")"
                # Относительный путь от dists/$dist
                rel="main/binary-$arch/Packages.gz"
                printf " %s %16d %s\n" "$sum" "$size" "$rel"
            fi
        done
    } >> "$dist_dir/Release"
}

########################
# MAIN
########################

main() {
    check_deps

    log "==== Starting VyOS mirror sync ===="
    log "UPSTREAM: $UPSTREAM_BASE"
    log "ROOT:     $ROOT"
    log "DIST:     $DIST"
    log "ARCHES:   ${ARCHES[*]}"
    log "JOBS:     $JOBS"

    mkdir -p "$ROOT"

    sync_metadata
    build_package_list
    download_packages
    generate_packages_indices
    generate_release

    log "==== VyOS mirror sync finished ===="
}

main "$@"
