# syntax=docker/dockerfile:1
#
# XenForo PHP-FPM runtime. Contains NO XenForo source — see docs/licensing-and-ci.md
# for why (XF source is license-restricted and cannot be redistributed in an image).
# The forum tree lives on a PersistentVolume; this image supplies only the PHP
# runtime, the extension set XenForo needs, and the env-driven config.php.
#
# Extension selection and build technique are adapted from XenForo's own MIT-licensed
# Dockerfile at https://github.com/xenforo-ltd/cli (internal/docker/embed/Dockerfile).
# See NOTICE.md.

ARG PHP_VERSION=8.4

# XenForo 2.3 supports PHP 7.2+; XenForo's own tooling defaults to 8.5. We pin 8.4
# because that is the newest version the add-on ecosystem is reliably tested against.
FROM php:${PHP_VERSION}-fpm-alpine

LABEL org.opencontainers.image.title="xenforo-k8s"
LABEL org.opencontainers.image.description="PHP-FPM runtime for XenForo on Kubernetes (no XenForo source included)"
LABEL org.opencontainers.image.vendor="SiliconSaga"
LABEL org.opencontainers.image.source="https://github.com/SiliconSaga/xenforo-k8s"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# imagick and redis are pecl builds and add meaningful build time. Both are off by
# default: a low-traffic forum does not need them, and GD covers image handling.
ARG PHP_BUILD_IMAGICK=0
ARG PHP_BUILD_REDIS=0
ARG PHP_VERSION_IGBINARY=3.2.17RC1
ARG PHP_VERSION_IMAGICK=3.8.1
ARG PHP_VERSION_REDIS=6.3.0

# --- Required by XenForo -----------------------------------------------------

RUN set -eux; \
    docker-php-ext-install -j"$(nproc)" exif;

RUN set -eux; \
    docker-php-ext-install -j"$(nproc)" mysqli pdo_mysql;

# GD with jpeg/webp/avif. The -dev packages go in as a virtual package so they can
# be dropped again in the same layer — keeps the runtime image small.
RUN set -eux; \
    apk add --no-cache --virtual .deps-gd \
        aom-libs \
        libavif \
        libdav1d \
        libjpeg-turbo \
        libpng \
        libwebp \
    ; \
    apk add --no-cache --virtual .deps-gd-build \
        aom-dev \
        dav1d-dev \
        libavif-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libwebp-dev \
        zlib-dev \
    ; \
    docker-php-ext-configure gd --with-avif --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" gd; \
    apk del .deps-gd-build;

RUN set -eux; \
    apk add --no-cache --virtual .deps-gmp gmp; \
    apk add --no-cache --virtual .deps-gmp-build gmp-dev; \
    docker-php-ext-install -j"$(nproc)" gmp; \
    apk del .deps-gmp-build;

RUN set -eux; \
    apk add --no-cache --virtual .deps-intl icu-libs; \
    apk add --no-cache --virtual .deps-intl-build icu-dev; \
    docker-php-ext-install -j"$(nproc)" intl; \
    apk del .deps-intl-build;

# zip/unzip are also used by XenForo's add-on archive installer, so keep the CLI
# tools around, not just the PHP extension.
RUN set -eux; \
    apk add --no-cache --virtual .deps-zip \
        libzip \
        unzip \
        zip \
    ; \
    apk add --no-cache --virtual .deps-zip-build libzip-dev; \
    docker-php-ext-install -j"$(nproc)" zip; \
    apk del .deps-zip-build;

RUN set -eux; \
    docker-php-ext-install -j"$(nproc)" opcache; \
    { \
        echo "opcache.jit=tracing"; \
        echo "opcache.jit_buffer_size=64M"; \
        echo "opcache.validate_timestamps=1"; \
        echo "opcache.revalidate_freq=15"; \
    } >> "${PHP_INI_DIR}/conf.d/docker-php-ext-opcache.ini";

# --- Optional -----------------------------------------------------------------

RUN set -eux; \
    if [ "${PHP_BUILD_IMAGICK}" -ne 0 ]; then \
        apk add --no-cache --virtual .deps-imagick imagemagick libgomp; \
        apk add --no-cache --virtual .deps-imagick-build ${PHPIZE_DEPS} imagemagick-dev; \
        pecl install "imagick-${PHP_VERSION_IMAGICK}"; \
        docker-php-ext-enable imagick; \
        rm -rf /tmp/pear; \
        apk del .deps-imagick-build; \
    fi;

RUN set -eux; \
    if [ "${PHP_BUILD_REDIS}" -ne 0 ]; then \
        apk add --no-cache --virtual .deps-redis-build ${PHPIZE_DEPS}; \
        pecl install "igbinary-${PHP_VERSION_IGBINARY}"; \
        pecl install --configureoptions 'enable-redis-igbinary="yes"' "redis-${PHP_VERSION_REDIS}"; \
        docker-php-ext-enable igbinary redis; \
        rm -rf /tmp/pear; \
        apk del .deps-redis-build; \
    fi;

# --- PHP configuration ---------------------------------------------------------

RUN set -eux; \
    cp "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"; \
    { \
        echo "post_max_size=128M"; \
        echo "upload_max_filesize=128M"; \
        echo "memory_limit=256M"; \
        echo "expose_php=Off"; \
    } > "${PHP_INI_DIR}/conf.d/xenforo.ini";

# php-fpm's default pool logs to a file and daemonizes access logging oddly under
# Kubernetes. Send everything to stdout/stderr so `kubectl logs` is the whole story.
RUN set -eux; \
    { \
        echo "[global]"; \
        echo "error_log = /proc/self/fd/2"; \
        echo "log_limit = 8192"; \
        echo "[www]"; \
        echo "access.log = /proc/self/fd/1"; \
        echo "catch_workers_output = yes"; \
        echo "decorate_workers_output = no"; \
        echo "clear_env = no"; \
        echo "pm = dynamic"; \
        echo "pm.max_children = 10"; \
        echo "pm.start_servers = 2"; \
        echo "pm.min_spare_servers = 1"; \
        echo "pm.max_spare_servers = 3"; \
    } > /usr/local/etc/php-fpm.d/zz-xenforo.conf;

# config.php and the Caddyfile are baked here rather than shipped as ConfigMaps so
# there is exactly one canonical copy of each, versioned with the image. An init
# container copies them into place at pod start — see kustomize/base/deployment.yaml.
# config.php reads everything from the environment, including the *_FILE
# indirection Kubernetes secret mounts rely on.
COPY config.php /opt/xenforo/config.php
COPY caddy/Caddyfile /opt/xenforo/Caddyfile

WORKDIR /var/www/html

EXPOSE 9000

CMD ["php-fpm"]
