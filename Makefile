.PHONY: help
help:
	@echo "make [TARGETS...]"
	@echo
	@echo "This is the makefile of osbuild-getting-started. The following"
	@echo "targets are available:"
	@echo
	@echo "  service_containers:      Build all needed containers from source to be able to run the service"
	@echo "  run_service:             Run all containers needed for the 'service'"
	@echo "                           This is running in foreground. Use CTRL-C to stop the containers."
	@echo "  run_service_no_frontend: Run all containers except for the frontend"
	@echo "  stop_service:            Usually the containers get stopped by CTRL-C. So 'stop-service'"
	@echo "                           is only needed if something strange happened and not all are stopped."
	@echo "  prune_service:           Remove the containers, including the test-data!"
	@echo "                           If you want empty databases"
	@echo "  clean:                   Clean all subprojects to assure a rebuild"

# source where the other repos are locally
# has to end with a trailing slash
SRC_DEPS_EXTERNAL_CHECKOUT_DIR ?= ../

# either "docker" or "sudo podman"
# podman needs to build as root as it also needs to run as root afterwards
CONTAINER_EXECUTABLE ?= docker
CONTAINER_COMPOSE_EXECUTABLE ?= $(CONTAINER_EXECUTABLE) compose

MAKE_SUB_CALL := make CONTAINER_EXECUTABLE="$(CONTAINER_EXECUTABLE)"

# osbuild is indirectly used by osbuild-composer
# but we'll mention it here too for better error messages and usability
COMMON_SRC_DEPS_NAMES := osbuild osbuild-composer pulp-client community-gateway
COMMON_SRC_DEPS_ORIGIN := $(addprefix $(SRC_DEPS_EXTERNAL_CHECKOUT_DIR),$(COMMON_SRC_DEPS_NAMES))

ONPREM_SRC_DEPS_NAMES := weldr-client
ONPREM_SRC_DEPS_ORIGIN := $(addprefix $(SRC_DEPS_EXTERNAL_CHECKOUT_DIR),$(ONPREM_SRC_DEPS_NAMES))

SERVICE_SRC_DEPS_NAMES := image-builder image-builder-frontend
SERVICE_SRC_DEPS_ORIGIN := $(addprefix $(SRC_DEPS_EXTERNAL_CHECKOUT_DIR),$(SERVICE_SRC_DEPS_NAMES))

# should be set if we are already sudo - otherwise we set to "whoami"
SUDO_USER ?= $(shell whoami)

$(COMMON_SRC_DEPS_ORIGIN) $(SERVICE_SRC_DEPS_ORIGIN) $(ONPREM_SRC_DEPS_ORIGIN):
	@for DIR in $@; do if ! [ -d $$DIR ]; then echo "Please checkout $$DIR so it is available at $$DIR"; exit 1; fi; done

COMPARE_TO_BRANCH ?= origin/main

SCRATCH_DIR := $(HOME)/.cache/osbuild-getting-started/scratch
export SCRATCH_DIR
COMMON_DIR := image-builder-config
CLI_DIRS := weldr cloudapi dnf-json
DATA_DIR := data/s3/service
ALL_SCRATCH_DIRS := $(addprefix $(SCRATCH_DIR)/,$(COMMON_DIR) $(CLI_DIRS) $(DATA_DIR))

# internal rule for sub-calls
# NOTE: This chowns all directories back - as we expect to run partly as root
# also we "git fetch origin" to get the current state!
.PHONY: common_sub_makes
common_sub_makes:
	@echo "We need to build everything as root, as the target also needs to run as root."
	@echo "At least for podman the password as already needed now"

	# creating container image from osbuild as a basis for worker
	$(MAKE_SUB_CALL) -C $(SRC_DEPS_EXTERNAL_CHECKOUT_DIR)osbuild-composer container_worker.dev container_composer.dev

.PHONY: service_sub_make_backend
service_sub_make_backend:
	$(MAKE_SUB_CALL) -C $(SRC_DEPS_EXTERNAL_CHECKOUT_DIR)image-builder container.dev

.PHONY: service_sub_make_frontend
service_sub_make_frontend:
	$(MAKE_SUB_CALL) -C $(SRC_DEPS_EXTERNAL_CHECKOUT_DIR)image-builder-frontend container.dev

.PHONY: service_sub_make_cleanup
service_sub_make_cleanup:
	@for DIR in $(COMMON_SRC_DEPS_ORIGIN) $(SERVICE_SRC_DEPS_ORIGIN); do echo "Giving directory permissions in '$$DIR' back to '$(SUDO_USER)'"; chown -R $(SUDO_USER): $$DIR || sudo chown -R $(SUDO_USER): $$DIR; done
	@echo "Your current versions are (comparing to origin/main):"
	bash -c './tools/git_stack.sh'

.PHONY: service_sub_makes_no_frontend
service_sub_makes_no_frontend: service_sub_make_backend service_sub_make_cleanup

.PHONY: service_sub_makes
service_sub_makes: service_sub_make_backend service_sub_make_frontend service_sub_make_cleanup

.PHONY: onprem_sub_makes
onprem_sub_makes:
	# building the cli
	$(MAKE_SUB_CALL) -C $(SRC_DEPS_EXTERNAL_CHECKOUT_DIR)weldr-client container.dev
	@for DIR in $(COMMON_SRC_DEPS_ORIGIN) $(ONPREM_SRC_DEPS_ORIGIN); do echo "Giving directory permissions in '$$DIR' back to '$(SUDO_USER)'"; chown -R $(SUDO_USER): $$DIR || sudo chown -R $(SUDO_USER): $$DIR; done
	@echo "Your current versions are (comparing to origin/main):"
	bash -c './tools/git_stack.sh'

.PHONY: service_containers
service_containers: $(COMMON_SRC_DEPS_ORIGIN) $(SERVICE_SRC_DEPS_ORIGIN) common_sub_makes service_sub_makes service_images_built.info

.PHONY: service_containers_no_frontend
service_containers_no_frontend: $(COMMON_SRC_DEPS_ORIGIN) $(SERVICE_SRC_DEPS_ORIGIN) common_sub_makes service_sub_makes_no_frontend service_images_built.info

onprem_containers: $(COMMON_SRC_DEPS_ORIGIN) $(ONPREM_SRC_DEPS_ORIGIN) common_sub_makes onprem_sub_makes onprem_images_built.info

service_images_built.info: service/config/Dockerfile-config service/config/composer/osbuild-composer.toml $(ALL_SCRATCH_DIRS)
	# building remaining containers (config, fauxauth)
	$(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose.yml build --build-arg CONFIG_BUILD_DATE=$(shell date -r $(SCRATCH_DIR)/$(COMMON_DIR) +%Y%m%d_%H%M%S)
	echo "Images last built on" > $@
	date >> $@

onprem_images_built.info: service/config/Dockerfile-config-onprem service/config/composer/osbuild-composer-onprem.toml $(ALL_SCRATCH_DIRS)
	# building remaining containers (config)
	$(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose-onprem.yml build --build-arg CONFIG_BUILD_DATE=$(shell date -r $(SCRATCH_DIR)/$(COMMON_DIR) +%Y%m%d_%H%M%S)
	echo "Images last built on" > $@
	date >> $@

$(ALL_SCRATCH_DIRS):
	@echo "Creating directory: $@"
	mkdir -p $@ || ( echo "Trying as root" ; sudo mkdir -p $@ )

.PHONY: wipe_config
wipe_config:
	sudo rm -rf $(SCRATCH_DIR)/$(COMMON_DIR)
	rm -f $(SRC_DEPS_EXTERNAL_CHECKOUT_DIR)image-builder-frontend/node_modules/.cache/webpack-dev-server/server.pem

.PHONY: clean
clean: prune_service prune_onprem wipe_config
	rm -f service_images_built.info
	rm -f onprem_images_built.info
	rm -rf $(SCRATCH_DIR) || (echo "Trying as root" ;sudo rm -rf $(SCRATCH_DIR))
	for DIR in $(COMMON_SRC_DEPS_ORIGIN) $(SERVICE_SRC_DEPS_ORIGIN) $(ONPREM_SRC_DEPS_ORIGIN); do $(MAKE_SUB_CALL) -C $$DIR clean; done
	$(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose.yml down --volumes
	$(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose.yml rm --volumes
	$(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose-onprem.yml down --volumes
	$(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose-onprem.yml rm --volumes	

# for compatibility of relative volume mount paths
# between docker and podman we have to change to the directory
.PHONY: run_service
.ONESHELL:
SHELL := /bin/bash
.SHELLFLAGS := -ec -o pipefail

run_service: $(addprefix $(SCRATCH_DIR)/,$(COMMON_DIRS)) service_containers
	export PORTS="$(shell $(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose.yml config|grep -Po '(?<=published: ")[0-9]+')"
	echo "-- Checking if any of our ports are used: $$PORTS"
	sudo netstat -lntp|grep -E "$$(echo "$$PORTS"|tr ' ' ':')"
	echo "-- Check done"
	cd service
	$(CONTAINER_COMPOSE_EXECUTABLE) up

# if you want to run the frontend yourself - outside the docker environment
.PHONY: run_service_no_frontend
run_service_no_frontend: service_containers_no_frontend
	$(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose.yml up backend fauxauth worker composer minio postgres_backend postgres_composer

# only for strange crashes - should shut down properly in normal operation
.PHONY: stop_service
.ONESHELL:
stop_service:
	cd service
	$(CONTAINER_COMPOSE_EXECUTABLE) stop

.PHONY: prune_service
.ONESHELL:
prune_service:
	cd service
	$(CONTAINER_COMPOSE_EXECUTABLE) down

.PHONY: prune_onprem
.ONESHELL:
prune_onprem:
	cd service
	$(CONTAINER_COMPOSE_EXECUTABLE) -f docker-compose-onprem.yml down

# for compatibility of relative volume mount paths
# between docker and podman we have to change to the directory
.PHONY: run_onprem
.ONESHELL:
run_onprem: $(addprefix $(SCRATCH_DIR)/,$(COMMON_DIRS) $(CLI_DIRS)) onprem_containers
	cd service
	echo "Remove dangling sockets as root"
	sudo rm -f $(addsuffix /api.sock*, $(addprefix $(SCRATCH_DIR)/, $(CLI_DIRS)))
	$(CONTAINER_COMPOSE_EXECUTABLE) -f docker-compose-onprem.yml up -d
	@echo "------ Welcome to osbuild! You can now use 'composer-cli' to build images"
	@echo "       … and 'exit' afterwards"
	@echo "       You might also be interested to open up a second terminal and"
	@echo "       run 'docker compose -f $(shell readlink -f service/docker-compose-onprem.yml) logs --follow' to see possible problems"

	$(CONTAINER_COMPOSE_EXECUTABLE) -f docker-compose-onprem.yml run --entrypoint /bin/bash -ti cli
	$(CONTAINER_COMPOSE_EXECUTABLE) -f docker-compose-onprem.yml stop

%.svg: %.dot
	dot -T svg $< > $@

.PHONY: docs
docs: docs/src_compile_service.svg docs/src_compile_onprem.svg

.PHONY: overview
overview:
	@echo "Fetching all repos for better overview if rebase will be necessary:"
ifeq (${SUDO_USER},$(shell whoami))
	bash -c './tools/git_stack.sh fetch --all'
else
	sudo -u ${SUDO_USER} bash -c './tools/git_stack.sh fetch --all'
endif
	@bash -c './tools/git_stack.sh'

