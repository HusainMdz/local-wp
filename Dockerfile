# Staging: WordPress 7.1.3 on PHP 8.4 (fpm-fcgi). The base image already ships
# Imagick and Ghostscript, which staging reports as available.
FROM wordpress:7.1.3-php8.4-fpm-alpine

# Run PHP as your host user (1000) instead of 82, so files in the bind mounts and
# files WordPress / WP-CLI create are editable on both sides without sudo.
ARG WWW_UID=1000
ARG WWW_GID=1000
RUN sed -i "s/^www-data:x:82:82:/www-data:x:${WWW_UID}:${WWW_GID}:/" /etc/passwd \
    && sed -i "s/^www-data:x:82:/www-data:x:${WWW_GID}:/" /etc/group \
    && find / -xdev \( -user 82 -o -group 82 \) -exec chown -h www-data:www-data {} +

# Install system dependencies, Git, Zsh, Curl, and OpenSSH once during build.
# mariadb-client and less are for WP-CLI (`wp db import/export`, paged help).
# nodejs/npm build theme assets in place; libstdc++ is needed by the VS Code server.
RUN apk update && apk add --no-cache \
    git \
    zsh \
    curl \
    openssh-client \
    bash \
    mariadb-client \
    less \
    nodejs \
    npm \
    libstdc++

# The local MariaDB has no TLS; the Alpine client requires it by default.
RUN printf '[client]\nskip-ssl\n' > /etc/my.cnf.d/zz-no-ssl.cnf

# Install Composer globally during build
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
    && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
    && php -r "unlink('composer-setup.php');"

# Install WP-CLI. Run it as www-data so files it creates stay writable by PHP:
#   docker compose exec -u www-data wordpress wp <command>
ARG WP_CLI_VERSION=2.12.0
RUN curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && chmod +x /usr/local/bin/wp

# WP-CLI starts the MariaDB tools with --no-defaults, which skips the skip-ssl setting above;
# make its db commands read the option files so `wp db ...` reaches the local MariaDB.
ENV WP_CLI_CONFIG_PATH=/etc/wp-cli/config.yml
RUN mkdir -p /etc/wp-cli \
    && printf '%s:\n  defaults: true\n' "db check" "db cli" "db clean" "db create" "db drop" \
        "db export" "db import" "db optimize" "db query" "db repair" "db reset" \
        > /etc/wp-cli/config.yml

# Build Xdebug but do not enable it: only dev/php.ini (compose.override.yml)
# loads it, so a staging-only run stays without it.
ARG XDEBUG_VERSION=3.5.3
RUN apk add --no-cache --virtual .xdebug-build $PHPIZE_DEPS linux-headers \
    && pecl install "xdebug-${XDEBUG_VERSION}" \
    && rm -rf /tmp/pear \
    && apk del .xdebug-build

# Oh My Zsh, shared by root and www-data:
#   docker compose exec wordpress zsh                (root)
#   docker compose exec -u www-data wordpress zsh    (www-data, for WP-CLI)
ENV ZSH=/usr/share/oh-my-zsh
COPY dev/zshrc /etc/skel/.zshrc
RUN git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$ZSH" \
    && rm -rf "$ZSH/.git" \
    && sed -i 's#^root:\(.*\):/bin/sh$#root:\1:/bin/zsh#' /etc/passwd \
    && cp /etc/skel/.zshrc /root/.zshrc \
    && mkdir -p /home/www-data \
    && cp /etc/skel/.zshrc /home/www-data/.zshrc \
    && chown -R www-data:www-data /home/www-data \
    && mkdir -p /var/lib/shell-history \
    && chmod 1777 /var/lib/shell-history

WORKDIR /var/www/html
