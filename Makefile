.PHONY: all
all: build bpf

# environment:
ARCH ?= $(shell uname -m)
KERN_RELEASE ?= $(shell uname -r)
KERN_SRC ?= $(shell readlink /lib/modules/$(KERN_RELEASE)/build)
# inputs and outputs:
OUT_DIR ?= dist
GO_SRC := $(shell find . -type f -name '*.go')
OUT_BIN := $(OUT_DIR)/tracee
BPF_SRC := tracee/tracee.bpf.c 
OUT_BPF := $(OUT_DIR)/tracee.bpf.o
BPF_HEADERS := 3rdparty/include
BPF_BUNDLE := $(OUT_DIR)/tracee.bpf.tar.gz
LIBBPF_SRC := 3rdparty/libbpf/src
LIBBPF_HEADERS := $(OUT_DIR)/libbpf/usr/include
LIBBPF_OBJ := $(OUT_DIR)/libbpf/libbpf.a
OUT_DOCKER ?= tracee
DOCKER_BUILDER ?= tracee-builder
RELEASE_ARCHIVE := $(OUT_DIR)/tracee.tar.gz
RELEASE_CHECKSUMS := $(OUT_DIR)/checksums.txt
RELEASE_DOCKER ?= aquasec/tracee
RELEASE_DOCKER_TAG ?= $(RELEASE_TAG:v%=%)
# tools:
CMD_LLC ?= llc
CMD_CLANG ?= clang
CMD_LLVM_STRIP ?= llvm-strip
CMD_DOCKER ?= docker
CMD_GIT ?= git
CMD_CHECKSUM ?= sha256sum
CMD_GITHUB ?= gh

$(OUT_DIR):
	mkdir -p $@

.PHONY: build
build: $(OUT_BIN)

go_env := GOOS=linux GOARCH=$(ARCH:x86_64=amd64) CC=$(CMD_CLANG) CGO_CFLAGS="-I $(abspath $(LIBBPF_HEADERS))" CGO_LDFLAGS="$(abspath $(LIBBPF_OBJ))"
$(OUT_BIN): $(LIBBPF_HEADERS) $(LIBBPF_OBJ) $(filter-out *_test.go,$(GO_SRC)) $(BPF_BUNDLE) $(if $(DOCKER),$(DOCKER_BUILDER)) | $(OUT_DIR)
ifndef DOCKER
	$(go_env) go build -v -o $(OUT_BIN) \
	-ldflags "-X main.bpfBundleInjected=$$(base64 -w 0 $(BPF_BUNDLE))"
else
	$(tracee_builder_make) build
	$(CMD_DOCKER) cp $$(cat $(tracee_builder_state)):/tracee/$(OUT_BIN) $(OUT_BIN)
	$(CMD_DOCKER) rm $$(cat $(tracee_builder_state)) && rm $(tracee_builder_state)
endif

bpf_compile_tools = $(CMD_LLC) $(CMD_CLANG)
.PHONY: $(bpf_compile_tools) 
$(bpf_compile_tools): % : check_%

$(LIBBPF_SRC):
	test -d $(LIBBPF_SRC) || ( echo "missing libbpf source, try git submodule update --init" ; false )

$(LIBBPF_HEADERS): | $(OUT_DIR) $(bpf_compile_tools) $(LIBBPF_SRC)
	cd $(LIBBPF_SRC) && $(MAKE) install_headers install_uapi_headers DESTDIR=$(abspath $(OUT_DIR))/libbpf

$(LIBBPF_OBJ): | $(OUT_DIR) $(bpf_compile_tools) $(LIBBPF_SRC) 
	cd $(LIBBPF_SRC) && $(MAKE) OBJDIR=$(abspath $(OUT_DIR))/libbpf BUILD_STATIC_ONLY=1 

bpf_bundle_dir := $(OUT_DIR)/tracee.bpf
$(BPF_BUNDLE): $(BPF_SRC) $(LIBBPF_HEADERS)/bpf $(BPF_HEADERS)
	mkdir -p $(bpf_bundle_dir)
	cp $$(find $^ -type f) $(bpf_bundle_dir)
	tar -czf $@ $(bpf_bundle_dir)

.PHONY: bpf
bpf: $(OUT_BPF)

linux_arch := $(ARCH:x86_64=x86)
$(OUT_BPF): $(BPF_SRC) $(LIBBPF_HEADERS) $(if $(DOCKER),$(DOCKER_BUILDER)) | $(OUT_DIR) $(bpf_compile_tools)
ifndef DOCKER
	@v=$$($(CMD_CLANG) --version); test $$(echo $${v#*version} | head -n1 | cut -d '.' -f1) -ge '9' || (echo 'required minimum clang version: 9' ; false)
	$(CMD_CLANG) -S \
		-D__BPF_TRACING__ \
		-D__KERNEL__ \
		-D__TARGET_ARCH_$(linux_arch) \
		-I $(LIBBPF_HEADERS)/bpf \
		-include $(KERN_SRC)/include/linux/kconfig.h \
		-I $(KERN_SRC)/arch/$(linux_arch)/include \
		-I $(KERN_SRC)/arch/$(linux_arch)/include/uapi \
		-I $(KERN_SRC)/arch/$(linux_arch)/include/generated \
		-I $(KERN_SRC)/arch/$(linux_arch)/include/generated/uapi \
		-I $(KERN_SRC)/include \
		-I $(KERN_SRC)/include/uapi \
		-I $(KERN_SRC)/include/generated \
		-I $(KERN_SRC)/include/generated/uapi \
		-I $(BPF_HEADERS) \
		-Wno-address-of-packed-member \
		-Wno-compare-distinct-pointer-types \
		-Wno-deprecated-declarations \
		-Wno-gnu-variable-sized-type-not-at-end \
		-Wno-pointer-sign \
		-Wno-pragma-once-outside-heade \
		-Wno-unknown-warning-option \
		-Wno-unused-value \
		-Wunused \
		-Wall \
		-fno-stack-protector \
		-fno-jump-tables \
		-fno-unwind-tables \
		-fno-asynchronous-unwind-tables \
		-xc \
		-nostdinc \
		-O2 -emit-llvm -c -g $< -o $(@:.o=.ll)
	$(CMD_LLC) -march=bpf -filetype=obj -o $@ $(@:.o=.ll)
	-$(CMD_LLVM_STRIP) -g $@
	rm $(@:.o=.ll)
else
	$(tracee_builder_make) bpf
	$(CMD_DOCKER) cp $$(cat $(tracee_builder_state)):/tracee/$(OUT_BPF) $(OUT_BPF)
	$(CMD_DOCKER) rm $$(cat $(tracee_builder_state) && rm $(tracee_builder_state))
endif


.PHONY: test 
go_src_test := $(shell find . -type f -name '*_test.go')
test: $(GO_SRC) $(go_src_test) $(LIBBPF_HEADERS) $(LIBBPF_OBJ) $(if $(DOCKER),$(DOCKER_BUILDER)) 
ifndef DOCKER
	$(go_env)	go test -v ./...
else
	$(tracee_builder_make) test
	$(CMD_DOCKER) rm $$(cat $(tracee_builder_state) && rm $(tracee_builder_state))
endif

.PHONY: $(DOCKER_BUILDER)
# use a dummy file to prevent unnecessary building
$(DOCKER_BUILDER): $(OUT_DIR)/$(DOCKER_BUILDER)

$(OUT_DIR)/$(DOCKER_BUILDER): $(GO_SRC) $(BPF_SRC) $(MAKEFILE_LIST) Dockerfile | $(OUT_DIR)
	$(CMD_DOCKER) build -t $(DOCKER_BUILDER) --iidfile $(OUT_DIR)/$(DOCKER_BUILDER) --target builder .

tracee_builder_state := $(OUT_DIR)/tracee-builder-cid
tracee_builder_make := $(CMD_DOCKER) run --cidfile $(tracee_builder_state) -v $(dir $(KERN_SRC)):$(dir $(KERN_SRC)) --entrypoint make $(DOCKER_BUILDER) KERN_SRC=$(KERN_SRC)

.PHONY: clean
clean:
	-rm -rf dist $(OUT_DIR)
	-cd $(LIBBPF_SRC) && $(MAKE) clean;
	-$(CMD_DOCKER) rmi $(file < $(DOCKER_BUILDER))
	
check_%:
	@command -v $* >/dev/null || (echo "missing required tool $*" ; false)

.PHONY: docker
docker:
	$(CMD_DOCKER) build -t $(OUT_DOCKER) .

$(RELEASE_ARCHIVE) $(RELEASE_CHECKSUMS) &: $(OUT_BIN) LICENSE | $(OUT_DIR) check_$(CMD_CHECKSUM)
	tar -czf $(RELEASE_ARCHIVE) $(OUT_BIN) LICENSE
	$(CMD_CHECKSUM) $(RELEASE_ARCHIVE) > $(RELEASE_CHECKSUMS)

release_notes:=$(OUT_DIR)/release-notes.txt
.PHONY: release
# before running this rule, need to authenticate git, gh, and docker tools.
release: | check_$(CMD_GITHUB) $(RELEASE_ARCHIVE) $(RELEASE_CHECKSUMS) #docker
	test -n '$(RELEASE_TAG)' || (echo "missing required variable RELEASE_TAG" ; false)
	rm $(release_notes)
	echo '## Changelog' > $(release_notes)
	$(CMD_GIT) log --pretty=oneline --abbrev=commit --no-decorate --no-color tags/$(shell $(CMD_GIT) describe --tags --abbrev=0)..HEAD >> $(release_notes)
	echo '' >> $(release_notes)
	echo '## Docker images' >> $(release_notes) >> $(release_notes)
	echo '- `docker pull docker.io/$(RELEASE_DOCKER):$(RELEASE_DOCKER_TAG)`' >> $(release_notes)
	echo '- `docker pull docker.io/$(RELEASE_DOCKER):latest`' >> $(release_notes)
	echo '' >>$(release_notes)
	$(CMD_GIT) tag $(RELEASE_TAG)
	$(CMD_GIT) push origin $(RELEASE_TAG)
	$(CMD_GITHUB) release create $(RELEASE_TAG) $(RELEASE_ARCHIVE) $(RELEASE_CHECKSUMS) --title $(RELEASE_TAG) --notes-file $(release_notes)
	$(CMD_DOCKER) tag $(OUT_DOCKER) $(RELEASE_DOCKER):latest
	$(CMD_DOCKER) push $(RELEASE_DOCKER):latest
	$(CMD_DOCKER) tag $(OUT_DOCKER) $(RELEASE_DOCKER):$(RELEASE_DOCKER_TAG)
	$(CMD_DOCKER) push $(RELEASE_DOCKER):$(RELEASE_DOCKER_TAG)
