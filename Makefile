.PHONY: help
help:
	@echo "make [TARGETS...]"
	@echo
	@echo "This is the makefile of osbuild-getting-started. The following"
	@echo "targets are available:"
	@echo
	@echo "    service-containers: Build all needed containers from source to be able to run the service"
	@echo "    run-service:        Run all containers to needed for the 'service'"
	@echo "    clean:              Clean all subprojects to assure a rebuild"

CONTAINER_EXECUTABLE := docker
CONTAINER_COMPOSE_EXECUTABLE := $(CONTAINER_EXECUTABLE) compose

MAKE_SUB_CALL := make CONTAINER_EXECUTABLE="$(CONTAINER_EXECUTABLE)"

SRC_DEPS_NAMES := osbuild osbuild-composer image-builder
SRC_DEPS_ORIGIN := $(addprefix ../,$(SRC_DEPS_NAMES))

$(SRC_DEPS_ORIGIN):
	@for DIR in $@; do if ! [ -d $$DIR ]; then echo "Please checkout $$DIR so it is available at $$(pwd)/$$DIR"; exit 1; fi; done

.PHONY: service-containers
service-containers: $(SRC_DEPS_ORIGIN)
	@echo "We need to build everything as root, as the target also needs to run as root."
	@echo "At least for podman the password as already needed now"

	# creating container image from osbuild as a basis for worker
	sudo $(MAKE_SUB_CALL) -C ../osbuild container
	sudo $(MAKE_SUB_CALL) -C ../osbuild-composer container_worker container_composer
	# building the backend
	sudo $(MAKE_SUB_CALL) -C ../image-builder container
	# building remaining containers (config, fauxauth)
	$(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose.yml build

.PHONY: clean
clean: $(SRC_DEPS_ORIGIN)
	for DIR in $(SRC_DEPS_ORIGIN); do sudo $(MAKE_SUB_CALL) -C $(DIR) clean; done

.PHONY: run-service
run-service:
	sudo $(CONTAINER_COMPOSE_EXECUTABLE) -f service/docker-compose.yml up
