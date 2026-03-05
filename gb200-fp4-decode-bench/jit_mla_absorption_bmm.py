"""JIT-compile the MLA absorption BMM CUTLASS kernel as a standalone extension.

Compiles cutlass_absorption_bmm_bf16_sm100.cu (BF16×BF16→FP8 batched GEMM)
via nvcc with CUTLASS 3.x headers, avoiding a full cmake rebuild.

Usage (from /opt/vllm-source):
    python tools/jit_mla_absorption_bmm.py
"""
import os
import subprocess
import textwrap

from torch.utils.cpp_extension import load

SRC_DIR = "/opt/vllm-source/csrc"
BUILD_DIR = "/tmp/jit_build/mla_absorption_bmm"
os.makedirs(BUILD_DIR, exist_ok=True)

# Normalize arch list — SM100 Blackwell
os.environ["TORCH_CUDA_ARCH_LIST"] = "10.0a"

# --- Locate CUTLASS headers (header-only library) ---
# CUTLASS 4.x splits headers across two directories:
#   include/          — core cutlass/ and cute/ headers
#   tools/util/include/ — cutlass/util/packed_stride.hpp etc.
CUTLASS_ROOT_CANDIDATES = [
    # FetchContent download in vLLM build tree
    os.path.join(os.path.dirname(SRC_DIR), ".deps", "cutlass-src"),
    # User-specified override
    os.environ.get("VLLM_CUTLASS_SRC_DIR", ""),
    # Fallback clone location
    "/tmp/cutlass-4.2.1",
]

cutlass_root = None
for root in CUTLASS_ROOT_CANDIDATES:
    if root and os.path.isfile(os.path.join(root, "include", "cutlass", "cutlass.h")):
        cutlass_root = root
        break

if cutlass_root is None:
    clone_dir = "/tmp/cutlass-4.2.1"
    if os.path.isdir(clone_dir):
        import shutil
        shutil.rmtree(clone_dir)
    print("CUTLASS headers not found, cloning v4.2.1...")
    subprocess.check_call([
        "git", "clone", "--depth", "1", "--branch", "v4.2.1",
        "https://github.com/nvidia/cutlass.git", clone_dir,
    ])
    cutlass_root = clone_dir

# Both include paths needed for CUTLASS 4.x
cutlass_include_dirs = [os.path.join(cutlass_root, "include")]
tools_util = os.path.join(cutlass_root, "tools", "util", "include")
if os.path.isdir(tools_util):
    cutlass_include_dirs.append(tools_util)

print(f"Using CUTLASS headers from: {cutlass_include_dirs}")

# --- Pybind11 binding ---
BINDING_SRC = textwrap.dedent("""\
    #include <torch/extension.h>

    void mla_absorption_bmm_bf16(
        torch::Tensor&, torch::Tensor const&, torch::Tensor const&,
        torch::Tensor const&, torch::Tensor const&);

    PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
        m.def("mla_absorption_bmm_bf16", &mla_absorption_bmm_bf16,
              "CUTLASS BF16xBF16->FP8 batched GEMM for MLA absorption BMM");
    }
""")

binding_path = os.path.join(BUILD_DIR, "mla_absorption_bmm_binding.cpp")
with open(binding_path, "w") as f:
    f.write(BINDING_SRC)

# --- JIT compile ---
mod = load(
    name="mla_absorption_bmm_ext",
    sources=[
        binding_path,
        os.path.join(SRC_DIR, "mla", "cutlass_absorption_bmm_bf16_sm100.cu"),
    ],
    extra_include_paths=cutlass_include_dirs + [SRC_DIR],
    build_directory=BUILD_DIR,
    extra_cflags=["-O3", "-std=c++17"],
    extra_cuda_cflags=[
        "-O3",
        "--use_fast_math",
        "-std=c++17",
        "--expt-relaxed-constexpr",
        "--expt-extended-lambda",
    ],
    verbose=True,
)

print(f"mla_absorption_bmm_ext built: {mod}")
