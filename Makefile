#
# Makefile for corosync-qnetd
# Version:	2.0 (20260519)
# Author:	Lisardo Prieto
#
# Two flows live here:
#
#   1) Local development & NAS deploy (private use)
#         make build        -> build single-arch image tagged :local
#         make save         -> export image to tar.gz
#         make scp-to-nas   -> copy tar.gz to the NAS
#         make load-in-nas  -> docker load on the NAS via SSH
#         make nas-deploy   -> the above four chained
#
#   2) Public release to Docker Hub (multi-architecture via buildx)
#         make release      -> build, tag (version + latest), push to Docker Hub
#         make release-dry  -> same as release but without --push (validates locally)
#
# Requirements:
#   - Docker Desktop (with buildx enabled, default in recent versions)
#   - ssh / scp in PATH (Git Bash, OpenSSH for Windows, WSL...)
#   - For release: `docker login` against Docker Hub beforehand
#

# .SILENT: build save scp-to-nas load-in-nas clean rmi nas-deploy release release-dry buildx-create buildx-rm

##################################################
# GLOBAL VARIABLES
##################################################

image-name      = corosync-qnetd
image-version   = 1.1.0

# --- Public registry (Docker Hub) ---
# Replace with your Docker Hub username before running 'release'.
dockerhub-user  = lpgonzalez
image-public    = $(dockerhub-user)/$(image-name)

# Tags pushed on each release. Adjust to taste (semver short tags, edge, etc.).
release-tags    = $(image-version) latest

# Platforms for multi-arch builds. armv7 is also viable if you need it.
platforms       = linux/amd64,linux/arm64

# --- Local NAS deploy ---
image-local     = $(image-name):local
tarball         = $(image-name).tar.gz

nas-user        = admin
nas-host        = 10.0.10.254
nas-ssh-port    = 7000
nas-dest        = /share/Container/$(image-name)

# --- Build metadata (filled at build time) ---
build-date      = $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
vcs-ref         = $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Common --build-arg flags
build-args      = --build-arg VERSION=$(image-version) \
                  --build-arg VCS_REF=$(vcs-ref) \
                  --build-arg BUILD_DATE=$(build-date)

##################################################



all:
	@echo "Choose a target. Examples:"
	@echo "  make nas-deploy   - build, save, scp and load on the NAS"
	@echo "  make release      - multi-arch build and push to Docker Hub"
	@echo "  make help         - full target list with descriptions"



help:
	@echo "Local NAS deploy (private):"
	@echo "  build          Build single-arch image tagged $(image-local)"
	@echo "  save           Export $(image-local) to $(tarball)"
	@echo "  scp-to-nas     Copy $(tarball) to $(nas-user)@$(nas-host):$(nas-dest)/"
	@echo "  load-in-nas    docker load on the NAS via SSH (cleans tarball after)"
	@echo "  nas-deploy     build + save + scp-to-nas + load-in-nas"
	@echo ""
	@echo "Public release (Docker Hub, multi-arch):"
	@echo "  release        Multi-arch build and push $(image-public) tags: $(release-tags)"
	@echo "  release-dry    Same as release but build only (no --push)"
	@echo "  buildx-create  Create the multi-arch buildx builder (one-off)"
	@echo "  buildx-rm      Remove the multi-arch buildx builder"
	@echo ""
	@echo "Housekeeping:"
	@echo "  rmi            Remove local image $(image-local)"
	@echo "  clean          Remove tarball and local image"



##################################################
# Local NAS deploy
##################################################

build:
	@echo "Building $(image-local) (single-arch, current host)..."
	docker build $(build-args) -t $(image-local) .



save:
	@echo "Exporting $(image-local) to $(tarball)..."
	docker save $(image-local) | gzip > $(tarball)



scp-to-nas:
	@echo "Uploading $(tarball) to $(nas-user)@$(nas-host):$(nas-dest)/..."
	scp -P $(nas-ssh-port) $(tarball) $(nas-user)@$(nas-host):$(nas-dest)/



load-in-nas:
	@echo "Loading $(tarball) on $(nas-host)..."
	ssh -p $(nas-ssh-port) $(nas-user)@$(nas-host) \
		"gunzip -c $(nas-dest)/$(tarball) | docker load && rm -f $(nas-dest)/$(tarball)"
	@echo ""
	@echo "OK. Now (re)create the Application 'corosync-qnetd' from Container Station."



nas-deploy:
	make build
	make save
	make scp-to-nas
	make load-in-nas



##################################################
# Public release to Docker Hub (multi-arch)
##################################################

# One-off: create a buildx builder that supports multi-arch (qemu-driven).
buildx-create:
	docker buildx create --name corosync-qnetd-builder --use --bootstrap || \
		docker buildx use corosync-qnetd-builder



buildx-rm:
	docker buildx rm corosync-qnetd-builder || echo "Builder not present, nothing to remove."



# Build and push multi-arch image with all tags listed in release-tags.
release: buildx-create
	@echo "Releasing $(image-public) tags=[$(release-tags)] platforms=[$(platforms)]"
	docker buildx build \
		$(build-args) \
		--platform $(platforms) \
		$(foreach t,$(release-tags),-t $(image-public):$(t)) \
		--push \
		.
	@echo ""
	@echo "Pushed: $(foreach t,$(release-tags),$(image-public):$(t) )"



# Dry-run: builds in the multi-arch builder but does NOT push.
# Useful to validate the Dockerfile builds cleanly on all platforms.
release-dry: buildx-create
	@echo "Dry-run multi-arch build for $(image-public) (no push)"
	docker buildx build \
		$(build-args) \
		--platform $(platforms) \
		$(foreach t,$(release-tags),-t $(image-public):$(t)) \
		.



##################################################
# Housekeeping
##################################################

rmi:
	docker rmi $(image-local) || echo "Image $(image-local) not present"



clean:
	rm -f $(tarball)
	make rmi
