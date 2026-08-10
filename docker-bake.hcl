# Variables for reuse
variable "VERSION" {
    default = "latest"
}

variable "REGISTRY" {
    default = "ghcr.io"
}

variable "OWNER" {
    default = "selfishpig"
}

variable "REPO" {
    default = "kokoro-fastapi"
}

variable "DOWNLOAD_MODEL" {
    default = "true"
}

# Source-control revision + build timestamp, populated from CI env.
# Left blank for local builds so the resulting labels/annotations stay empty
# rather than carrying stale values.
variable "REVISION" {
    default = ""
}

variable "CREATED" {
    default = ""
}

# OCI metadata applied to every image. `labels` lands in the image config
# (visible via `docker inspect`); `annotations` lands on the pushed manifest
# (which is what GHCR reads for per-arch package pages). Index-level
# annotations for the multi-arch tag are added in release.yml at
# `imagetools create` time, since bake here only produces per-arch manifests.
target "_common" {
    context = "."
    args = {
        DEBIAN_FRONTEND = "noninteractive"
        DOWNLOAD_MODEL = "${DOWNLOAD_MODEL}"
    }
    labels = {
        "org.opencontainers.image.source"   = "https://github.com/${OWNER}/Kokoro-FastAPI"
        "org.opencontainers.image.url"      = "https://github.com/${OWNER}/Kokoro-FastAPI"
        "org.opencontainers.image.licenses" = "Apache-2.0"
        "org.opencontainers.image.revision" = "${REVISION}"
        "org.opencontainers.image.version"  = "${VERSION}"
        "org.opencontainers.image.created"  = "${CREATED}"
    }
    annotations = [
        "org.opencontainers.image.source=https://github.com/${OWNER}/Kokoro-FastAPI",
        "org.opencontainers.image.url=https://github.com/${OWNER}/Kokoro-FastAPI",
        "org.opencontainers.image.licenses=Apache-2.0",
        "org.opencontainers.image.revision=${REVISION}",
        "org.opencontainers.image.version=${VERSION}",
        "org.opencontainers.image.created=${CREATED}",
    ]
}

# Base settings for CPU builds
target "_cpu_base" {
    inherits = ["_common"]
    dockerfile = "docker/cpu/Dockerfile.optimized"
    labels = {
        "org.opencontainers.image.title"       = "Kokoro-FastAPI (CPU)"
        "org.opencontainers.image.description" = "Kokoro TTS served via FastAPI. CPU build."
    }
    annotations = [
        "org.opencontainers.image.title=Kokoro-FastAPI (CPU)",
        "org.opencontainers.image.description=Kokoro TTS served via FastAPI. CPU build.",
    ]
}

# Base settings for GPU builds
target "_gpu_base" {
    inherits = ["_common"]
    dockerfile = "docker/gpu/Dockerfile.optimized"
    labels = {
        "org.opencontainers.image.title"       = "Kokoro-FastAPI (GPU)"
        "org.opencontainers.image.description" = "Kokoro TTS served via FastAPI. NVIDIA GPU build with CUDA 12.8 and cu128 PyTorch wheels. amd64 only."
    }
    annotations = [
        "org.opencontainers.image.title=Kokoro-FastAPI (GPU)",
        "org.opencontainers.image.description=Kokoro TTS served via FastAPI. NVIDIA GPU build with CUDA 12.8 and cu128 PyTorch wheels. amd64 only.",
    ]
}

# CPU target with multi-platform support
target "cpu" {
    inherits = ["_cpu_base"]
    platforms = ["linux/amd64", "linux/arm64"]
    cache-from = [
        "type=registry,ref=${REGISTRY}/${OWNER}/${REPO}-cache:cpu-amd64",
        "type=registry,ref=${REGISTRY}/${OWNER}/${REPO}-cache:cpu-arm64",
    ]
    tags = [
        "${REGISTRY}/${OWNER}/${REPO}-cpu:${VERSION}"
    ]
}

# The published GPU image is amd64-only.
group "gpu" {
    targets = ["gpu-amd64"]
}

# Individual platform targets for debugging/testing
target "cpu-amd64" {
    inherits = ["_cpu_base"]
    platforms = ["linux/amd64"]
    cache-from = ["type=registry,ref=${REGISTRY}/${OWNER}/${REPO}-cache:cpu-amd64"]
    tags = [
        "${REGISTRY}/${OWNER}/${REPO}-cpu:${VERSION}-amd64"
    ]
}

target "cpu-arm64" {
    inherits = ["_cpu_base"]
    platforms = ["linux/arm64"]
    cache-from = ["type=registry,ref=${REGISTRY}/${OWNER}/${REPO}-cache:cpu-arm64"]
    tags = [
        "${REGISTRY}/${OWNER}/${REPO}-cpu:${VERSION}-arm64"
    ]
}

target "gpu-amd64" {
    inherits = ["_gpu_base"]
    platforms = ["linux/amd64"]
    args = {
        CUDA_VERSION = "12.8.1"
        GPU_EXTRA = "gpu-cu128"
    }
    cache-from = ["type=registry,ref=${REGISTRY}/${OWNER}/${REPO}-cache:gpu-amd64"]
    tags = [
        "${REGISTRY}/${OWNER}/${REPO}-gpu:${VERSION}-amd64"
    ]
}

# Development targets for faster local builds
target "cpu-dev" {
    inherits = ["_cpu_base"]
    cache-from = ["type=registry,ref=${REGISTRY}/${OWNER}/${REPO}-cache:cpu-amd64"]
    tags = ["${REGISTRY}/${OWNER}/${REPO}-cpu:dev"]
}

target "gpu-dev" {
    inherits = ["_gpu_base"]
    args = {
        CUDA_VERSION = "12.8.1"
        GPU_EXTRA = "gpu-cu128"
    }
    cache-from = ["type=registry,ref=${REGISTRY}/${OWNER}/${REPO}-cache:gpu-amd64"]
    tags = ["${REGISTRY}/${OWNER}/${REPO}-gpu:dev"]
}

group "dev" {
    targets = ["cpu-dev", "gpu-dev"]
}

# Build groups for different use cases
group "cpu-all" {
    targets = ["cpu", "cpu-amd64", "cpu-arm64"]
}

group "gpu-all" {
    targets = ["gpu-amd64"]
}

group "all" {
    targets = ["cpu", "gpu-amd64"]
}

group "individual-platforms" {
    targets = ["cpu-amd64", "cpu-arm64", "gpu-amd64"]
}

group "default" {
    targets = ["cpu", "gpu-amd64"]
}
