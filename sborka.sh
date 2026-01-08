#!/usr/bin/env bash
set -euo pipefail

# === Настройки ===
# Путь к локальному репозиторию (может быть http://, https:// или file://)
#LOCAL_REPO="http://repo.local/vyos/"
LOCAL_REPO="file://home/user/vyos-build/vyos-local-repo/"
# Архитектура (amd64 или arm64)
ARCH="amd64"
# Директория для сборки
BUILD_DIR="$HOME/vyos-build"

# === Подготовка окружения ===
sudo apt-get update
sudo apt-get install -y git make python3 python3-pip \
    live-build pbuilder debootstrap devscripts equivs \
    curl gnupg

# === Клонирование исходников VyOS ===
#if [ ! -d "$BUILD_DIR" ]; then
#    git clone https://github.com/vyos/vyos-build.git "$BUILD_DIR"
#fi
#cd "$BUILD_DIR"

# === Настройка локального репозитория ===
# Меняем defaults.toml
pushd "$BUILD_DIR"
sed -i "s|https://packages.vyos.net/|$LOCAL_REPO|g" data/defaults.toml

# Меняем списки пакетов
for f in data/packages/*.list; do
    sed -i "s|https://packages.vyos.net/|$LOCAL_REPO|g" "$f"
done

# === Сборка образа ===
# Пример: rolling release
./build-vyos-image \
    --architecture "$ARCH" \
    --build-type release \
    --version rolling \
    --debian-mirror "$LOCAL_REPO"

echo "Образ собран. Проверьте каталог build/ для ISO."
