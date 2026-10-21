# Shortcuts for the local Docker environment. `make` lists them.
-include .env
export

SHELL := /bin/bash
.SHELLFLAGS := -eo pipefail -c

COMPOSE ?= docker compose
# -T (no TTY) so output can be piped: db export/import, git hooks.
WP    = $(COMPOSE) exec -T -u www-data wordpress wp
# Dump/restore with the db container's own client: the WordPress image's client is
# MariaDB 11, whose dumps set NOTE_VERBOSITY, which the 10.11.5 server rejects.
DB_CLI = $(COMPOSE) exec -T db sh -c
STAMP := $(shell date +%Y%m%d-%H%M%S)
CA_DIR := $(HOME)/.local/share/mindzer-dev-ca

STAGING_PATH    ?= /var/www/vhosts/mindzersystems.com/staging.mindzersystems.com
STAGING_URL     ?= https://staging.mindzersystems.com
STAGING_WP      ?= wp
LOCAL_URL       ?= https://localhost
DB_TABLE_PREFIX ?= wp_

.DEFAULT_GOAL := help
.PHONY: help up down logs shell root-shell wp debug-log fix-perms dev-plugins \
        db-export db-import pull-staging certs trust-cert

help: ## List the commands
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-13s %s\n", $$1, $$2}'

# ─── Stack ────────────────────────────────────────────────────────────────

up: dev/certs/localhost.pem ## Build and start, wait until ready, then dev setup
	$(COMPOSE) up -d --build --wait
	@$(MAKE) --no-print-directory fix-perms dev-plugins

down: ## Stop the stack (data volumes are kept)
	$(COMPOSE) down

logs: ## Follow all container logs
	$(COMPOSE) logs -f

shell: ## zsh as www-data (the user for WP-CLI)
	$(COMPOSE) exec -u www-data wordpress zsh

root-shell: ## zsh as root
	$(COMPOSE) exec wordpress zsh

wp: ## WP-CLI: make wp ARGS="plugin list"
	$(COMPOSE) exec -u www-data wordpress wp $(ARGS)

debug-log: ## Follow wp-content/debug.log
	$(COMPOSE) exec wordpress tail -F wp-content/debug.log

# Files from before www-data became UID 1000 (or created by Docker as root).
fix-perms:
	@$(COMPOSE) exec -T wordpress find /var/www/html -xdev \
		\( ! -user www-data -o ! -group www-data \) -exec chown -h www-data:www-data {} +

dev-plugins: ## Install + activate Query Monitor (dev only, lives in the volume)
	@if $(WP) core is-installed 2>/dev/null; then \
		$(WP) plugin is-installed query-monitor || $(WP) plugin install query-monitor; \
		$(WP) plugin activate query-monitor; \
	else \
		echo "WordPress is not installed yet; run 'make dev-plugins' after installing or importing."; \
	fi

# ─── Database ─────────────────────────────────────────────────────────────

db-export: ## Save the local database to backups/local-<time>.sql.gz
	@mkdir -p backups
	$(DB_CLI) 'mariadb-dump -u"$$MARIADB_USER" -p"$$MARIADB_PASSWORD" --single-transaction "$$MARIADB_DATABASE"' \
		| gzip > backups/local-$(STAMP).sql.gz
	@echo "Saved backups/local-$(STAMP).sql.gz"

db-import: ## Replace the local database: make db-import FILE=dump.sql[.gz]
	@test -n "$(FILE)" || { echo "Usage: make db-import FILE=path/to/dump.sql[.gz]"; exit 1; }
	@test -f "$(FILE)" || { echo "No such file: $(FILE)"; exit 1; }
	@$(MAKE) --no-print-directory db-export
	$(DB_CLI) 'mariadb -u"$$MARIADB_USER" -p"$$MARIADB_PASSWORD" -e "DROP DATABASE \`$$MARIADB_DATABASE\`; CREATE DATABASE \`$$MARIADB_DATABASE\`"'
	case "$(FILE)" in *.gz) gunzip -c "$(FILE)" ;; *) cat "$(FILE)" ;; esac \
		| $(DB_CLI) 'mariadb -u"$$MARIADB_USER" -p"$$MARIADB_PASSWORD" "$$MARIADB_DATABASE"'

pull-staging: ## Copy staging's database here and point its URLs at LOCAL_URL
	@test -n "$(STAGING_SSH)" || { echo "Set STAGING_SSH (user@host) in .env"; exit 1; }
	@prefix=$$(ssh $(STAGING_SSH) "cd '$(STAGING_PATH)' && $(STAGING_WP) db prefix"); \
	if [ "$$prefix" != "$(DB_TABLE_PREFIX)" ]; then \
		echo "Staging uses table prefix '$$prefix', local uses '$(DB_TABLE_PREFIX)'."; \
		echo "Set DB_TABLE_PREFIX=$$prefix in .env, run 'make up', then retry."; \
		exit 1; \
	fi
	@mkdir -p backups
	ssh $(STAGING_SSH) "cd '$(STAGING_PATH)' && $(STAGING_WP) db export - --single-transaction" \
		| gzip > backups/staging-$(STAMP).sql.gz
	@$(MAKE) --no-print-directory db-import FILE=backups/staging-$(STAMP).sql.gz
	$(WP) search-replace '$(STAGING_URL)' '$(LOCAL_URL)' --all-tables-with-prefix --skip-columns=guid --report-changed-only
	$(WP) search-replace '$(subst https://,http://,$(STAGING_URL))' '$(LOCAL_URL)' --all-tables-with-prefix --skip-columns=guid --report-changed-only
	$(WP) cache flush
	@$(MAKE) --no-print-directory dev-plugins

# ─── HTTPS ────────────────────────────────────────────────────────────────

dev/certs/localhost.pem:
	@mkdir -p dev/certs "$(CA_DIR)"
	docker run --rm -e OWNER=$$(id -u):$$(id -g) \
		-v "$(CA_DIR):/ca" -v "$(CURDIR)/dev/certs:/certs" \
		-v "$(CURDIR)/dev/make-certs.sh:/make-certs.sh:ro" \
		alpine:3.22 sh -c 'apk add --no-cache -q openssl && sh /make-certs.sh'

certs: ## Recreate the localhost certificate (the CA is kept)
	rm -f dev/certs/localhost.pem dev/certs/localhost-key.pem
	@$(MAKE) --no-print-directory dev/certs/localhost.pem

trust-cert: dev/certs/localhost.pem ## Trust the local CA in Windows (confirm the dialog)
	@win_tmp=$$(wslpath "$$(powershell.exe -NoProfile -Command '[IO.Path]::GetTempPath()' | tr -d '\r')"); \
	cp "$(CA_DIR)/rootCA.pem" "$$win_tmp/mindzer-dev-ca.crt"; \
	powershell.exe -NoProfile -Command "Import-Certificate -FilePath \"$$(wslpath -w "$$win_tmp/mindzer-dev-ca.crt")\" -CertStoreLocation Cert:\CurrentUser\Root | Out-Null"; \
	rm -f "$$win_tmp/mindzer-dev-ca.crt"; \
	echo "Trusted. Restart the browser, then open $(LOCAL_URL)"
