# Package related
BINARY_NAME=ib-sriov
PACKAGE=ib-sriov-cni
ORG_PATH=github.com/k8snetworkplumbingwg
REPO_PATH=$(ORG_PATH)/$(PACKAGE)
GOPATH=$(CURDIR)/.gopath
GOBIN =$(CURDIR)/bin
BINDIR=$(CURDIR)/bin
BUILDDIR=$(CURDIR)/build
BASE=$(GOPATH)/src/$(REPO_PATH)
GOFILES=$(shell find . -name *.go | grep -vE "(\/vendor\/)|(_test.go)")
PKGS=$(or $(PKG),$(shell cd $(BASE) && env GOPATH=$(GOPATH) $(GO) list ./... | grep -v "^$(PACKAGE)/vendor/"))
TESTPKGS = $(shell env GOPATH=$(GOPATH) $(GO) list -f '{{ if or .TestGoFiles .XTestGoFiles }}{{ .ImportPath }}{{ end }}' $(PKGS))

export GOPATH
export GOBIN

# Version
VERSION?=master
DATE=`date -Iseconds`
COMMIT?=`git rev-parse --verify HEAD`
LDFLAGS="-X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.date=$(DATE)"

# Docker
IMAGE_BUILDER?=@docker
IMAGEDIR=$(BASE)/images
DOCKERFILE?=$(CURDIR)/Dockerfile
TAG?=k8snetworkplumbingwg/ib-sriov-cni
IMAGE_BUILD_OPTS?=
# Accept proxy settings for docker
# To pass proxy for Docker invoke it as 'make image HTTP_POXY=http://192.168.0.1:8080'
DOCKERARGS=
ifdef HTTP_PROXY
	DOCKERARGS += --build-arg http_proxy=$(HTTP_PROXY)
endif
ifdef HTTPS_PROXY
	DOCKERARGS += --build-arg https_proxy=$(HTTPS_PROXY)
endif
IMAGE_BUILD_OPTS += $(DOCKERARGS)

# Go tools
GO      = go
GOLANGCI_LINT = $(GOBIN)/golangci-lint
# golangci-lint version should be updated periodically
# we keep it fixed to avoid it from unexpectedly failing on the project
# in case of a version bump
GOLANGCI_LINT_VER = v1.51.2
TIMEOUT = 15
Q = $(if $(filter 1,$V),,@)

.PHONY: all
all: lint build test-coverage

$(BASE): ; $(info  setting GOPATH...)
	@mkdir -p $(dir $@)
	@ln -sf $(CURDIR) $@

$(GOBIN):
	@mkdir -p $@

$(BUILDDIR): | $(BASE) ; $(info Creating build directory...)
	@cd $(BASE) && mkdir -p $@

build: $(BUILDDIR)/$(BINARY_NAME) ; $(info Building $(BINARY_NAME)...) ## Build executable file
	$(info Done!)

$(BUILDDIR)/$(BINARY_NAME): $(GOFILES) | $(BUILDDIR)
	@cd $(BASE)/cmd/$(PACKAGE) && CGO_ENABLED=0 $(GO) build -o $(BUILDDIR)/$(BINARY_NAME) -tags no_openssl -ldflags $(LDFLAGS) -v

# Tools
$(GOLANGCI_LINT): ; $(info  installing golangci-lint...)
	$Q go install github.com/golangci/golangci-lint/cmd/golangci-lint@$(GOLANGCI_LINT_VER)


# Tests

.PHONY: lint
lint: | $(GOLANGCI_LINT) ; $(info  running golangci-lint...) @ ## Run golangci-lint
	$Q $(GOLANGCI_LINT) run --timeout=5m

TEST_TARGETS := test-default test-bench test-short test-verbose test-race
.PHONY: $(TEST_TARGETS) test-xml check test tests
test-bench:   ARGS=-run=__absolutelynothing__ -bench=. ## Run benchmarks
test-short:   ARGS=-short        ## Run only short tests
test-verbose: ARGS=-v            ## Run tests in verbose mode with coverage reporting
test-race:    ARGS=-race         ## Run tests with race detector
$(TEST_TARGETS): NAME=$(MAKECMDGOALS:test-%=%)
$(TEST_TARGETS): test
check test tests: lint | $(BASE) ; $(info  running $(NAME:%=% )tests...) @ ## Run tests
	$Q cd $(BASE) && $(GO) test -timeout $(TIMEOUT)s $(ARGS) $(TESTPKGS)

test-xml: lint | $(BASE) $(GO2XUNIT) ; $(info  running $(NAME:%=% )tests...) @ ## Run tests with xUnit output
	$Q cd $(BASE) && 2>&1 $(GO) test -timeout 20s -v $(TESTPKGS) | tee test/tests.output
	$(GO2XUNIT) -fail -input test/tests.output -output test/tests.xml

GOVERALLS = $(BINDIR)/goveralls
$(GOVERALLS): | $(BASE) ; $(info  installing goveralls...)
	$(call go-install-tool,$(GOVERALLS),github.com/mattn/goveralls@latest)

HADOLINT_TOOL = $(BINDIR)/hadolint
$(HADOLINT_TOOL): | $(BASE) ; $(info  installing hadolint...)
	$(call wget-install-tool,$(HADOLINT_TOOL),"https://github.com/hadolint/hadolint/releases/download/v2.12.1-beta/hadolint-Linux-x86_64")

SHELLCHECK_TOOL = $(BINDIR)/shellcheck
$(SHELLCHECK_TOOL): | $(BASE) ; $(info  installing shellcheck...)
	$(call install-shellcheck,$(BINDIR),"https://github.com/koalaman/shellcheck/releases/download/v0.9.0/shellcheck-v0.9.0.linux.x86_64.tar.xz")

COVERAGE_MODE = count
COVER_PROFILE = ib-sriov-cni.cover
test-coverage-tools: | $(GOVERALLS)
test-coverage: test-coverage-tools | $(BASE) ; $(info  running coverage tests...) @ ## Run coverage tests
	$Q $(GO) test -covermode=$(COVERAGE_MODE) -coverprofile=$(COVER_PROFILE) ./...

.PHONY: upload-coverage
upload-coverage: test-coverage-tools | $(BASE) ; $(info  uploading coverage results...) @ ## Upload coverage report
	$(GOVERALLS) -coverprofile=$(COVER_PROFILE) -service=github

.PHONY: hadolint
hadolint: $(BASE) $(HADOLINT_TOOL); $(info  running hadolint...) @ ## Run hadolint
	$Q $(HADOLINT_TOOL) Dockerfile

.PHONY: shellcheck
shellcheck: $(BASE) $(SHELLCHECK_TOOL); $(info  running shellcheck...) @ ## Run shellcheck
	$Q $(SHELLCHECK_TOOL) images/entrypoint.sh

# Container image
.PHONY: image
image: | $(BASE) ; $(info Building Docker image...)  ## Build conatiner image
	$(IMAGE_BUILDER) build -t $(TAG) -f $(DOCKERFILE)  $(CURDIR) $(IMAGE_BUILD_OPTS)

# Dependency management
.PHONY: deps-update
deps-update: ; $(info  updating dependencies...)
	go mod tidy && go mod vendor

# Misc

.PHONY: clean
clean: ; $(info  Cleaning...)	 ## Cleanup everything
	@$(GO) clean -modcache
	@rm -rf $(GOPATH)
	@rm -rf $(BUILDDIR)
	@rm -rf  test

.PHONY: help
help: ## Show this message
	@grep -E '^[ a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

define wget-install-tool
@[ -f $(1) ] || { \
echo "Downloading $(2)" ;\
mkdir -p $(BINDIR);\
wget -O $(1) $(2);\
chmod +x $(1) ;\
}
endef

define install-shellcheck
@[ -f $(1) ] || { \
echo "Downloading $(2)" ;\
mkdir -p $(1);\
wget -O $(1)/shellcheck.tar.xz $(2);\
tar xf $(1)/shellcheck.tar.xz -C $(1);\
mv $(1)/shellcheck*/shellcheck $(1)/shellcheck;\
chmod +x $(1)/shellcheck;\
rm -r $(1)/shellcheck*/;\
rm $(1)/shellcheck.tar.xz;\
}
endef
